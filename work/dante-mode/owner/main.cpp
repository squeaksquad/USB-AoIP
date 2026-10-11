// usb16x16-dante-owner: the long-lived owner of the Inferno (Dante) device.
// Design and the measurements behind every rule here: ../OWNER_DESIGN.md and
// ../RESULTS.md.
//
// The network half opens the Inferno PCMs once, keeps the playback pointer a
// lead ahead of the Dante clock, takes everything the capture delivers, and
// never calls prepare, drop or start again until it exits. The USB half joins
// the gadget's two PCMs to it whenever a host is streaming, each direction on
// its own, and goes away again without the network half doing anything but
// sending silence. With --no-usb only the network half runs.
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
// With --dsp-preset the outgoing direction (gadget capture to Dante) passes
// through the bridge core's DspStage on its way to the Inferno buffer
// (dsp_path.hpp). Without it no sample is converted and the path is the
// integer copy it always was. With --dsp-live-file as well, a thread made
// before the device is opened (rule 3) follows that file and publishes each
// same-shape artifact written to it into the running stage (dsp_live.hpp).
// With --meter-file, three level meters (what the host sent, what goes to
// Dante, what Dante returned) are published to that file by another such
// thread (meter_tap.hpp); with or without a preset.
//
// Build on the Pi (the bridge core is the one source file DspStage lives in):
//   g++ -std=c++20 -O2 -Wall -Wextra -Wpedantic -Werror -I ../../phase4-bridge/include
//       -o usb16x16-dante-owner main.cpp ../../phase4-bridge/src/bridge_core.cpp -lasound -lpthread
// (one line)
// (the headers beside it; servo_test.cpp, dsp_path_test.cpp, dsp_live_test.cpp
// and meter_tap_test.cpp are their tests and build anywhere)

#include <alsa/asoundlib.h>

#include "dsp_live.hpp"
#include "dsp_path.hpp"
#include "meter_tap.hpp"
#include "servo.hpp"

#include <dirent.h>
#include <poll.h>
#include <pthread.h>
#include <sched.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cerrno>
#include <cinttypes>
#include <csignal>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <fstream>
#include <sstream>
#include <string>
#include <string_view>

namespace {

constexpr unsigned kChannels = 16;
constexpr unsigned kRate = 48000;
constexpr std::int64_t kTickNs = 1000000;          // the loop's grid while no gadget drives it
constexpr snd_pcm_uframes_t kResyncMargin = 16;    // the clock moves 4 to 5 frames during a forward (RESULTS.md)
constexpr std::int64_t kPacketFrames = 32;         // the transmit thread reads this far ahead of the clock
constexpr std::size_t kScratchFrames = 1024;
constexpr unsigned kIdleWakes = 100;               // wakes without movement before a direction counts as stopped
constexpr unsigned kFaultHoldoffWakes = 50;        // after a gadget PCM error, leave that direction alone this long
constexpr int kNominalPitch = 1000000;

std::atomic<bool> stop_requested{false};
// Set by main once the loop has returned: only then may the steward close what the loop was using.
std::atomic<bool> loop_finished{false};
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
    std::string usb{"hw:CARD=UAC2Gadget,DEV=0"};
    snd_pcm_uframes_t usb_period{48};
    snd_pcm_uframes_t usb_buffer{480};
    snd_pcm_uframes_t rx_queue{144};
    snd_pcm_uframes_t rx_slack{96};
    double kp{0.5};
    double ki{0.003};
    double seed_ppm{0.0};
    bool seed_given{false};
    std::string ppm_file;
    // Coefficient artifact from `usb16x16-dsp-compile --bridge`. Empty means no
    // DSP stage at all: the outgoing direction stays an integer copy.
    std::string dsp_preset;
    // A file polled every 50 ms for a same-shape artifact to publish into the
    // running stage. Empty means the stage's numbers never change. Needs --dsp-preset.
    std::string dsp_live_file;
    std::string dsp_live_status;
    // Level meter snapshot file. Empty means no tap: nothing is converted or measured for it.
    std::string meter_file;
    // Test only: the loop sleeps once for stall_ms at stall_at seconds, to
    // exercise the paths a stall takes (resync, gadget overrun, re-prime).
    unsigned stall_at{0};
    unsigned stall_ms{0};
    bool mlock{true};
    bool realtime{true};
};

[[noreturn]] void usage(const char* message = nullptr) {
    if (message != nullptr) {
        std::fprintf(stderr, "%s\n", message);
    }
    std::fputs("usb16x16-dante-owner [--no-usb] [--pcm inferno] [--period 64] [--buffer 1024] [--tx-lead 128]\n"
               "                     [--guard 256] [--priority 79] [--seconds 0] [--log-every 10]\n"
               "                     [--usb hw:CARD=UAC2Gadget,DEV=0] [--usb-period 48] [--usb-buffer 480]\n"
               "                     [--rx-queue 144] [--rx-slack 96] [--kp 0.5] [--ki 0.003] [--seed-ppm 0]\n"
               "                     [--ppm-file PATH] [--dsp-preset FILE]\n"
               "                     [--dsp-live-file PATH] [--dsp-live-status PATH]\n"
               "                     [--meter-file PATH] [--stall-at SECONDS --stall-ms MS]\n"
               "                     [--no-mlock] [--no-rt]\n"
               "  --no-usb    network half only: silence out, capture discarded, the gadget never opened\n"
               "  --tx-lead   Inferno playback depth held after each gadget block (and the silent lead)\n"
               "  --rx-queue  gadget playback queue held after each write\n"
               "  --rx-slack  how far over --rx-queue the queue may go before incoming frames are dropped\n"
               "  --seed-ppm  the host's clock against Dante's, to start both servos from (0: learn it)\n"
               "  --ppm-file  where the learned offset is kept between runs; read at start unless\n"
               "              --seed-ppm is given, rewritten once a minute and at exit\n"
               "  --dsp-preset  DSP coefficients on the outgoing direction, gadget to Dante (default: no DSP)\n"
               "  --dsp-live-file    poll PATH (50 ms) for a same-shape artifact and publish its numbers\n"
               "                     into the running stage; needs --dsp-preset\n"
               "  --dsp-live-status  where the outcome of each live file is written (default: the\n"
               "                     live file with .status appended)\n"
               "  --meter-file       publish per-channel levels (usb-capture, dante-playback, dante-capture)\n"
               "                     to PATH, about twenty times a second while audio moves\n"
               "  --guard     frames behind the clock that are not cleared yet\n"
               "  --seconds   stop after this long; 0 runs until a signal\n"
               "  --stall-at, --stall-ms   test only: stall the loop once, MS long, SECONDS after it starts\n"
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
        else if (a == "--usb") o.usb = v;
        else if (a == "--usb-period") o.usb_period = parse_number(v, "--usb-period");
        else if (a == "--usb-buffer") o.usb_buffer = parse_number(v, "--usb-buffer");
        else if (a == "--rx-queue") o.rx_queue = parse_number(v, "--rx-queue");
        else if (a == "--rx-slack") o.rx_slack = parse_number(v, "--rx-slack");
        else if (a == "--kp") o.kp = std::strtod(v, nullptr);
        else if (a == "--ki") o.ki = std::strtod(v, nullptr);
        else if (a == "--seed-ppm") { o.seed_ppm = std::strtod(v, nullptr); o.seed_given = true; }
        else if (a == "--ppm-file") o.ppm_file = v;
        else if (a == "--dsp-preset") o.dsp_preset = v;
        else if (a == "--dsp-live-file") o.dsp_live_file = v;
        else if (a == "--dsp-live-status") o.dsp_live_status = v;
        else if (a == "--meter-file") o.meter_file = v;
        else if (a == "--stall-at") o.stall_at = static_cast<unsigned>(parse_number(v, "--stall-at"));
        else if (a == "--stall-ms") o.stall_ms = static_cast<unsigned>(parse_number(v, "--stall-ms"));
        else if (a == "--period") o.period = parse_number(v, "--period");
        else if (a == "--buffer") o.buffer = parse_number(v, "--buffer");
        else if (a == "--tx-lead") o.tx_lead = parse_number(v, "--tx-lead");
        else if (a == "--guard") o.guard = parse_number(v, "--guard");
        else if (a == "--priority") o.priority = static_cast<int>(parse_number(v, "--priority"));
        else if (a == "--seconds") o.seconds = static_cast<unsigned>(parse_number(v, "--seconds"));
        else if (a == "--log-every") o.log_every = static_cast<unsigned>(parse_number(v, "--log-every"));
        else usage((std::string("unknown option ") + std::string(a)).c_str());
    }
    if (o.usb_period < 16 || o.usb_period > 96) usage("--usb-period must be 16 to 96");
    if (o.rx_queue < 2 * o.usb_period || o.rx_queue + o.rx_slack + o.usb_period > o.usb_buffer || o.usb_buffer > 2048) {
        usage("--rx-queue, --rx-slack and --usb-buffer do not fit");
    }
    if (!(o.kp > 0.0 && o.kp <= 5.0) || !(o.ki >= 0.0 && o.ki <= 1.0) || !(o.seed_ppm >= -250.0 && o.seed_ppm <= 250.0)) {
        usage("--kp, --ki or --seed-ppm out of range");
    }
    if (o.buffer != 1024 && o.buffer != 2048) usage("--buffer must be 1024 or 2048");
    if (o.period != 32 && o.period != 64) usage("--period must be 32 or 64");
    // The transmit thread reads up to one packet (32 frames) ahead of the clock.
    if (o.tx_lead < 48 || o.tx_lead + o.guard + o.period > o.buffer) usage("--tx-lead and --guard do not fit the buffer");
    if (o.priority < 1 || o.priority > 98) usage("--priority must be 1 to 98");
    if (o.log_every < 1) usage("--log-every must be at least 1");
    if ((o.stall_at == 0) != (o.stall_ms == 0) || o.stall_ms > 500) usage("--stall-at and --stall-ms go together; at most 500 ms");
    if (o.dsp_preset.empty() && (!o.dsp_live_file.empty() || !o.dsp_live_status.empty())) {
        usage("--dsp-live-file needs --dsp-preset: there is no stage to update");
    }
    if (o.dsp_live_file.empty() && !o.dsp_live_status.empty()) usage("--dsp-live-status needs --dsp-live-file");
    if (o.dsp_live_status.empty() && !o.dsp_live_file.empty()) o.dsp_live_status = o.dsp_live_file + ".status";
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

// True once a thread of this process carries the name. The plugin's transmit
// thread is made by its runtime after the opens have returned: under the
// memory lock it appeared after the loop had started (2026-10-09, the hour
// run), so start-up waits for it rather than assume it.
bool wait_for_thread(const char* wanted, int milliseconds) {
    for (int waited = 0; waited <= milliseconds; waited += 10) {
        if (DIR* directory = opendir("/proc/self/task")) {
            bool found = false;
            while (dirent* entry = readdir(directory)) {
                if (entry->d_name[0] == '.') continue;
                char path[96];
                char name[64] = "";
                const unsigned tid = static_cast<unsigned>(std::strtoul(entry->d_name, nullptr, 10));
                std::snprintf(path, sizeof path, "/proc/self/task/%u/comm", tid);
                if (FILE* f = std::fopen(path, "r")) {
                    if (std::fgets(name, sizeof name, f) != nullptr) name[std::strcspn(name, "\n")] = '\0';
                    std::fclose(f);
                }
                if (std::strcmp(name, wanted) == 0) found = true;
            }
            closedir(directory);
            if (found) return true;
        }
        timespec nap{0, 10000000};
        nanosleep(&nap, nullptr);
    }
    return false;
}

// ---- what the loop publishes --------------------------------------------------------

enum class UsbOwner : int { steward_absent = 0, loop = 1, steward_closing = 2 };
enum class TxState : int { idle = 0, armed = 1, flow = 2 };

struct Telemetry {
    std::atomic<std::uint64_t> wakes{0};
    std::atomic<std::int64_t> gap_us_max{0};
    // Inferno playback depth as found on each wake, before anything is written.
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

    // The USB half.
    std::atomic<int> usb_owner{static_cast<int>(UsbOwner::steward_absent)};
    std::atomic<int> tx_state{static_cast<int>(TxState::idle)};
    std::atomic<bool> rx_flowing{false};
    std::atomic<int> wanted_capture_pitch{kNominalPitch};
    std::atomic<int> wanted_playback_pitch{kNominalPitch};
    // Depths after each write, as the servos see them: the last one-second means, in milliframes.
    std::atomic<std::int64_t> tx_mean_milli{0};
    std::atomic<std::int64_t> rx_mean_milli{0};
    std::atomic<std::int64_t> rx_depth_min{INT64_MAX};   // gadget queue as found, before the write
    std::atomic<std::int64_t> rx_depth_max{INT64_MIN};
    std::atomic<std::int64_t> tx_integral_milli{0};
    std::atomic<std::int64_t> rx_integral_milli{0};
    std::atomic<std::uint64_t> usb_tx_frames{0};          // gadget capture frames sent to Dante
    std::atomic<std::uint64_t> usb_rx_frames{0};          // Dante frames queued to the gadget
    std::atomic<std::uint64_t> tx_links{0};               // times the outgoing direction was primed
    std::atomic<std::uint64_t> tx_reprimes{0};            // of those, forced while it was flowing
    std::atomic<std::int64_t> tx_prime_block{0};          // the last prime: frames in the block it used
    std::atomic<std::int64_t> tx_prime_found{0};          //   and the Inferno depth it found
    std::atomic<std::uint64_t> rx_primes{0};
    std::atomic<std::uint64_t> rx_overflow{0};            // Dante frames dropped with the host pulling
    std::atomic<std::uint64_t> rx_idle_discards{0};       // Dante frames dropped with no host pulling
    std::atomic<std::uint64_t> usb_capture_faults{0};
    std::atomic<std::uint64_t> usb_playback_faults{0};
    std::atomic<std::int64_t> usb_last_fault{0};
    std::atomic<std::uint64_t> usb_detaches{0};
    std::atomic<std::uint64_t> pitch_write_errors{0};
    std::atomic<std::uint64_t> servo_rejected{0};         // seconds the depth filter held back
    // Largest |sample| (24-bit units) on channels 1 and 2 since the last USB line:
    // what the host sent, and what Dante returned. Tells a silent host from a silent loop.
    std::atomic<std::int32_t> out_peak_1{0};
    std::atomic<std::int32_t> out_peak_2{0};
    std::atomic<std::int32_t> back_peak_1{0};
    std::atomic<std::int32_t> back_peak_2{0};
    // Holes: runs of frames with all sixteen channels zero, between frames that carry signal,
    // 8 frames to 100 ms long. Count and longest, on what the host sent and on what Dante
    // returned. A hole in the first is the host's or USB's; in the second only, the network's.
    std::atomic<std::uint64_t> out_holes{0};
    std::atomic<std::uint32_t> out_hole_max{0};
    std::atomic<std::uint64_t> back_holes{0};
    std::atomic<std::uint32_t> back_hole_max{0};
    std::atomic<std::int64_t> ppm_estimate_milli{0};
    std::atomic<bool> ppm_known{false};
    // The DSP stage's cost on the loop thread, conversions included. Zero calls without a preset.
    std::atomic<std::int64_t> dsp_ns_max{0};
    std::atomic<std::uint64_t> dsp_ns_total{0};
    std::atomic<std::uint64_t> dsp_calls{0};
    std::atomic<std::uint64_t> dsp_resets{0};
    // Live coefficients: publishes the loop has taken, and the control thread's counts.
    std::atomic<std::uint64_t> dsp_live_generation{0};
    std::atomic<std::uint64_t> dsp_live_applied{0};
    std::atomic<std::uint64_t> dsp_live_refused{0};
    // The meter taps' cost on the loop thread, conversions for them included.
    std::atomic<std::int64_t> meter_ns_max{0};
    std::atomic<std::uint64_t> meter_ns_total{0};
    std::atomic<std::uint64_t> meter_calls{0};
    std::atomic<unsigned> stall_injected_ms{0};   // --stall-at fired; reported once
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
    bool no_usb;
};

const char* tx_state_name(int state) noexcept {
    return state == static_cast<int>(TxState::flow) ? "flow" : state == static_cast<int>(TxState::armed) ? "armed" : "idle";
}
const char* usb_owner_name(int owner) noexcept {
    return owner == static_cast<int>(UsbOwner::loop) ? "open" : owner == static_cast<int>(UsbOwner::steward_closing) ? "closing" : "absent";
}

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
    int link_owner = -1;
    int link_tx = -1;
    int link_rx = -1;
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
        if (const unsigned stall = t.stall_injected_ms.exchange(0, std::memory_order_relaxed); stall != 0) {
            std::printf("STALL injected ms=%u t=%.3f\n", stall, seconds);
        }
        if (const std::uint64_t errors = t.net_errors.load(std::memory_order_relaxed); errors != reported_errors) {
            const auto code = static_cast<int>(t.last_error.load(std::memory_order_relaxed));
            std::printf("NETERROR count=%" PRIu64 " last=%d (%s) t=%.3f\n", errors, code, snd_strerror(code), seconds);
            reported_errors = errors;
            std::fflush(stdout);
        }
        const int owner = t.usb_owner.load(std::memory_order_relaxed);
        const int tx = t.tx_state.load(std::memory_order_relaxed);
        const int rx = t.rx_flowing.load(std::memory_order_relaxed) ? 1 : 0;
        if (!context.no_usb && (owner != link_owner || tx != link_tx || rx != link_rx)) {
            link_owner = owner;
            link_tx = tx;
            link_rx = rx;
            std::printf("USBLINK usb=%s tx=%s rx=%s tx_links=%" PRIu64 " rx_primes=%" PRIu64 " capture_faults=%" PRIu64
                        " playback_faults=%" PRIu64 " last_fault=%" PRId64 " tx_prime_block=%" PRId64 " tx_prime_found=%" PRId64
                        " t=%.3f\n",
                        usb_owner_name(owner), tx_state_name(tx), rx != 0 ? "flow" : "idle",
                        t.tx_links.load(std::memory_order_relaxed), t.rx_primes.load(std::memory_order_relaxed),
                        t.usb_capture_faults.load(std::memory_order_relaxed),
                        t.usb_playback_faults.load(std::memory_order_relaxed),
                        t.usb_last_fault.load(std::memory_order_relaxed),
                        t.tx_prime_block.load(std::memory_order_relaxed),
                        t.tx_prime_found.load(std::memory_order_relaxed), seconds);
            signature = thread_inventory("usblink", true);
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
            const std::uint64_t txf = t.tx_frames.load(std::memory_order_relaxed);
            const std::uint64_t rxf = t.rx_frames.load(std::memory_order_relaxed);
            std::printf("OWNER t=%.1f wakes=%" PRIu64 " gap_us_max=%" PRId64 " tx_depth=%" PRId64 "..%" PRId64
                        " rx_avail_max=%" PRId64 " tx_frames=%" PRIu64 " rx_frames=%" PRIu64 " tx_resyncs=%" PRIu64
                        " tx_lost=%" PRIu64 " rx_resyncs=%" PRIu64 " rx_lost=%" PRIu64 " cleared=%" PRIu64
                        " offset_mismatches=%" PRIu64 " net_errors=%" PRIu64 "\n",
                        seconds, t.wakes.exchange(0, std::memory_order_relaxed),
                        t.gap_us_max.exchange(0, std::memory_order_relaxed),
                        t.tx_depth_min.exchange(INT64_MAX, std::memory_order_relaxed),
                        t.tx_depth_max.exchange(INT64_MIN, std::memory_order_relaxed),
                        t.rx_avail_max.exchange(0, std::memory_order_relaxed), txf - last_tx, rxf - last_rx,
                        t.tx_resyncs.load(std::memory_order_relaxed), t.tx_lost.load(std::memory_order_relaxed),
                        t.rx_resyncs.load(std::memory_order_relaxed), t.rx_lost.load(std::memory_order_relaxed),
                        t.cleared.load(std::memory_order_relaxed), t.offset_mismatches.load(std::memory_order_relaxed),
                        t.net_errors.load(std::memory_order_relaxed));
            if (!context.no_usb) {
                std::printf("USB t=%.1f usb=%s tx=%s rx=%s tx_mean=%.1f rx_mean=%.1f rx_depth=%" PRId64 "..%" PRId64
                            " pitch_c=%d pitch_p=%d tx_i=%.2f rx_i=%.2f usb_tx=%" PRIu64 " usb_rx=%" PRIu64
                            " tx_links=%" PRIu64 " tx_reprimes=%" PRIu64 " rx_primes=%" PRIu64 " rx_overflow=%" PRIu64
                            " rx_idle_discards=%" PRIu64 " capture_faults=%" PRIu64 " playback_faults=%" PRIu64
                            " detaches=%" PRIu64 " pitch_write_errors=%" PRIu64 " servo_rejected=%" PRIu64
                            " out_peak=%d,%d back_peak=%d,%d out_holes=%" PRIu64 "/%u back_holes=%" PRIu64 "/%u\n",
                            seconds, usb_owner_name(owner), tx_state_name(tx), rx != 0 ? "flow" : "idle",
                            static_cast<double>(t.tx_mean_milli.load(std::memory_order_relaxed)) / 1000.0,
                            static_cast<double>(t.rx_mean_milli.load(std::memory_order_relaxed)) / 1000.0,
                            t.rx_depth_min.exchange(INT64_MAX, std::memory_order_relaxed),
                            t.rx_depth_max.exchange(INT64_MIN, std::memory_order_relaxed),
                            t.wanted_capture_pitch.load(std::memory_order_relaxed),
                            t.wanted_playback_pitch.load(std::memory_order_relaxed),
                            static_cast<double>(t.tx_integral_milli.load(std::memory_order_relaxed)) / 1000.0,
                            static_cast<double>(t.rx_integral_milli.load(std::memory_order_relaxed)) / 1000.0,
                            t.usb_tx_frames.load(std::memory_order_relaxed), t.usb_rx_frames.load(std::memory_order_relaxed),
                            t.tx_links.load(std::memory_order_relaxed), t.tx_reprimes.load(std::memory_order_relaxed),
                            t.rx_primes.load(std::memory_order_relaxed), t.rx_overflow.load(std::memory_order_relaxed),
                            t.rx_idle_discards.load(std::memory_order_relaxed),
                            t.usb_capture_faults.load(std::memory_order_relaxed),
                            t.usb_playback_faults.load(std::memory_order_relaxed),
                            t.usb_detaches.load(std::memory_order_relaxed),
                            t.pitch_write_errors.load(std::memory_order_relaxed),
                            t.servo_rejected.load(std::memory_order_relaxed),
                            t.out_peak_1.exchange(0, std::memory_order_relaxed),
                            t.out_peak_2.exchange(0, std::memory_order_relaxed),
                            t.back_peak_1.exchange(0, std::memory_order_relaxed),
                            t.back_peak_2.exchange(0, std::memory_order_relaxed),
                            t.out_holes.load(std::memory_order_relaxed), t.out_hole_max.load(std::memory_order_relaxed),
                            t.back_holes.load(std::memory_order_relaxed), t.back_hole_max.load(std::memory_order_relaxed));
            }
            if (const std::uint64_t calls = t.dsp_calls.exchange(0, std::memory_order_relaxed); calls != 0) {
                std::printf("DSP t=%.1f dsp_us_max=%.1f dsp_us_mean=%.1f dsp_calls=%" PRIu64 " dsp_resets=%" PRIu64
                            " dsp_live_gen=%" PRIu64 " dsp_live_applied=%" PRIu64 " dsp_live_refused=%" PRIu64 "\n",
                            seconds, static_cast<double>(t.dsp_ns_max.exchange(0, std::memory_order_relaxed)) / 1000.0,
                            static_cast<double>(t.dsp_ns_total.exchange(0, std::memory_order_relaxed)) / 1000.0 /
                                static_cast<double>(calls),
                            calls, t.dsp_resets.load(std::memory_order_relaxed),
                            t.dsp_live_generation.load(std::memory_order_relaxed),
                            t.dsp_live_applied.load(std::memory_order_relaxed),
                            t.dsp_live_refused.load(std::memory_order_relaxed));
            }
            if (const std::uint64_t calls = t.meter_calls.exchange(0, std::memory_order_relaxed); calls != 0) {
                std::printf("METER t=%.1f meter_us_max=%.1f meter_us_mean=%.1f meter_calls=%" PRIu64 "\n", seconds,
                            static_cast<double>(t.meter_ns_max.exchange(0, std::memory_order_relaxed)) / 1000.0,
                            static_cast<double>(t.meter_ns_total.exchange(0, std::memory_order_relaxed)) / 1000.0 /
                                static_cast<double>(calls),
                            calls);
            }
            std::fflush(stdout);
            last_tx = txf;
            last_rx = rxf;
        }
    }
    return nullptr;
}

// ---- live coefficients -----------------------------------------------------------------

struct DspLiveContext {
    usb16x16::owner::DspLive* live;
    const usb16x16::DspStage* stage;
    Telemetry* telemetry;
};

// Never the loop thread and never real-time: it reads files and allocates.
void* dsp_live_entry(void* argument) {
    const DspLiveContext context = *static_cast<DspLiveContext*>(argument);
    usb16x16::owner::DspLive& live = *context.live;
    Telemetry& t = *context.telemetry;
    bool announced = false;
    while (!stop_requested.load(std::memory_order_relaxed)) {
        timespec nap{0, 50000000};
        nanosleep(&nap, nullptr);
        if (!t.running.load(std::memory_order_acquire)) continue;
        if (!announced) {
            announced = true;
            live.announce();
        }
        const usb16x16::owner::DspLive::Event event = live.poll();
        t.dsp_live_generation.store(context.stage->generation(), std::memory_order_relaxed);
        using Outcome = usb16x16::owner::DspLive::Outcome;
        if (event.outcome == Outcome::none) continue;
        if (event.outcome == Outcome::applied) {
            t.dsp_live_applied.fetch_add(1, std::memory_order_relaxed);
            std::printf("DSPLIVE applied sha256=%s\n", event.sha.c_str());
        } else {
            if (event.outcome == Outcome::refused) t.dsp_live_refused.fetch_add(1, std::memory_order_relaxed);
            std::printf("DSPLIVE %s sha256=%s reason=\"%s\"\n", event.outcome == Outcome::refused ? "refused" : "ignored",
                        event.sha.c_str(), event.reason.c_str());
        }
        std::fflush(stdout);
    }
    std::printf("DSPLIVE stopped applied=%" PRIu64 " refused=%" PRIu64 " ignored=%" PRIu64 " status_failures=%" PRIu64
                " last=%s\n",
                live.applied(), live.refused(), live.ignored(), live.status_failures(),
                live.last_sha().empty() ? "none" : live.last_sha().c_str());
    return nullptr;
}

// ---- level meters ----------------------------------------------------------------------

struct MeterContext {
    usb16x16::owner::MeterPublisher* publisher;
    Telemetry* telemetry;
};

// Never the loop thread and never real-time: it formats text and writes a file.
void* meter_entry(void* argument) {
    const MeterContext context = *static_cast<MeterContext*>(argument);
    while (!stop_requested.load(std::memory_order_relaxed)) {
        timespec nap{0, 25000000};
        nanosleep(&nap, nullptr);
        if (!context.telemetry->running.load(std::memory_order_acquire)) continue;
        context.publisher->poll();
    }
    std::printf("METERS stopped writes=%" PRIu64 " failures=%" PRIu64 "\n", context.publisher->writes(),
                context.publisher->failures());
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

using Scratch = std::array<std::int32_t, kScratchFrames * kChannels>;

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

void net_error(Telemetry& t, std::int64_t code) noexcept {
    t.last_error.store(code, std::memory_order_relaxed);
    t.net_errors.fetch_add(1, std::memory_order_relaxed);
}

// Commit `frames` at the Inferno application pointer: interleaved S32 from
// `source`, or silence when it is null. (The ring ahead of the pointer is
// already zero by the clearing rule; silence is written anyway so the rule is
// not what correctness of the lead rests on.)
bool commit_playback(NetHalf& net, const std::int32_t* source, snd_pcm_uframes_t frames, Telemetry& t) noexcept {
    while (frames > 0) {
        const snd_pcm_channel_area_t* areas = nullptr;
        snd_pcm_uframes_t offset = 0;
        snd_pcm_uframes_t run = frames;
        const int begin = snd_pcm_mmap_begin(net.playback.handle, &areas, &offset, &run);
        if (begin < 0 || run == 0) {
            net_error(t, begin);
            return false;
        }
        if (offset != net.appl % net.playback.buffer) {
            t.offset_mismatches.fetch_add(1, std::memory_order_relaxed);
        }
        if (source != nullptr) {
            std::memcpy(net.playback.base + offset * net.playback.stride, source, run * net.playback.stride);
            source += run * kChannels;
        } else {
            std::memset(net.playback.base + offset * net.playback.stride, 0, run * net.playback.stride);
        }
        const snd_pcm_sframes_t done = snd_pcm_mmap_commit(net.playback.handle, offset, run);
        if (done <= 0) {
            net_error(t, done);
            return false;
        }
        net.appl += static_cast<std::uint64_t>(done);
        frames -= static_cast<snd_pcm_uframes_t>(done);
        t.tx_frames.fetch_add(static_cast<std::uint64_t>(done), std::memory_order_relaxed);
    }
    return true;
}

// Move the Inferno application pointer forward without writing. What it skips
// is zero already (the clearing rule), so this is how silence of an exact
// length is inserted.
void skip_playback(NetHalf& net, snd_pcm_uframes_t frames) noexcept {
    if (frames == 0) return;
    const snd_pcm_sframes_t moved = snd_pcm_forward(net.playback.handle, frames);
    if (moved > 0) net.appl += static_cast<std::uint64_t>(moved);
}

// Take what the Inferno capture has. With `keep` null everything is discarded;
// otherwise the newest frames (at most kScratchFrames) are copied out and their
// count returned. Above the buffer size the ring has been lapped, which the
// plugin does not report: it is counted and only the newest period is kept.
// Returns -1 on a PCM error.
long take_capture(NetHalf& net, std::int32_t* keep, Telemetry& t) noexcept {
    snd_pcm_sframes_t captured = snd_pcm_avail_update(net.capture.handle);
    if (captured < 0) {
        net_error(t, captured);
        return -1;
    }
    if (captured == 0) return 0;
    store_max(t.rx_avail_max, captured);
    t.rx_frames.fetch_add(static_cast<std::uint64_t>(captured), std::memory_order_relaxed);
    if (static_cast<snd_pcm_uframes_t>(captured) > net.capture.buffer) {
        const auto lost = static_cast<std::uint64_t>(captured) - net.capture.period;
        t.rx_resyncs.fetch_add(1, std::memory_order_relaxed);
        t.rx_lost.fetch_add(lost, std::memory_order_relaxed);
        t.resync_report.store(-static_cast<std::int64_t>(lost), std::memory_order_relaxed);
        snd_pcm_forward(net.capture.handle, static_cast<snd_pcm_uframes_t>(lost));
        captured = static_cast<snd_pcm_sframes_t>(net.capture.period);
    }
    if (keep == nullptr) {
        snd_pcm_forward(net.capture.handle, static_cast<snd_pcm_uframes_t>(captured));
        return 0;
    }
    long kept = 0;
    auto remaining = static_cast<snd_pcm_uframes_t>(captured);
    while (remaining > 0) {
        const snd_pcm_channel_area_t* areas = nullptr;
        snd_pcm_uframes_t offset = 0;
        snd_pcm_uframes_t run = remaining;
        const int begin = snd_pcm_mmap_begin(net.capture.handle, &areas, &offset, &run);
        if (begin < 0 || run == 0) {
            net_error(t, begin);
            return -1;
        }
        std::memcpy(keep + static_cast<std::size_t>(kept) * kChannels, net.capture.base + offset * net.capture.stride,
                    run * net.capture.stride);
        const snd_pcm_sframes_t done = snd_pcm_mmap_commit(net.capture.handle, offset, run);
        if (done <= 0) {
            net_error(t, done);
            return -1;
        }
        kept += done;
        remaining -= static_cast<snd_pcm_uframes_t>(done);
    }
    return kept;
}

// Where the Dante clock stands against the playback application pointer, with
// the resync and the clearing rule applied. Sets `depth` (frames the pointer is
// ahead of the clock) and `resynced`. False on a PCM error.
bool observe_playback(NetHalf& net, std::int64_t& depth, bool& resynced, Telemetry& t) noexcept {
    resynced = false;
    snd_pcm_sframes_t available = snd_pcm_avail_update(net.playback.handle);
    if (available < 0) {
        net_error(t, available);
        return false;
    }
    depth = static_cast<std::int64_t>(net.playback.buffer) - available;
    store_min(t.tx_depth_min, depth);
    store_max(t.tx_depth_max, depth);
    if (depth < 0) {
        // The clock has passed the pointer. Move the pointer past the clock by
        // a margin (the clock keeps moving while this runs). No prepare, and no
        // thread is touched.
        skip_playback(net, static_cast<snd_pcm_uframes_t>(-depth) + kResyncMargin);
        t.tx_resyncs.fetch_add(1, std::memory_order_relaxed);
        t.tx_lost.fetch_add(static_cast<std::uint64_t>(-depth), std::memory_order_relaxed);
        t.resync_report.store(-depth, std::memory_order_relaxed);
        resynced = true;
        available = snd_pcm_avail_update(net.playback.handle);
        if (available < 0) {
            net_error(t, available);
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
            // A stall longer than a lap: nothing in the ring is current.
            std::memset(net.playback.base, 0, net.playback.buffer * net.playback.stride);
        } else {
            clear_ring(net.playback, static_cast<snd_pcm_uframes_t>(net.cleared_to % net.playback.buffer),
                       static_cast<snd_pcm_uframes_t>(span));
        }
        t.cleared.fetch_add(span, std::memory_order_relaxed);
        net.cleared_to = static_cast<std::uint64_t>(clear_until);
    }
    return true;
}

// ---- the USB half: handles ---------------------------------------------------------

struct UsbPcm {
    snd_pcm_t* handle{nullptr};
    snd_pcm_uframes_t period{0};
    snd_pcm_uframes_t buffer{0};
};

// Written by the steward before it hands the gadget to the loop, read by the
// loop only while it is the owner (Telemetry::usb_owner).
struct UsbHandles {
    UsbPcm capture;
    UsbPcm playback;
    pollfd capture_poll[4]{};
    int capture_poll_count{0};
};

// Opens and configures one gadget PCM as the bridge does (packed 24-bit, mmap,
// nonblocking), except that nothing starts by itself. Returns 0 or the ALSA error.
int open_usb(const Options& o, snd_pcm_stream_t stream, UsbPcm& pcm, std::string& stage) {
    int rc = snd_pcm_open(&pcm.handle, o.usb.c_str(), stream, SND_PCM_NONBLOCK);
    if (rc < 0) { pcm.handle = nullptr; stage = "open"; return rc; }
    snd_pcm_hw_params_t* hw = nullptr;
    snd_pcm_sw_params_t* sw = nullptr;
    snd_pcm_hw_params_alloca(&hw);
    snd_pcm_sw_params_alloca(&sw);
    unsigned rate = kRate;
    int dir = 0;
    pcm.period = o.usb_period;
    pcm.buffer = o.usb_buffer;
    snd_pcm_uframes_t boundary = 0;
    stage = "hw_params";
    if ((rc = snd_pcm_hw_params_any(pcm.handle, hw)) < 0 ||
        (rc = snd_pcm_hw_params_set_access(pcm.handle, hw, SND_PCM_ACCESS_MMAP_INTERLEAVED)) < 0 ||
        (rc = snd_pcm_hw_params_set_format(pcm.handle, hw, SND_PCM_FORMAT_S24_3LE)) < 0 ||
        (rc = snd_pcm_hw_params_set_channels(pcm.handle, hw, kChannels)) < 0 ||
        (rc = snd_pcm_hw_params_set_rate_near(pcm.handle, hw, &rate, &dir)) < 0 ||
        (rc = snd_pcm_hw_params_set_period_size_near(pcm.handle, hw, &pcm.period, &dir)) < 0 ||
        (rc = snd_pcm_hw_params_set_buffer_size_near(pcm.handle, hw, &pcm.buffer)) < 0 ||
        (rc = snd_pcm_hw_params(pcm.handle, hw)) < 0) {
        return rc;
    }
    snd_pcm_hw_params_get_period_size(hw, &pcm.period, &dir);
    snd_pcm_hw_params_get_buffer_size(hw, &pcm.buffer);
    if (rate != kRate || pcm.buffer < o.rx_queue + o.rx_slack + pcm.period) {
        stage = "negotiated sizes";
        return -EINVAL;
    }
    stage = "sw_params";
    if ((rc = snd_pcm_sw_params_current(pcm.handle, sw)) < 0 ||
        (rc = snd_pcm_sw_params_get_boundary(sw, &boundary)) < 0 ||
        (rc = snd_pcm_sw_params_set_avail_min(pcm.handle, sw, pcm.period)) < 0 ||
        (rc = snd_pcm_sw_params_set_start_threshold(pcm.handle, sw, boundary)) < 0 ||
        (rc = snd_pcm_sw_params(pcm.handle, sw)) < 0) {
        return rc;
    }
    return 0;
}

// The gadget's two pitch controls. Steward thread only.
struct PitchControl {
    snd_ctl_t* ctl{nullptr};
    snd_ctl_elem_value_t* capture{nullptr};
    snd_ctl_elem_value_t* playback{nullptr};
    int written_capture{0};
    int written_playback{0};

    static void name(snd_ctl_elem_value_t* value, const char* text) {
        snd_ctl_elem_id_t* id = nullptr;
        snd_ctl_elem_id_alloca(&id);
        snd_ctl_elem_id_set_interface(id, SND_CTL_ELEM_IFACE_PCM);
        snd_ctl_elem_id_set_name(id, text);
        snd_ctl_elem_value_set_id(value, id);
    }
    int open(const std::string& pcm_device) {
        const auto comma = pcm_device.find(',');
        const std::string device = comma == std::string::npos ? pcm_device : pcm_device.substr(0, comma);
        int rc = snd_ctl_open(&ctl, device.c_str(), 0);
        if (rc < 0) { ctl = nullptr; return rc; }
        snd_ctl_elem_value_malloc(&capture);
        snd_ctl_elem_value_malloc(&playback);
        name(capture, "Capture Pitch 1000000");
        name(playback, "Playback Pitch 1000000");
        // Read once so a missing control fails here, not on the first write.
        if ((rc = snd_ctl_elem_read(ctl, capture)) < 0 || (rc = snd_ctl_elem_read(ctl, playback)) < 0) {
            close();
            return rc;
        }
        written_capture = static_cast<int>(snd_ctl_elem_value_get_integer(capture, 0));
        written_playback = static_cast<int>(snd_ctl_elem_value_get_integer(playback, 0));
        return 0;
    }
    int write(int capture_pitch, int playback_pitch) {
        if (ctl == nullptr) return 0;
        int first = 0;
        int second = 0;
        if (capture_pitch != written_capture) {
            snd_ctl_elem_value_set_integer(capture, 0, capture_pitch);
            first = snd_ctl_elem_write(ctl, capture);
            if (first >= 0) written_capture = capture_pitch;
        }
        if (playback_pitch != written_playback) {
            snd_ctl_elem_value_set_integer(playback, 0, playback_pitch);
            second = snd_ctl_elem_write(ctl, playback);
            if (second >= 0) written_playback = playback_pitch;
        }
        return first < 0 ? first : (second < 0 ? second : 0);
    }
    void close() {
        if (ctl == nullptr) return;
        // Never leave the gadget pitched for whatever runs next.
        (void)write(kNominalPitch, kNominalPitch);
        snd_ctl_elem_value_free(capture);
        snd_ctl_elem_value_free(playback);
        snd_ctl_close(ctl);
        ctl = nullptr;
    }
};

// The learned clock offset between runs: one number in a small file, replaced
// whole. Never called on the loop thread.
bool read_ppm_file(const std::string& path, double& ppm) {
    FILE* f = std::fopen(path.c_str(), "r");
    if (f == nullptr) return false;
    double value = 0.0;
    const bool ok = std::fscanf(f, "%lf", &value) == 1 && value >= -250.0 && value <= 250.0;
    std::fclose(f);
    if (ok) ppm = value;
    return ok;
}

void write_ppm_file(const std::string& path, const Telemetry& t) {
    if (path.empty() || !t.ppm_known.load(std::memory_order_acquire)) return;
    const std::string temporary = path + ".tmp";
    FILE* f = std::fopen(temporary.c_str(), "w");
    if (f == nullptr) return;
    std::fprintf(f, "%.2f\n", static_cast<double>(t.ppm_estimate_milli.load(std::memory_order_relaxed)) / 1000.0);
    std::fclose(f);
    std::rename(temporary.c_str(), path.c_str());
}

struct StewardContext {
    const Options* options;
    Telemetry* telemetry;
    UsbHandles* handles;
};

// Opens, closes and pitches the gadget, so that none of it happens on the
// loop thread: opening a PCM parses ALSA configuration from the SD card. It
// owns the handles while the owner word says so and never otherwise.
void* steward_entry(void* argument) {
    const StewardContext context = *static_cast<StewardContext*>(argument);
    const Options& o = *context.options;
    Telemetry& t = *context.telemetry;
    UsbHandles& usb = *context.handles;
    PitchControl pitch;
    std::int64_t next_try = 0;
    int last_reported = 1;   // not an ALSA error, so the first failure is printed
    std::int64_t next_ppm_write = now_ns() + 60000000000LL;
    const auto close_all = [&]() {
        pitch.close();
        if (usb.playback.handle != nullptr) { snd_pcm_close(usb.playback.handle); usb.playback.handle = nullptr; }
        if (usb.capture.handle != nullptr) { snd_pcm_close(usb.capture.handle); usb.capture.handle = nullptr; }
    };
    while (!loop_finished.load(std::memory_order_acquire)) {
        timespec nap{0, 20000000};
        nanosleep(&nap, nullptr);
        if (!t.running.load(std::memory_order_acquire)) continue;
        if (now_ns() >= next_ppm_write) {
            next_ppm_write = now_ns() + 60000000000LL;
            write_ppm_file(o.ppm_file, t);
        }
        const auto owner = static_cast<UsbOwner>(t.usb_owner.load(std::memory_order_acquire));
        if (owner == UsbOwner::loop) {
            const int rc = pitch.write(t.wanted_capture_pitch.load(std::memory_order_relaxed),
                                       t.wanted_playback_pitch.load(std::memory_order_relaxed));
            if (rc < 0) t.pitch_write_errors.fetch_add(1, std::memory_order_relaxed);
            continue;
        }
        if (owner == UsbOwner::steward_closing) {
            close_all();
            std::printf("USBCLOSE reason=%" PRId64 " (%s)\n", t.usb_last_fault.load(std::memory_order_relaxed),
                        snd_strerror(static_cast<int>(t.usb_last_fault.load(std::memory_order_relaxed))));
            std::fflush(stdout);
            next_try = now_ns() + 1000000000LL;
            last_reported = 1;
            t.usb_owner.store(static_cast<int>(UsbOwner::steward_absent), std::memory_order_release);
            continue;
        }
        if (now_ns() < next_try) continue;
        next_try = now_ns() + 1000000000LL;
        std::string stage;
        int rc = open_usb(o, SND_PCM_STREAM_CAPTURE, usb.capture, stage);
        if (rc == 0) rc = open_usb(o, SND_PCM_STREAM_PLAYBACK, usb.playback, stage);
        if (rc == 0) {
            stage = "pitch controls";
            rc = pitch.open(o.usb);
        }
        if (rc == 0) {
            stage = "poll descriptors";
            usb.capture_poll_count = snd_pcm_poll_descriptors(usb.capture.handle, usb.capture_poll, 4);
            if (usb.capture_poll_count <= 0) rc = usb.capture_poll_count < 0 ? usb.capture_poll_count : -EIO;
        }
        if (rc < 0) {
            close_all();
            if (rc != last_reported) {
                std::printf("USBOPEN failed stage=%s code=%d (%s); retrying every second\n", stage.c_str(), rc,
                            snd_strerror(rc));
                std::fflush(stdout);
                last_reported = rc;
            }
            continue;
        }
        (void)pitch.write(kNominalPitch, kNominalPitch);
        std::printf("USBOPEN device=%s capture period=%lu buffer=%lu playback period=%lu buffer=%lu\n", o.usb.c_str(),
                    static_cast<unsigned long>(usb.capture.period), static_cast<unsigned long>(usb.capture.buffer),
                    static_cast<unsigned long>(usb.playback.period), static_cast<unsigned long>(usb.playback.buffer));
        std::fflush(stdout);
        last_reported = 1;
        t.usb_owner.store(static_cast<int>(UsbOwner::loop), std::memory_order_release);
    }
    // The loop has returned; whatever is open is ours to close.
    close_all();
    return nullptr;
}

// ---- the USB half: on the loop thread ------------------------------------------------

struct UsbHalf {
    bool attached{false};
    // Out: gadget capture to Dante.
    TxState tx{TxState::idle};
    unsigned tx_idle_wakes{0};
    unsigned tx_holdoff{0};
    bool tx_restart_due{false};   // the gadget capture is stopped and is started again when the holdoff ends
    usb16x16::owner::DepthFilter tx_filter;
    // Back: Dante to gadget playback.
    bool rx_primed{false};
    bool rx_flowing{false};
    unsigned rx_idle_wakes{0};
    unsigned rx_holdoff{0};
    std::int64_t rx_last_after{0};
    usb16x16::owner::DepthFilter rx_filter;
    std::int64_t next_servo_ns{0};
    usb16x16::owner::PitchPi tx_servo;
    usb16x16::owner::PitchPi rx_servo;
    Scratch tx_scratch{};
    Scratch rx_scratch{};
    std::uint32_t out_zero_run{0};
    std::uint32_t back_zero_run{0};
    // The DSP stage on the outgoing direction; null without --dsp-preset.
    usb16x16::owner::OutDsp* dsp{nullptr};
    // The level meters; null without --meter-file.
    usb16x16::owner::OwnerMeters* meters{nullptr};
};

void set_tx_state(UsbHalf& usb, TxState state, Telemetry& t) noexcept {
    usb.tx = state;
    t.tx_state.store(static_cast<int>(state), std::memory_order_relaxed);
    usb.tx_filter.restart();
    if (state != TxState::flow) t.wanted_capture_pitch.store(kNominalPitch, std::memory_order_relaxed);
}

void set_rx_flowing(UsbHalf& usb, bool flowing, Telemetry& t) noexcept {
    usb.rx_flowing = flowing;
    t.rx_flowing.store(flowing, std::memory_order_relaxed);
    usb.rx_filter.restart();
    if (!flowing) t.wanted_playback_pitch.store(kNominalPitch, std::memory_order_relaxed);
}

// Hand the gadget back to the steward to be closed and looked for again.
void detach_usb(UsbHalf& usb, std::int64_t code, Telemetry& t) noexcept {
    usb.attached = false;
    usb.rx_primed = false;
    set_tx_state(usb, TxState::idle, t);
    set_rx_flowing(usb, false, t);
    t.usb_last_fault.store(code, std::memory_order_relaxed);
    t.usb_detaches.fetch_add(1, std::memory_order_relaxed);
    t.usb_owner.store(static_cast<int>(UsbOwner::steward_closing), std::memory_order_release);
}

// A gadget capture error: the outgoing direction stops, and the PCM is
// stopped now and started again when the holdoff ends (service_tx). Started
// here, as it was until 2026-10-11, it ran unread through a holdoff five
// times as long as its buffer, overran, and faulted again at the first read,
// for ever: one loop stall with a host sending and the outgoing direction
// never came back (2,500 faults in two minutes, RESULTS.md). Nothing here
// touches an Inferno handle.
void capture_fault(UsbHalf& usb, UsbHandles& handles, std::int64_t code, Telemetry& t) noexcept {
    t.usb_capture_faults.fetch_add(1, std::memory_order_relaxed);
    t.usb_last_fault.store(code, std::memory_order_relaxed);
    set_tx_state(usb, TxState::idle, t);
    usb.tx_idle_wakes = 0;
    usb.tx_holdoff = kFaultHoldoffWakes;
    usb.tx_restart_due = true;
    snd_pcm_drop(handles.capture.handle);
    // A gadget that has gone is handed back at once, as before, not after the holdoff.
    if (code == -ENODEV) detach_usb(usb, code, t);
}

void playback_fault(UsbHalf& usb, UsbHandles& handles, std::int64_t code, Telemetry& t) noexcept {
    t.usb_playback_faults.fetch_add(1, std::memory_order_relaxed);
    t.usb_last_fault.store(code, std::memory_order_relaxed);
    set_rx_flowing(usb, false, t);
    usb.rx_primed = false;
    usb.rx_idle_wakes = 0;
    usb.rx_holdoff = kFaultHoldoffWakes;
    snd_pcm_drop(handles.playback.handle);
    const int rc = snd_pcm_prepare(handles.playback.handle);
    if (rc < 0) detach_usb(usb, rc, t);
}

// Gadget capture (packed 24-bit) into interleaved S32, newest frames last.
// Returns frames read, 0 for none, or a negative ALSA error.
long read_gadget(UsbPcm& pcm, std::int32_t* destination) noexcept {
    snd_pcm_sframes_t available = snd_pcm_avail_update(pcm.handle);
    if (available <= 0) return available == -EAGAIN ? 0 : static_cast<long>(available);
    if (static_cast<std::size_t>(available) > kScratchFrames) {
        // More than the scratch holds can only follow a long stall: keep the newest.
        const snd_pcm_sframes_t skipped = snd_pcm_forward(pcm.handle, static_cast<snd_pcm_uframes_t>(available) - kScratchFrames);
        if (skipped < 0) return static_cast<long>(skipped);
        available = static_cast<snd_pcm_sframes_t>(kScratchFrames);
    }
    long total = 0;
    auto remaining = static_cast<snd_pcm_uframes_t>(available);
    while (remaining > 0) {
        const snd_pcm_channel_area_t* areas = nullptr;
        snd_pcm_uframes_t offset = 0;
        snd_pcm_uframes_t run = remaining;
        const int begin = snd_pcm_mmap_begin(pcm.handle, &areas, &offset, &run);
        if (begin < 0) return begin == -EAGAIN ? total : begin;
        if (run == 0) break;
        for (unsigned channel = 0; channel < kChannels; ++channel) {
            const auto* source = static_cast<const std::uint8_t*>(areas[channel].addr) +
                                 (areas[channel].first + offset * areas[channel].step) / 8;
            const std::size_t step = areas[channel].step / 8;
            std::int32_t* out = destination + static_cast<std::size_t>(total) * kChannels + channel;
            for (snd_pcm_uframes_t frame = 0; frame < run; ++frame) {
                // 24 bits into the top of 32, low byte zero: what the Dante side carries.
                *out = static_cast<std::int32_t>((static_cast<std::uint32_t>(source[0]) << 8) |
                                                 (static_cast<std::uint32_t>(source[1]) << 16) |
                                                 (static_cast<std::uint32_t>(source[2]) << 24));
                out += kChannels;
                source += step;
            }
        }
        const snd_pcm_sframes_t done = snd_pcm_mmap_commit(pcm.handle, offset, run);
        if (done < 0) return static_cast<long>(done);
        total += done;
        remaining -= static_cast<snd_pcm_uframes_t>(done);
    }
    return total;
}

// Interleaved S32 (or silence when null) into the gadget playback queue as
// packed 24-bit. Returns frames written or a negative ALSA error.
long write_gadget(UsbPcm& pcm, const std::int32_t* source, snd_pcm_uframes_t frames) noexcept {
    long total = 0;
    while (frames > 0) {
        const snd_pcm_channel_area_t* areas = nullptr;
        snd_pcm_uframes_t offset = 0;
        snd_pcm_uframes_t run = frames;
        const int begin = snd_pcm_mmap_begin(pcm.handle, &areas, &offset, &run);
        if (begin < 0) return begin;
        if (run == 0) return -ENOSPC;
        for (unsigned channel = 0; channel < kChannels; ++channel) {
            auto* out = static_cast<std::uint8_t*>(areas[channel].addr) +
                        (areas[channel].first + offset * areas[channel].step) / 8;
            const std::size_t step = areas[channel].step / 8;
            const std::int32_t* in = source != nullptr ? source + static_cast<std::size_t>(total) * kChannels + channel : nullptr;
            for (snd_pcm_uframes_t frame = 0; frame < run; ++frame) {
                const std::uint32_t sample = in != nullptr ? static_cast<std::uint32_t>(*in) : 0U;
                out[0] = static_cast<std::uint8_t>(sample >> 8);
                out[1] = static_cast<std::uint8_t>(sample >> 16);
                out[2] = static_cast<std::uint8_t>(sample >> 24);
                out += step;
                if (in != nullptr) in += kChannels;
            }
        }
        const snd_pcm_sframes_t done = snd_pcm_mmap_commit(pcm.handle, offset, run);
        if (done < 0) return static_cast<long>(done);
        total += done;
        frames -= static_cast<snd_pcm_uframes_t>(done);
    }
    return total;
}

// Peak of channels 1 and 2 over a block of interleaved S32, into two atomics.
void observe_peaks(const std::int32_t* block, long frames, std::atomic<std::int32_t>& first,
                   std::atomic<std::int32_t>& second) noexcept {
    std::int32_t peak_1 = 0;
    std::int32_t peak_2 = 0;
    for (long frame = 0; frame < frames; ++frame) {
        const std::int32_t a = block[static_cast<std::size_t>(frame) * kChannels] >> 8;
        const std::int32_t b = block[static_cast<std::size_t>(frame) * kChannels + 1] >> 8;
        peak_1 = std::max(peak_1, a < 0 ? -a : a);
        peak_2 = std::max(peak_2, b < 0 ? -b : b);
    }
    if (peak_1 > first.load(std::memory_order_relaxed)) first.store(peak_1, std::memory_order_relaxed);
    if (peak_2 > second.load(std::memory_order_relaxed)) second.store(peak_2, std::memory_order_relaxed);
}

void add_meter_cost(Telemetry& t, std::int64_t spent) noexcept {
    store_max(t.meter_ns_max, spent);
    t.meter_ns_total.fetch_add(static_cast<std::uint64_t>(spent), std::memory_order_relaxed);
    t.meter_calls.fetch_add(1, std::memory_order_relaxed);
}

// The outgoing block through the DSP stage, in place, and past the two
// outgoing meters, each with what it cost. Without a preset the block is not
// changed and both meters see the same samples.
void run_dsp(UsbHalf& usb, std::int32_t* block, std::int64_t frames, Telemetry& t) noexcept {
    const auto count = static_cast<std::size_t>(frames);
    if (usb.dsp == nullptr || !usb.dsp->ready(count)) {
        if (usb.meters != nullptr) {
            const std::int64_t before = now_ns();
            usb.meters->observe(block, count, usb.meters->usb_capture, &usb.meters->dante_playback);
            add_meter_cost(t, now_ns() - before);
        }
        return;
    }
    const std::int64_t t0 = now_ns();
    usb.dsp->to_float(block, count);
    const std::int64_t t1 = now_ns();
    if (usb.meters != nullptr) usb.meters->usb_capture.observe(usb.dsp->floats(), count);
    const std::int64_t t2 = now_ns();
    usb.dsp->filter(count);
    const std::int64_t t3 = now_ns();
    if (usb.meters != nullptr) usb.meters->dante_playback.observe(usb.dsp->floats(), count);
    const std::int64_t t4 = now_ns();
    usb.dsp->from_float(block, count);
    const std::int64_t spent = (t1 - t0) + (t3 - t2) + (now_ns() - t4);
    store_max(t.dsp_ns_max, spent);
    t.dsp_ns_total.fetch_add(static_cast<std::uint64_t>(spent), std::memory_order_relaxed);
    t.dsp_calls.fetch_add(1, std::memory_order_relaxed);
    if (usb.meters != nullptr) add_meter_cost(t, (t2 - t1) + (t4 - t3));
}

constexpr std::uint32_t kHoleMinFrames = 8;
constexpr std::uint32_t kHoleMaxFrames = 4800;

// Count runs of all-zero frames that end in signal (see Telemetry::out_holes). `run` carries
// the open run from block to block; a run longer than kHoleMaxFrames is silence, not a hole.
void observe_holes(const std::int32_t* block, long frames, std::uint32_t& run, std::atomic<std::uint64_t>& count,
                   std::atomic<std::uint32_t>& longest) noexcept {
    for (long frame = 0; frame < frames; ++frame) {
        const std::int32_t* samples = block + static_cast<std::size_t>(frame) * kChannels;
        std::int32_t any = 0;
        for (unsigned channel = 0; channel < kChannels; ++channel) any |= samples[channel];
        if (any == 0) {
            if (run <= kHoleMaxFrames) ++run;
            continue;
        }
        if (run >= kHoleMinFrames && run <= kHoleMaxFrames) {
            count.fetch_add(1, std::memory_order_relaxed);
            if (run > longest.load(std::memory_order_relaxed)) longest.store(run, std::memory_order_relaxed);
        }
        run = 0;
    }
}

// Out, one wake. `depth` is the Inferno playback depth as observed this wake
// and is updated by what is written. False only on an Inferno error.
bool service_tx(UsbHalf& usb, UsbHandles& handles, NetHalf& net, std::int64_t& depth, bool resynced,
                Telemetry& t) noexcept {
    if (usb.tx_holdoff > 0) {
        if (--usb.tx_holdoff == 0 && usb.tx_restart_due) {
            usb.tx_restart_due = false;
            int rc = snd_pcm_prepare(handles.capture.handle);
            if (rc == 0) rc = snd_pcm_start(handles.capture.handle);
            if (rc < 0) detach_usb(usb, rc, t);
        }
        return true;
    }
    const long frames = read_gadget(handles.capture, usb.tx_scratch.data());
    if (frames < 0) {
        capture_fault(usb, handles, frames, t);
        return true;
    }
    if (frames == 0) {
        // A flowing host that sends nothing while the pointer is within a wake
        // of the clock has stopped (a block that is merely late leaves the
        // depth a wake higher): it counts as stopped now, so the lead is kept
        // up with silence from this wake on. Waiting out kIdleWakes here let
        // the clock pass the pointer on every wake, 98 resyncs in 100 ms.
        const bool starved = usb.tx == TxState::flow &&
                             depth < static_cast<std::int64_t>(handles.capture.period + kResyncMargin);
        if (starved || (usb.tx != TxState::idle && ++usb.tx_idle_wakes >= kIdleWakes)) set_tx_state(usb, TxState::idle, t);
        return true;
    }
    usb.tx_idle_wakes = 0;
    observe_peaks(usb.tx_scratch.data(), frames, t.out_peak_1, t.out_peak_2);
    observe_holes(usb.tx_scratch.data(), frames, usb.out_zero_run, t.out_holes, t.out_hole_max);
    const auto lead = static_cast<std::int64_t>(net.lead);
    const std::int64_t ceiling = static_cast<std::int64_t>(net.playback.buffer) - static_cast<std::int64_t>(net.guard) -
                                 static_cast<std::int64_t>(net.playback.period);
    if (usb.tx == TxState::idle) {
        // The first block after silence is whatever the gadget had queued: discard it and prime on the next.
        set_tx_state(usb, TxState::armed, t);
        return true;
    }
    if (usb.tx == TxState::flow && (resynced || depth < kPacketFrames || depth + frames > ceiling)) {
        // The pointer is no longer where the prime put it (a stall, or the
        // servo lost the depth): set it again rather than run on at a depth
        // nobody chose. This block is discarded like the first after silence.
        t.tx_reprimes.fetch_add(1, std::memory_order_relaxed);
        set_tx_state(usb, TxState::armed, t);
        return true;
    }
    if (usb.tx == TxState::armed) {
        if (depth >= lead) return true;   // still above the lead: let the clock take it down
        // Prime only on an ordinary block. A larger one means frames the host
        // sent earlier are still arriving (after a stall the gadget delivers
        // its backlog over more than one wake), and a prime made then is deeper
        // than the lead by whatever arrives next: 37 frames on 2026-10-09.
        if (static_cast<snd_pcm_uframes_t>(frames) > handles.capture.period + handles.capture.period / 2) return true;
        // Land this block so that the pointer ends exactly `lead` ahead of the
        // clock: skip forward over silence, or drop the block's oldest frames.
        const std::int64_t room = lead - depth;
        const std::int64_t take = std::min<std::int64_t>(frames, room);
        skip_playback(net, static_cast<snd_pcm_uframes_t>(room - take));
        std::int32_t* const primed = usb.tx_scratch.data() + static_cast<std::size_t>(frames - take) * kChannels;
        if (usb.dsp != nullptr) {
            // A prime follows a gap: the filters start from silence, not from the tail of what played before it.
            usb.dsp->reset();
            t.dsp_resets.fetch_add(1, std::memory_order_relaxed);
        }
        run_dsp(usb, primed, take, t);
        if (!commit_playback(net, primed, static_cast<snd_pcm_uframes_t>(take), t)) {
            return false;
        }
        depth = lead;
        t.usb_tx_frames.fetch_add(static_cast<std::uint64_t>(take), std::memory_order_relaxed);
        t.tx_links.fetch_add(1, std::memory_order_relaxed);
        t.tx_prime_block.store(frames, std::memory_order_relaxed);
        t.tx_prime_found.store(lead - room, std::memory_order_relaxed);
        // Both directions see the same two clocks with opposite sign.
        usb.tx_servo.restart(usb.rx_flowing && usb.rx_servo.settled() ? -usb.rx_servo.integral() : usb.tx_servo.integral());
        set_tx_state(usb, TxState::flow, t);
        t.wanted_capture_pitch.store(usb16x16::owner::pitch_value(usb.tx_servo.output(), -1), std::memory_order_relaxed);
        return true;
    }
    run_dsp(usb, usb.tx_scratch.data(), frames, t);
    if (!commit_playback(net, usb.tx_scratch.data(), static_cast<snd_pcm_uframes_t>(frames), t)) return false;
    depth += frames;
    t.usb_tx_frames.fetch_add(static_cast<std::uint64_t>(frames), std::memory_order_relaxed);
    usb.tx_filter.add(static_cast<int>(depth));
    return true;
}

// Back, one wake: `frames` of Dante audio in the scratch, newest last.
void service_rx(UsbHalf& usb, UsbHandles& handles, const Options& o, long frames, Telemetry& t) noexcept {
    if (usb.rx_holdoff > 0) {
        --usb.rx_holdoff;
        return;
    }
    UsbPcm& pcm = handles.playback;
    // snd_pcm_avail, not avail_update: on a kernel PCM the mmap'd pointer only
    // moves when the driver reports a period, so avail_update can be most of a
    // period stale, by an amount that slides with the host's packet phase. That
    // staleness is the queue that "read 37 frames high" for seconds at a time on
    // 2026-10-09. snd_pcm_avail asks the driver where the pointer is now.
    const snd_pcm_sframes_t available = snd_pcm_avail(pcm.handle);
    if (available < 0) {
        playback_fault(usb, handles, available, t);
        return;
    }
    const std::int64_t queue = static_cast<std::int64_t>(pcm.buffer) - available;
    const auto target = static_cast<std::int64_t>(o.rx_queue);
    if (!usb.rx_primed) {
        // The queue is set to exactly the target: silence, then the newest Dante frames, then start.
        const std::int64_t real = std::min<std::int64_t>(frames, target);
        long rc = write_gadget(pcm, nullptr, static_cast<snd_pcm_uframes_t>(target - real));
        if (rc >= 0 && real > 0) {
            rc = write_gadget(pcm, usb.rx_scratch.data() + static_cast<std::size_t>(frames - real) * kChannels,
                              static_cast<snd_pcm_uframes_t>(real));
        }
        if (rc >= 0) rc = snd_pcm_start(pcm.handle);
        if (rc < 0) {
            playback_fault(usb, handles, rc, t);
            return;
        }
        usb.rx_primed = true;
        usb.rx_last_after = target;
        usb.rx_idle_wakes = 0;
        t.rx_primes.fetch_add(1, std::memory_order_relaxed);
        t.usb_rx_frames.fetch_add(static_cast<std::uint64_t>(real), std::memory_order_relaxed);
        return;
    }
    store_min(t.rx_depth_min, queue);
    store_max(t.rx_depth_max, queue);
    // The host is pulling when the queue went down since the last write.
    if (usb.rx_last_after - queue > 0) {
        usb.rx_idle_wakes = 0;
        if (!usb.rx_flowing) {
            usb.rx_servo.restart(usb.tx == TxState::flow && usb.tx_servo.settled() ? -usb.tx_servo.integral()
                                                                                   : usb.rx_servo.integral());
            set_rx_flowing(usb, true, t);
            t.wanted_playback_pitch.store(usb16x16::owner::pitch_value(usb.rx_servo.output(), +1), std::memory_order_relaxed);
        }
    } else if (usb.rx_flowing && ++usb.rx_idle_wakes >= kIdleWakes) {
        // The host has stopped pulling. In the hundred wakes it took to be sure,
        // the queue filled to the slack limit (240 on 2026-10-10), and a queue
        // cannot be emptied from this side: left alone, the host would resume
        // 96 frames deeper than the target, and no pitch setting takes frames
        // out of the round trip again. So the queue is thrown away and primed
        // afresh, to sit at exactly the target until a host pulls.
        set_rx_flowing(usb, false, t);
        usb.rx_primed = false;
        usb.rx_idle_wakes = 0;
        snd_pcm_drop(pcm.handle);
        const int rc = snd_pcm_prepare(pcm.handle);
        if (rc < 0) detach_usb(usb, rc, t);
        return;
    }
    // With the host pulling, the queue may run over the target by the slack
    // before anything is dropped. With no host it is held at the target, so
    // that the depth is the chosen one at the moment a host starts.
    const std::int64_t limit = usb.rx_flowing ? target + static_cast<std::int64_t>(o.rx_slack) : target;
    const std::int64_t room = std::max<std::int64_t>(0, limit - queue);
    const std::int64_t take = std::min<std::int64_t>(frames, room);
    if (frames > take) {
        (usb.rx_flowing ? t.rx_overflow : t.rx_idle_discards)
            .fetch_add(static_cast<std::uint64_t>(frames - take), std::memory_order_relaxed);
    }
    if (take > 0) {
        const long rc = write_gadget(pcm, usb.rx_scratch.data() + static_cast<std::size_t>(frames - take) * kChannels,
                                     static_cast<snd_pcm_uframes_t>(take));
        if (rc < 0) {
            playback_fault(usb, handles, rc, t);
            return;
        }
        t.usb_rx_frames.fetch_add(static_cast<std::uint64_t>(take), std::memory_order_relaxed);
    }
    usb.rx_last_after = queue + take;
    if (usb.rx_flowing) {
        usb.rx_filter.add(static_cast<int>(usb.rx_last_after));
    }
}

// Once a second: each flowing direction's mean depth through its PI law.
void run_servos(UsbHalf& usb, const Options& o, std::int64_t now, Telemetry& t) noexcept {
    if (now < usb.next_servo_ns) return;
    const double interval = usb.next_servo_ns == 0 ? 1.0 : 1.0 + static_cast<double>(now - usb.next_servo_ns) / 1e9;
    usb.next_servo_ns = now + 1000000000LL;
    double figure = 0.0;
    const bool tx_closed = usb.tx_filter.finish(figure);
    if (usb.tx == TxState::flow && tx_closed) {
        const double offset = usb.tx_servo.update(figure - static_cast<double>(o.tx_lead), interval);
        t.wanted_capture_pitch.store(usb16x16::owner::pitch_value(offset, -1), std::memory_order_relaxed);
        t.tx_integral_milli.store(std::llround(usb.tx_servo.integral() * 1000.0), std::memory_order_relaxed);
    }
    t.tx_mean_milli.store(std::llround(usb.tx_filter.last_figure() * 1000.0), std::memory_order_relaxed);
    const bool rx_closed = usb.rx_filter.finish(figure);
    if (usb.rx_flowing && rx_closed) {
        const double offset = usb.rx_servo.update(figure - static_cast<double>(o.rx_queue), interval);
        t.wanted_playback_pitch.store(usb16x16::owner::pitch_value(offset, +1), std::memory_order_relaxed);
        t.rx_integral_milli.store(std::llround(usb.rx_servo.integral() * 1000.0), std::memory_order_relaxed);
    }
    t.rx_mean_milli.store(std::llround(usb.rx_filter.last_figure() * 1000.0), std::memory_order_relaxed);
    t.servo_rejected.store(usb.tx_filter.rejected() + usb.rx_filter.rejected(), std::memory_order_relaxed);
    // The host's clock against Dante's, as far as either loop has learned it:
    // what the next start is seeded with.
    const bool tx_knows = usb.tx == TxState::flow && usb.tx_servo.settled();
    const bool rx_knows = usb.rx_flowing && usb.rx_servo.settled();
    if (tx_knows || rx_knows) {
        const double estimate = tx_knows && rx_knows ? 0.5 * (usb.tx_servo.integral() - usb.rx_servo.integral())
                                : tx_knows ? usb.tx_servo.integral() : -usb.rx_servo.integral();
        t.ppm_estimate_milli.store(std::llround(estimate * 1000.0), std::memory_order_relaxed);
        t.ppm_known.store(true, std::memory_order_release);
    }
}

// One wake of the whole owner. False on an Inferno error, which the design has
// no answer to short of the prepare it forbids.
bool service(NetHalf& net, UsbHalf& usb, UsbHandles& handles, const Options& o, std::int64_t now, Telemetry& t) noexcept {
    // The gadget arrives and leaves through the owner word.
    const bool loop_owns = t.usb_owner.load(std::memory_order_acquire) == static_cast<int>(UsbOwner::loop);
    if (loop_owns && !usb.attached) {
        usb.attached = true;
        usb.rx_primed = false;
        usb.tx_holdoff = 0;
        usb.tx_restart_due = false;
        usb.rx_holdoff = 0;
        const int rc = snd_pcm_start(handles.capture.handle);
        if (rc < 0) detach_usb(usb, rc, t);
    }

    const long received = take_capture(net, usb.attached ? usb.rx_scratch.data() : nullptr, t);
    if (received < 0) return false;

    std::int64_t depth = 0;
    bool resynced = false;
    if (!observe_playback(net, depth, resynced, t)) return false;

    if (usb.attached && !service_tx(usb, handles, net, depth, resynced, t)) return false;
    if (usb.attached) {
        observe_peaks(usb.rx_scratch.data(), received, t.back_peak_1, t.back_peak_2);
        observe_holes(usb.rx_scratch.data(), received, usb.back_zero_run, t.back_holes, t.back_hole_max);
        if (usb.meters != nullptr && received > 0) {
            const std::int64_t before = now_ns();
            usb.meters->observe(usb.rx_scratch.data(), static_cast<std::size_t>(received), usb.meters->dante_capture);
            add_meter_cost(t, now_ns() - before);
        }
        service_rx(usb, handles, o, received, t);
    }
    if (usb.attached) run_servos(usb, o, now, t);

    // No block went through the stage on this wake: take any coefficient set
    // published meanwhile, so the next live update is not left waiting for a host.
    if (usb.dsp != nullptr && usb.tx != TxState::flow) usb.dsp->take();

    // With nothing flowing out, the lead is kept up with silence.
    if (usb.tx != TxState::flow && depth < static_cast<std::int64_t>(net.lead)) {
        return commit_playback(net, nullptr, static_cast<snd_pcm_uframes_t>(static_cast<std::int64_t>(net.lead) - depth), t);
    }
    return true;
}

pthread_t start_thread(void* (*entry)(void*), void* argument, const char* what) {
    pthread_t thread{};
    pthread_attr_t attributes;
    pthread_attr_init(&attributes);
    pthread_attr_setstacksize(&attributes, 256 * 1024);
    const int created = pthread_create(&thread, &attributes, entry, argument);
    pthread_attr_destroy(&attributes);
    if (created != 0) {
        std::printf("FATAL %s thread: %s\n", what, std::strerror(created));
        std::exit(1);
    }
    return thread;
}

}  // namespace

int main(int argc, char** argv) {
    // The wall clock this process began at: a live file older than this is a preview left behind.
    timespec process_started{};
    clock_gettime(CLOCK_REALTIME, &process_started);
    Options options = parse_options(argc, argv);
    bool seed_from_file = false;
    if (!options.seed_given && !options.ppm_file.empty()) seed_from_file = read_ppm_file(options.ppm_file, options.seed_ppm);
    std::signal(SIGINT, on_signal);
    std::signal(SIGTERM, on_signal);
    std::setvbuf(stdout, nullptr, _IOLBF, 0);

    std::printf("START usb16x16-dante-owner mode=%s pcm=%s period=%lu buffer=%lu tx_lead=%lu guard=%lu priority=%d "
                "mlock=%d rt=%d seconds=%u usb=%s usb_period=%lu usb_buffer=%lu rx_queue=%lu rx_slack=%lu kp=%g ki=%g "
                "seed_ppm=%g seed_from_file=%d\n",
                options.no_usb ? "no-usb" : "usb", options.pcm.c_str(), static_cast<unsigned long>(options.period),
                static_cast<unsigned long>(options.buffer), static_cast<unsigned long>(options.tx_lead),
                static_cast<unsigned long>(options.guard), options.priority, options.mlock ? 1 : 0,
                options.realtime ? 1 : 0, options.seconds, options.usb.c_str(),
                static_cast<unsigned long>(options.usb_period), static_cast<unsigned long>(options.usb_buffer),
                static_cast<unsigned long>(options.rx_queue), static_cast<unsigned long>(options.rx_slack), options.kp,
                options.ki, options.seed_ppm, seed_from_file ? 1 : 0);

    // 0. The preset, before anything is opened: an owner asked for DSP that ran
    // without it would be measured as if it had filtered.
    static usb16x16::owner::OutDsp dsp;
    if (!options.dsp_preset.empty()) {
        if (options.no_usb) usage("--dsp-preset needs the USB half: the stage is on the gadget-to-Dante direction");
        std::ifstream preset_file(options.dsp_preset, std::ios::binary);
        std::stringstream preset_text;
        preset_text << preset_file.rdbuf();
        if (!preset_file) {
            std::printf("FATAL DSP preset %s cannot be read\n", options.dsp_preset.c_str());
            return 2;
        }
        try {
            dsp.load(preset_text.str());
        } catch (const std::exception& error) {
            std::printf("FATAL DSP preset %s: %s\n", options.dsp_preset.c_str(), error.what());
            return 2;
        }
        std::printf("DSP loaded file=%s preset=\"%s\" internal=%zu biquads=%zu delay_frames=%zu shape=%s\n",
                    options.dsp_preset.c_str(), dsp.stage().preset().c_str(), dsp.stage().internal_channels(),
                    dsp.stage().biquad_count(), dsp.stage().delay_samples(), dsp.stage().shape_key().c_str());
        if (!options.dsp_live_file.empty()) {
            std::printf("DSPLIVE following file=%s status=%s\n", options.dsp_live_file.c_str(),
                        options.dsp_live_status.c_str());
        }
    }

    // 1. Memory lock first, so every stack made below is populated when it is made.
    if (options.mlock && mlockall(MCL_CURRENT | MCL_FUTURE) != 0) {
        std::printf("FATAL mlockall: %s\n", std::strerror(errno));
        return 1;
    }

    // 2. The owner's own threads, before the device exists. They idle until `running`.
    static Telemetry telemetry;
    static UsbHandles handles;
    static UsbHalf usb;
    usb.tx_servo = usb16x16::owner::PitchPi({options.kp, options.ki, 250.0});
    usb.rx_servo = usb16x16::owner::PitchPi({options.kp, options.ki, 250.0});
    usb.tx_servo.restart(options.seed_ppm);
    usb.rx_servo.restart(-options.seed_ppm);
    if (dsp.enabled()) usb.dsp = &dsp;
    TelemetryContext telemetry_context{&telemetry, options.log_every, options.no_usb};
    StewardContext steward_context{&options, &telemetry, &handles};
    const pthread_t telemetry_thread = start_thread(telemetry_entry, &telemetry_context, "telemetry");
    pthread_t steward_thread{};
    if (!options.no_usb) steward_thread = start_thread(steward_entry, &steward_context, "steward");
    usb16x16::owner::DspLive dsp_live(dsp.stage(), options.dsp_live_file, options.dsp_live_status, process_started);
    DspLiveContext dsp_live_context{&dsp_live, &dsp.stage(), &telemetry};
    pthread_t dsp_live_thread{};
    const bool live_enabled = dsp.enabled() && !options.dsp_live_file.empty();
    if (live_enabled) dsp_live_thread = start_thread(dsp_live_entry, &dsp_live_context, "dsp live");
    static usb16x16::owner::OwnerMeters meters;
    usb16x16::owner::MeterPublisher meter_publisher(meters, options.meter_file);
    MeterContext meter_context{&meter_publisher, &telemetry};
    pthread_t meter_thread{};
    const bool meters_enabled = !options.meter_file.empty() && !options.no_usb;
    if (meters_enabled) {
        usb.meters = &meters;
        meter_thread = start_thread(meter_entry, &meter_context, "meters");
        std::printf("METERS publishing file=%s window_frames=%zu\n", options.meter_file.c_str(),
                    meters.usb_capture.window_frames());
    }
    thread_inventory("before-open", true);

    // 3. The Inferno device, at normal priority: its control threads inherit the opener's policy.
    NetHalf net;
    net.capture = open_net(options, SND_PCM_STREAM_CAPTURE);
    net.playback = open_net(options, SND_PCM_STREAM_PLAYBACK);
    net.lead = options.tx_lead;
    net.guard = options.guard;
    const std::int64_t opened = now_ns();
    const bool have_rx = wait_for_thread("flows RX", 3000);
    const bool have_tx = wait_for_thread("flows TX", 3000);
    std::printf("NETTHREADS flows_rx=%d flows_tx=%d waited_ms=%" PRId64 "\n", have_rx ? 1 : 0, have_tx ? 1 : 0,
                (now_ns() - opened) / 1000000);
    if (!have_rx || !have_tx) {
        std::printf("FATAL the plugin's network threads did not appear\n");
        return 1;
    }
    thread_inventory("after-open", true);

    // 4. The lead as silence, then the one start of each stream.
    if (!commit_playback(net, nullptr, net.lead, telemetry)) {
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
    // 6. Release the telemetry and, with it, the steward to look for the gadget.
    telemetry.running.store(true, std::memory_order_release);

    const std::int64_t started = now_ns();
    std::int64_t next = started + kTickNs;
    std::int64_t last_wake = started;
    int exit_code = 0;
    bool stalled = false;
    while (!stop_requested.load(std::memory_order_relaxed)) {
        // While a host is sending, its frames time the loop; otherwise a 1 ms grid does.
        if (usb.attached && usb.tx != TxState::idle && usb.tx_holdoff == 0) {
            timespec timeout{0, static_cast<long>(kTickNs)};
            ppoll(handles.capture_poll, static_cast<nfds_t>(handles.capture_poll_count), &timeout, nullptr);
            next = now_ns() + kTickNs;
        } else {
            timespec target{};
            target.tv_sec = static_cast<time_t>(next / 1000000000LL);
            target.tv_nsec = static_cast<long>(next % 1000000000LL);
            clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &target, nullptr);
            next += kTickNs;
        }
        const std::int64_t now = now_ns();
        store_max(telemetry.gap_us_max, (now - last_wake) / 1000);
        last_wake = now;
        telemetry.wakes.fetch_add(1, std::memory_order_relaxed);
        if (!service(net, usb, handles, options, now, telemetry)) {
            // Not recoverable by design: a prepare here is the six-second dropout.
            exit_code = 3;
            break;
        }
        if (options.stall_at != 0 && !stalled && now - started >= static_cast<std::int64_t>(options.stall_at) * 1000000000LL) {
            stalled = true;
            timespec stall{0, static_cast<long>(options.stall_ms) * 1000000L};
            nanosleep(&stall, nullptr);
            telemetry.stall_injected_ms.store(options.stall_ms, std::memory_order_relaxed);
        }
        if (next < now) next = now + kTickNs;   // a stall: do not run a burst of catch-up wakes
        if (options.seconds != 0 && now - started >= static_cast<std::int64_t>(options.seconds) * 1000000000LL) break;
    }
    stop_requested.store(true, std::memory_order_relaxed);
    loop_finished.store(true, std::memory_order_release);
    if (!options.no_usb) pthread_join(steward_thread, nullptr);   // closes the gadget and puts the pitch back
    write_ppm_file(options.ppm_file, telemetry);
    if (live_enabled) pthread_join(dsp_live_thread, nullptr);
    if (meters_enabled) pthread_join(meter_thread, nullptr);
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
    if (!options.no_usb) {
        std::printf("USBSUMMARY usb_tx=%" PRIu64 " usb_rx=%" PRIu64 " tx_links=%" PRIu64 " tx_reprimes=%" PRIu64
                    " rx_primes=%" PRIu64 " rx_overflow=%" PRIu64 " rx_idle_discards=%" PRIu64 " capture_faults=%" PRIu64
                    " playback_faults=%" PRIu64 " detaches=%" PRIu64 " pitch_write_errors=%" PRIu64
                    " servo_rejected=%" PRIu64 " tx_integral_ppm=%.2f rx_integral_ppm=%.2f out_holes=%" PRIu64
                    "/%u back_holes=%" PRIu64 "/%u\n",
                    telemetry.usb_tx_frames.load(), telemetry.usb_rx_frames.load(), telemetry.tx_links.load(),
                    telemetry.tx_reprimes.load(), telemetry.rx_primes.load(), telemetry.rx_overflow.load(),
                    telemetry.rx_idle_discards.load(), telemetry.usb_capture_faults.load(),
                    telemetry.usb_playback_faults.load(), telemetry.usb_detaches.load(),
                    telemetry.pitch_write_errors.load(), telemetry.servo_rejected.load(), usb.tx_servo.integral(),
                    usb.rx_servo.integral(), telemetry.out_holes.load(), telemetry.out_hole_max.load(),
                    telemetry.back_holes.load(), telemetry.back_hole_max.load());
    }
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
