// usb16x16-dante-owner: the long-lived owner of the Inferno (Dante) device.
// Design and the measurements behind every rule here: ../OWNER_DESIGN.md and
// ../RESULTS.md. This file is step 4 of that design, the network half only:
// it opens the Inferno PCMs once, keeps the playback pointer a fixed lead ahead
// of the clock with silence, discards what the capture delivers, and never
// calls prepare, drop or start again until it exits. The USB half is step 5.
//
// The three rules the network half exists to keep:
//   1. No prepare after start. A stall is absorbed by forwarding the
//      application pointers (needs the plugin built from patches/0001 with
//      XRUN_REPORT "0"; the stock plugin reports the underrun and the only way
//      out of that is the prepare that costs six seconds of audio).
//   2. Nothing but the lead holds audio. The transmit thread sends whatever the
//      buffer holds at the clock, written or not, so the buffer is cleared
//      behind the clock (less a guard) on every wake.
//   3. Every thread exists before the loop starts, and the Inferno device is
//      opened before the loop thread turns real-time, so the plugin's control
//      threads do not inherit that.
//
// Build on the Pi:
//   g++ -std=c++20 -O2 -Wall -Wextra -Wpedantic -Werror -o usb16x16-dante-owner main.cpp -lasound -lpthread

#include <alsa/asoundlib.h>

#include <dirent.h>
#include <pthread.h>
#include <sched.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <cinttypes>
#include <csignal>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <string_view>

namespace {

constexpr unsigned kChannels = 16;
constexpr unsigned kRate = 48000;
constexpr std::int64_t kTickNs = 1000000;          // the loop's grid while no gadget drives it
constexpr snd_pcm_uframes_t kResyncMargin = 16;    // the clock moves 4 to 5 frames during a forward (RESULTS.md)

std::atomic<bool> stop_requested{false};
void on_signal(int) { stop_requested.store(true, std::memory_order_relaxed); }

std::int64_t now_ns() noexcept {
    timespec ts{};
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return static_cast<std::int64_t>(ts.tv_sec) * 1000000000LL + ts.tv_nsec;
}

struct Options {
    std::string pcm{"inferno"};
    snd_pcm_uframes_t period{64};
    snd_pcm_uframes_t buffer{1024};
    snd_pcm_uframes_t tx_lead{128};
    snd_pcm_uframes_t guard{256};
    int priority{79};
    unsigned seconds{0};
    unsigned log_every{10};
    bool no_usb{false};
    bool mlock{true};
    bool realtime{true};
};

[[noreturn]] void usage(const char* message = nullptr) {
    if (message != nullptr) {
        std::fprintf(stderr, "%s\n", message);
    }
    std::fputs("usb16x16-dante-owner --no-usb [--pcm inferno] [--period 64] [--buffer 1024] [--tx-lead 128]\n"
               "                     [--guard 256] [--priority 79] [--seconds 0] [--log-every 10]\n"
               "                     [--no-mlock] [--no-rt]\n"
               "  --no-usb    network half only: silence out, capture discarded (the only mode built so far)\n"
               "  --tx-lead   frames the playback pointer is kept ahead of the Dante clock\n"
               "  --guard     frames behind the clock that are not cleared yet\n"
               "  --seconds   stop after this long; 0 runs until a signal\n"
               "  --no-mlock, --no-rt   for an unprivileged trial only\n",
               stderr);
    std::exit(2);
}

unsigned long parse_number(const char* text, const char* name) {
    char* end = nullptr;
    errno = 0;
    const unsigned long value = std::strtoul(text, &end, 10);
    if (errno != 0 || end == text || *end != '\0') {
        usage((std::string("bad value for ") + name).c_str());
    }
    return value;
}

Options parse_options(int argc, char** argv) {
    Options o;
    for (int i = 1; i < argc; ++i) {
        const std::string_view a(argv[i]);
        if (a == "--no-usb") { o.no_usb = true; continue; }
        if (a == "--no-mlock") { o.mlock = false; continue; }
        if (a == "--no-rt") { o.realtime = false; continue; }
        if (a == "--help" || i + 1 >= argc) { usage(); }
        const char* v = argv[++i];
        if (a == "--pcm") o.pcm = v;
        else if (a == "--period") o.period = parse_number(v, "--period");
        else if (a == "--buffer") o.buffer = parse_number(v, "--buffer");
        else if (a == "--tx-lead") o.tx_lead = parse_number(v, "--tx-lead");
        else if (a == "--guard") o.guard = parse_number(v, "--guard");
        else if (a == "--priority") o.priority = static_cast<int>(parse_number(v, "--priority"));
        else if (a == "--seconds") o.seconds = static_cast<unsigned>(parse_number(v, "--seconds"));
        else if (a == "--log-every") o.log_every = static_cast<unsigned>(parse_number(v, "--log-every"));
        else usage((std::string("unknown option ") + std::string(a)).c_str());
    }
    if (!o.no_usb) usage("the USB half is not built yet: run with --no-usb");
    if (o.buffer != 1024 && o.buffer != 2048) usage("--buffer must be 1024 or 2048");
    if (o.period != 32 && o.period != 64) usage("--period must be 32 or 64");
    // The transmit thread reads up to one packet (32 frames) ahead of the clock.
    if (o.tx_lead < 48 || o.tx_lead + o.guard + o.period > o.buffer) usage("--tx-lead and --guard do not fit the buffer");
    if (o.priority < 1 || o.priority > 98) usage("--priority must be 1 to 98");
    if (o.log_every < 1) usage("--log-every must be at least 1");
    return o;
}

// ---- thread inventory (the probe's THREADS line) -----------------------------------

unsigned thread_inventory(const char* stage, bool print) {
    DIR* directory = opendir("/proc/self/task");
    if (directory == nullptr) return 0;
    unsigned signature = 0;
    unsigned count = 0;
    char text[4096];
    std::size_t used = 0;
    text[0] = '\0';
    while (dirent* entry = readdir(directory)) {
        if (entry->d_name[0] == '.') continue;
        const unsigned tid = static_cast<unsigned>(std::strtoul(entry->d_name, nullptr, 10));
        signature = signature * 31U + tid;
        ++count;
        if (!print) continue;
        char path[96];
        char name[64] = "?";
        char stat[1024];
        std::snprintf(path, sizeof path, "/proc/self/task/%u/comm", tid);
        if (FILE* f = std::fopen(path, "r")) {
            if (std::fgets(name, sizeof name, f) != nullptr) name[std::strcspn(name, "\n")] = '\0';
            std::fclose(f);
        }
        long priority = -1;
        long policy = -1;
        std::snprintf(path, sizeof path, "/proc/self/task/%u/stat", tid);
        if (FILE* f = std::fopen(path, "r")) {
            if (std::fgets(stat, sizeof stat, f) != nullptr) {
                char* cursor = std::strrchr(stat, ')');   // fields after the name; state is field 3
                int field = 2;
                char* save = nullptr;
                for (char* token = cursor != nullptr ? strtok_r(cursor + 1, " ", &save) : nullptr; token != nullptr;
                     token = strtok_r(nullptr, " ", &save)) {
                    ++field;
                    if (field == 40) priority = std::strtol(token, nullptr, 10);
                    if (field == 41) { policy = std::strtol(token, nullptr, 10); break; }
                }
            }
            std::fclose(f);
        }
        const char* policy_name = policy == 0 ? "OTHER" : policy == 1 ? "FIFO" : policy == 2 ? "RR" : "?";
        if (used < sizeof text - 128) {
            used += static_cast<std::size_t>(
                std::snprintf(text + used, sizeof text - used, " [%u %s %s/%ld]", tid, name, policy_name, priority));
        }
    }
    closedir(directory);
    if (print) {
        std::printf("THREADS stage=%s count=%u%s\n", stage, count, text);
        std::fflush(stdout);
    }
    return signature ^ (count << 24);
}

// ---- what the loop publishes for the telemetry thread -------------------------------

struct Telemetry {
    std::atomic<std::uint64_t> wakes{0};
    std::atomic<std::int64_t> gap_us_max{0};
    std::atomic<std::int64_t> tx_depth_min{INT64_MAX};
    std::atomic<std::int64_t> tx_depth_max{INT64_MIN};
    std::atomic<std::int64_t> rx_avail_max{0};
    std::atomic<std::uint64_t> tx_frames{0};
    std::atomic<std::uint64_t> rx_frames{0};
    std::atomic<std::uint64_t> tx_resyncs{0};
    std::atomic<std::uint64_t> tx_lost{0};
    std::atomic<std::uint64_t> rx_resyncs{0};
    std::atomic<std::uint64_t> rx_lost{0};
    std::atomic<std::uint64_t> cleared{0};
    std::atomic<std::uint64_t> offset_mismatches{0};
    std::atomic<std::uint64_t> net_errors{0};
    std::atomic<std::int64_t> last_error{0};
    // One pending resync report at a time; the loop never prints.
    std::atomic<std::int64_t> resync_report{0};   // frames, negative for capture
    std::atomic<bool> running{false};
};

void store_max(std::atomic<std::int64_t>& target, std::int64_t value) noexcept {
    if (value > target.load(std::memory_order_relaxed)) target.store(value, std::memory_order_relaxed);
}
void store_min(std::atomic<std::int64_t>& target, std::int64_t value) noexcept {
    if (value < target.load(std::memory_order_relaxed)) target.store(value, std::memory_order_relaxed);
}

struct TelemetryContext {
    Telemetry* telemetry;
    unsigned log_every;
};

void* telemetry_entry(void* argument) {
    const TelemetryContext context = *static_cast<TelemetryContext*>(argument);
    Telemetry& t = *context.telemetry;
    const std::int64_t started = now_ns();
    std::int64_t next_line = started + static_cast<std::int64_t>(context.log_every) * 1000000000LL;
    std::int64_t next_inventory = started + 60000000000LL;
    unsigned signature = 0;
    std::uint64_t last_tx = 0;
    std::uint64_t last_rx = 0;
    std::uint64_t reported_errors = 0;
    while (!stop_requested.load(std::memory_order_relaxed)) {
        timespec nap{0, 100000000};
        nanosleep(&nap, nullptr);
        if (!t.running.load(std::memory_order_acquire)) continue;
        const std::int64_t now = now_ns();
        const double seconds = static_cast<double>(now - started) / 1e9;
        if (const std::int64_t report = t.resync_report.exchange(0, std::memory_order_relaxed); report != 0) {
            std::printf("NETRESYNC dir=%s frames=%" PRId64 " t=%.3f\n", report < 0 ? "capture" : "playback",
                        report < 0 ? -report : report, seconds);
            signature = thread_inventory("after-resync", true);
        }
        if (const std::uint64_t errors = t.net_errors.load(std::memory_order_relaxed); errors != reported_errors) {
            const auto code = static_cast<int>(t.last_error.load(std::memory_order_relaxed));
            std::printf("NETERROR count=%" PRIu64 " last=%d (%s) t=%.3f\n", errors, code, snd_strerror(code), seconds);
            reported_errors = errors;
            std::fflush(stdout);
        }
        if (signature == 0) signature = thread_inventory("", false);
        if (now >= next_inventory) {
            next_inventory += 60000000000LL;
            const unsigned current = thread_inventory("", false);
            if (current != signature) {
                signature = thread_inventory("CHANGED-while-running", true);
            }
        }
        if (now >= next_line) {
            next_line += static_cast<std::int64_t>(context.log_every) * 1000000000LL;
            const std::uint64_t tx = t.tx_frames.load(std::memory_order_relaxed);
            const std::uint64_t rx = t.rx_frames.load(std::memory_order_relaxed);
            std::printf("OWNER t=%.1f state=no-usb wakes=%" PRIu64 " gap_us_max=%" PRId64 " tx_depth=%" PRId64 "..%" PRId64
                        " rx_avail_max=%" PRId64 " tx_frames=%" PRIu64 " rx_frames=%" PRIu64 " tx_resyncs=%" PRIu64
                        " tx_lost=%" PRIu64 " rx_resyncs=%" PRIu64 " rx_lost=%" PRIu64 " cleared=%" PRIu64
                        " offset_mismatches=%" PRIu64 " net_errors=%" PRIu64 "\n",
                        seconds, t.wakes.exchange(0, std::memory_order_relaxed),
                        t.gap_us_max.exchange(0, std::memory_order_relaxed),
                        t.tx_depth_min.exchange(INT64_MAX, std::memory_order_relaxed),
                        t.tx_depth_max.exchange(INT64_MIN, std::memory_order_relaxed),
                        t.rx_avail_max.exchange(0, std::memory_order_relaxed), tx - last_tx, rx - last_rx,
                        t.tx_resyncs.load(std::memory_order_relaxed), t.tx_lost.load(std::memory_order_relaxed),
                        t.rx_resyncs.load(std::memory_order_relaxed), t.rx_lost.load(std::memory_order_relaxed),
                        t.cleared.load(std::memory_order_relaxed), t.offset_mismatches.load(std::memory_order_relaxed),
                        t.net_errors.load(std::memory_order_relaxed));
            std::fflush(stdout);
            last_tx = tx;
            last_rx = rx;
        }
    }
    return nullptr;
}

// ---- the Inferno PCMs ------------------------------------------------------------------

[[noreturn]] void fail(const std::string& what, int code) {
    std::printf("FATAL %s: %s (%d)\n", what.c_str(), snd_strerror(code), code);
    std::fflush(stdout);
    std::exit(1);
}

struct NetPcm {
    snd_pcm_t* handle{nullptr};
    snd_pcm_uframes_t period{0};
    snd_pcm_uframes_t buffer{0};
    // The whole ring: one interleaved block of buffer * stride bytes.
    char* base{nullptr};
    std::size_t stride{0};
};

// Opens and configures one direction. hw_params leaves an ioplug prepared and
// has already created its network thread; prepare is deliberately not called,
// because on this plugin a second prepare stops that thread and makes another.
NetPcm open_net(const Options& o, snd_pcm_stream_t stream) {
    const char* direction = stream == SND_PCM_STREAM_CAPTURE ? "capture" : "playback";
    NetPcm pcm;
    int rc = snd_pcm_open(&pcm.handle, o.pcm.c_str(), stream, SND_PCM_NONBLOCK);
    if (rc < 0) fail(std::string("open ") + direction, rc);

    snd_pcm_hw_params_t* hw = nullptr;
    snd_pcm_sw_params_t* sw = nullptr;
    snd_pcm_hw_params_alloca(&hw);
    snd_pcm_sw_params_alloca(&sw);
    unsigned rate = kRate;
    int dir = 0;
    pcm.period = o.period;
    pcm.buffer = o.buffer;
    if ((rc = snd_pcm_hw_params_any(pcm.handle, hw)) < 0 ||
        (rc = snd_pcm_hw_params_set_access(pcm.handle, hw, SND_PCM_ACCESS_MMAP_INTERLEAVED)) < 0 ||
        (rc = snd_pcm_hw_params_set_format(pcm.handle, hw, SND_PCM_FORMAT_S32_LE)) < 0 ||
        (rc = snd_pcm_hw_params_set_channels(pcm.handle, hw, kChannels)) < 0 ||
        (rc = snd_pcm_hw_params_set_rate_near(pcm.handle, hw, &rate, &dir)) < 0 ||
        (rc = snd_pcm_hw_params_set_period_size_near(pcm.handle, hw, &pcm.period, &dir)) < 0 ||
        (rc = snd_pcm_hw_params_set_buffer_size_near(pcm.handle, hw, &pcm.buffer)) < 0) {
        fail(std::string("hw_params setup ") + direction, rc);
    }
    const std::int64_t before = now_ns();
    if ((rc = snd_pcm_hw_params(pcm.handle, hw)) < 0) fail(std::string("hw_params ") + direction, rc);
    const std::int64_t hw_us = (now_ns() - before) / 1000;
    snd_pcm_hw_params_get_period_size(hw, &pcm.period, &dir);
    snd_pcm_hw_params_get_buffer_size(hw, &pcm.buffer);
    if (rate != kRate || pcm.period != o.period || pcm.buffer != o.buffer) {
        std::printf("FATAL %s negotiated rate=%u period=%lu buffer=%lu, asked %u/%lu/%lu\n", direction, rate,
                    static_cast<unsigned long>(pcm.period), static_cast<unsigned long>(pcm.buffer), kRate,
                    static_cast<unsigned long>(o.period), static_cast<unsigned long>(o.buffer));
        std::exit(1);
    }

    // Both streams are started explicitly, once; nothing may start or stop them by itself.
    snd_pcm_uframes_t boundary = 0;
    if ((rc = snd_pcm_sw_params_current(pcm.handle, sw)) < 0 ||
        (rc = snd_pcm_sw_params_get_boundary(sw, &boundary)) < 0 ||
        (rc = snd_pcm_sw_params_set_avail_min(pcm.handle, sw, pcm.period)) < 0 ||
        (rc = snd_pcm_sw_params_set_start_threshold(pcm.handle, sw, boundary)) < 0 ||
        (rc = snd_pcm_sw_params_set_stop_threshold(pcm.handle, sw, boundary)) < 0 ||
        (rc = snd_pcm_sw_params(pcm.handle, sw)) < 0) {
        fail(std::string("sw_params ") + direction, rc);
    }

    // The ring's address: frame 0 of the mmap area. Nothing is committed here.
    const snd_pcm_channel_area_t* areas = nullptr;
    snd_pcm_uframes_t offset = 0;
    snd_pcm_uframes_t frames = 1;
    if ((rc = snd_pcm_mmap_begin(pcm.handle, &areas, &offset, &frames)) < 0) fail(std::string("mmap_begin ") + direction, rc);
    pcm.stride = areas[0].step / 8;
    pcm.base = static_cast<char*>(areas[0].addr) + areas[0].first / 8;
    if (pcm.stride != kChannels * sizeof(std::int32_t) || offset != 0) {
        std::printf("FATAL %s buffer layout: stride=%zu offset=%lu\n", direction, pcm.stride,
                    static_cast<unsigned long>(offset));
        std::exit(1);
    }
    // A fresh buffer is not silence on this plugin (RESULTS.md, part 3).
    std::memset(pcm.base, 0, pcm.buffer * pcm.stride);
    std::printf("NETOPEN dir=%s period=%lu buffer=%lu hw_params_us=%" PRId64 " state=%s\n", direction,
                static_cast<unsigned long>(pcm.period), static_cast<unsigned long>(pcm.buffer), hw_us,
                snd_pcm_state_name(snd_pcm_state(pcm.handle)));
    return pcm;
}

// Zero `frames` frames of the playback ring starting at ring index `index`.
void clear_ring(const NetPcm& pcm, snd_pcm_uframes_t index, snd_pcm_uframes_t frames) noexcept {
    while (frames > 0) {
        const snd_pcm_uframes_t run = std::min(frames, pcm.buffer - index);
        std::memset(pcm.base + index * pcm.stride, 0, run * pcm.stride);
        frames -= run;
        index = (index + run) % pcm.buffer;
    }
}

// ---- the network half ------------------------------------------------------------------

struct NetHalf {
    NetPcm capture;
    NetPcm playback;
    snd_pcm_uframes_t lead{0};
    snd_pcm_uframes_t guard{0};
    // Frames the playback application pointer has moved since start (commits
    // and forwards), and the position below which the ring has been cleared.
    std::uint64_t appl{0};
    std::uint64_t cleared_to{0};
};

// Commit `frames` of silence at the application pointer. The ring ahead of the
// pointer is already zero by the clearing rule; it is cleared again here so the
// rule is not what correctness of the lead rests on.
bool commit_silence(NetHalf& net, snd_pcm_uframes_t frames, Telemetry& t) noexcept {
    while (frames > 0) {
        const snd_pcm_channel_area_t* areas = nullptr;
        snd_pcm_uframes_t offset = 0;
        snd_pcm_uframes_t run = frames;
        const int begin = snd_pcm_mmap_begin(net.playback.handle, &areas, &offset, &run);
        if (begin < 0 || run == 0) {
            t.last_error.store(begin, std::memory_order_relaxed);
            t.net_errors.fetch_add(1, std::memory_order_relaxed);
            return false;
        }
        if (offset != net.appl % net.playback.buffer) {
            t.offset_mismatches.fetch_add(1, std::memory_order_relaxed);
        }
        std::memset(net.playback.base + offset * net.playback.stride, 0, run * net.playback.stride);
        const snd_pcm_sframes_t done = snd_pcm_mmap_commit(net.playback.handle, offset, run);
        if (done <= 0) {
            t.last_error.store(done, std::memory_order_relaxed);
            t.net_errors.fetch_add(1, std::memory_order_relaxed);
            return false;
        }
        net.appl += static_cast<std::uint64_t>(done);
        frames -= static_cast<snd_pcm_uframes_t>(done);
        t.tx_frames.fetch_add(static_cast<std::uint64_t>(done), std::memory_order_relaxed);
    }
    return true;
}

// One wake of the network half with no gadget: returns false on an error that
// the design has no answer to (the stock plugin reporting an underrun).
bool service_network(NetHalf& net, Telemetry& t) noexcept {
    // Capture: everything is discarded. Above the buffer size the ring has been
    // lapped, which the plugin does not report; it is counted, and the pointer
    // moves on the same way.
    const snd_pcm_sframes_t captured = snd_pcm_avail_update(net.capture.handle);
    if (captured < 0) {
        t.last_error.store(captured, std::memory_order_relaxed);
        t.net_errors.fetch_add(1, std::memory_order_relaxed);
        return false;
    }
    if (captured > 0) {
        store_max(t.rx_avail_max, captured);
        if (static_cast<snd_pcm_uframes_t>(captured) > net.capture.buffer) {
            const auto lost = static_cast<std::uint64_t>(captured) - net.capture.buffer;
            t.rx_resyncs.fetch_add(1, std::memory_order_relaxed);
            t.rx_lost.fetch_add(lost, std::memory_order_relaxed);
            t.resync_report.store(-static_cast<std::int64_t>(lost), std::memory_order_relaxed);
        }
        snd_pcm_forward(net.capture.handle, static_cast<snd_pcm_uframes_t>(captured));
        t.rx_frames.fetch_add(static_cast<std::uint64_t>(captured), std::memory_order_relaxed);
    }

    // Playback: where the clock stands against the application pointer.
    snd_pcm_sframes_t available = snd_pcm_avail_update(net.playback.handle);
    if (available < 0) {
        t.last_error.store(available, std::memory_order_relaxed);
        t.net_errors.fetch_add(1, std::memory_order_relaxed);
        return false;
    }
    std::int64_t depth = static_cast<std::int64_t>(net.playback.buffer) - available;
    store_min(t.tx_depth_min, depth);
    store_max(t.tx_depth_max, depth);
    if (depth < 0) {
        // The clock has passed the pointer. Move the pointer past the clock by
        // a margin (the clock keeps moving while this runs); the lead is
        // written below as on any wake. No prepare, no thread is touched.
        const auto deficit = static_cast<snd_pcm_uframes_t>(-depth) + kResyncMargin;
        const snd_pcm_sframes_t moved = snd_pcm_forward(net.playback.handle, deficit);
        if (moved > 0) net.appl += static_cast<std::uint64_t>(moved);
        t.tx_resyncs.fetch_add(1, std::memory_order_relaxed);
        t.tx_lost.fetch_add(static_cast<std::uint64_t>(-depth), std::memory_order_relaxed);
        t.resync_report.store(-depth, std::memory_order_relaxed);
        available = snd_pcm_avail_update(net.playback.handle);
        if (available < 0) {
            t.last_error.store(available, std::memory_order_relaxed);
            t.net_errors.fetch_add(1, std::memory_order_relaxed);
            return false;
        }
        depth = static_cast<std::int64_t>(net.playback.buffer) - available;
    }

    // Clear behind the clock, less the guard: positions [cleared_to, clock - guard).
    const std::int64_t clock = static_cast<std::int64_t>(net.appl) - depth;
    const std::int64_t clear_until = clock - static_cast<std::int64_t>(net.guard);
    if (clear_until > static_cast<std::int64_t>(net.cleared_to)) {
        const auto span = static_cast<std::uint64_t>(clear_until) - net.cleared_to;
        if (span >= net.playback.buffer) {
            // A stall longer than a lap: nothing in the ring is current. The
            // lead written below is the only thing that should be in it.
            std::memset(net.playback.base, 0, net.playback.buffer * net.playback.stride);
        } else {
            clear_ring(net.playback, static_cast<snd_pcm_uframes_t>(net.cleared_to % net.playback.buffer),
                       static_cast<snd_pcm_uframes_t>(span));
        }
        t.cleared.fetch_add(span, std::memory_order_relaxed);
        net.cleared_to = static_cast<std::uint64_t>(clear_until);
    }

    if (depth < static_cast<std::int64_t>(net.lead)) {
        return commit_silence(net, static_cast<snd_pcm_uframes_t>(static_cast<std::int64_t>(net.lead) - depth), t);
    }
    return true;
}

}  // namespace

int main(int argc, char** argv) {
    const Options options = parse_options(argc, argv);
    std::signal(SIGINT, on_signal);
    std::signal(SIGTERM, on_signal);
    std::setvbuf(stdout, nullptr, _IOLBF, 0);

    std::printf("START usb16x16-dante-owner mode=no-usb pcm=%s period=%lu buffer=%lu tx_lead=%lu guard=%lu "
                "priority=%d mlock=%d rt=%d seconds=%u\n",
                options.pcm.c_str(), static_cast<unsigned long>(options.period),
                static_cast<unsigned long>(options.buffer), static_cast<unsigned long>(options.tx_lead),
                static_cast<unsigned long>(options.guard), options.priority, options.mlock ? 1 : 0,
                options.realtime ? 1 : 0, options.seconds);

    // 1. Memory lock first, so every stack made below is populated when it is made.
    if (options.mlock && mlockall(MCL_CURRENT | MCL_FUTURE) != 0) {
        std::printf("FATAL mlockall: %s\n", std::strerror(errno));
        return 1;
    }

    // 2. The owner's own threads, before the device exists.
    Telemetry telemetry;
    TelemetryContext context{&telemetry, options.log_every};
    pthread_t telemetry_thread{};
    pthread_attr_t attributes;
    pthread_attr_init(&attributes);
    pthread_attr_setstacksize(&attributes, 256 * 1024);
    const int created = pthread_create(&telemetry_thread, &attributes, telemetry_entry, &context);
    pthread_attr_destroy(&attributes);
    if (created != 0) {
        std::printf("FATAL telemetry thread: %s\n", std::strerror(created));
        return 1;
    }
    thread_inventory("before-open", true);

    // 3. The Inferno device, at normal priority: its control threads inherit the opener's policy.
    NetHalf net;
    net.capture = open_net(options, SND_PCM_STREAM_CAPTURE);
    net.playback = open_net(options, SND_PCM_STREAM_PLAYBACK);
    net.lead = options.tx_lead;
    net.guard = options.guard;
    thread_inventory("after-open", true);

    // 4. The lead as silence, then the one start of each stream.
    if (!commit_silence(net, net.lead, telemetry)) {
        fail("first lead", static_cast<int>(telemetry.last_error.load()));
    }
    int rc = snd_pcm_start(net.capture.handle);
    if (rc < 0) fail("start capture", rc);
    rc = snd_pcm_start(net.playback.handle);
    if (rc < 0) fail("start playback", rc);
    std::printf("NETSTART capture=%s playback=%s\n", snd_pcm_state_name(snd_pcm_state(net.capture.handle)),
                snd_pcm_state_name(snd_pcm_state(net.playback.handle)));

    // 5. Only now does the loop thread turn real-time.
    if (options.realtime) {
        sched_param parameters{};
        parameters.sched_priority = options.priority;
        const int result = pthread_setschedparam(pthread_self(), SCHED_FIFO, &parameters);
        if (result != 0) {
            std::printf("FATAL SCHED_FIFO: %s\n", std::strerror(result));
            return 1;
        }
    }
    thread_inventory("running", true);
    telemetry.running.store(true, std::memory_order_release);

    const std::int64_t started = now_ns();
    std::int64_t next = started + kTickNs;
    std::int64_t last_wake = started;
    int exit_code = 0;
    while (!stop_requested.load(std::memory_order_relaxed)) {
        timespec target{};
        target.tv_sec = static_cast<time_t>(next / 1000000000LL);
        target.tv_nsec = static_cast<long>(next % 1000000000LL);
        clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &target, nullptr);
        const std::int64_t now = now_ns();
        store_max(telemetry.gap_us_max, (now - last_wake) / 1000);
        last_wake = now;
        telemetry.wakes.fetch_add(1, std::memory_order_relaxed);
        if (!service_network(net, telemetry)) {
            // Not recoverable by design: a prepare here is the six-second dropout.
            exit_code = 3;
            break;
        }
        next += kTickNs;
        if (next < now) next = now + kTickNs;   // a stall: do not run a burst of catch-up wakes
        if (options.seconds != 0 && now - started >= static_cast<std::int64_t>(options.seconds) * 1000000000LL) break;
    }
    stop_requested.store(true, std::memory_order_relaxed);
    pthread_join(telemetry_thread, nullptr);

    const double elapsed = static_cast<double>(now_ns() - started) / 1e9;
    std::printf("SUMMARY seconds=%.2f exit=%d tx_frames=%" PRIu64 " rx_frames=%" PRIu64 " tx_resyncs=%" PRIu64
                " tx_lost=%" PRIu64 " rx_resyncs=%" PRIu64 " rx_lost=%" PRIu64 " cleared=%" PRIu64
                " offset_mismatches=%" PRIu64 " net_errors=%" PRIu64 " last_error=%" PRId64 " capture=%s playback=%s\n",
                elapsed, exit_code, telemetry.tx_frames.load(), telemetry.rx_frames.load(), telemetry.tx_resyncs.load(),
                telemetry.tx_lost.load(), telemetry.rx_resyncs.load(), telemetry.rx_lost.load(), telemetry.cleared.load(),
                telemetry.offset_mismatches.load(), telemetry.net_errors.load(), telemetry.last_error.load(),
                snd_pcm_state_name(snd_pcm_state(net.capture.handle)),
                snd_pcm_state_name(snd_pcm_state(net.playback.handle)));
    if (exit_code == 3) {
        std::printf("FATAL the Inferno PCM reported an error; with the stock plugin this is an underrun "
                    "(run the plugin built from patches/0001 with XRUN_REPORT \"0\")\n");
    }
    thread_inventory("before-close", true);
    snd_pcm_drop(net.playback.handle);
    snd_pcm_close(net.playback.handle);
    snd_pcm_drop(net.capture.handle);
    snd_pcm_close(net.capture.handle);
    return exit_code;
}
