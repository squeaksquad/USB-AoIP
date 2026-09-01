#include "usb16x16/bridge_core.hpp"

#include <alsa/asoundlib.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <cmath>
#include <csignal>
#include <cstdint>
#include <cstring>
#include <iomanip>
#include <iostream>
#include <limits>
#include <memory>
#include <poll.h>
#include <pthread.h>
#include <sched.h>
#include <stdexcept>
#include <string>
#include <string_view>
#include <sys/mman.h>
#include <thread>
#include <unistd.h>
#include <vector>

namespace {

using usb16x16::kChannels;

constexpr std::size_t kScratchFrames = 512;
constexpr std::uint64_t kTelemetryIntervalFrames = 480;
constexpr std::size_t kServoSamplesPerUpdate = 100;
constexpr std::size_t kMinimumRateSamples = 60;
constexpr double kDifferentialFramesPerSecondPerPpm =
    2.0 * usb16x16::kNominalRate * 1.0e-6;

std::atomic<bool> stop_requested{false};

void signal_handler(int) {
    stop_requested.store(true, std::memory_order_relaxed);
}

enum class SampleFormat { s24_3le, s32_le };

struct Options {
    std::string usb_device{"hw:CARD=UAC2Gadget,DEV=0"};
    std::string ravenna_device{"hw:CARD=RAVENNA,DEV=0"};
    unsigned int rate{48000};
    snd_pcm_uframes_t requested_period{96};
    snd_pcm_uframes_t requested_buffer{384};
    std::size_t ring_frames{768};
    std::size_t target_frames{192};
    // Frames to prime into the ALSA playback queue. Zero means "the whole
    // playback buffer", which is the historical behaviour. This is the
    // ring/queue split knob: the elastic ring holds target_frames as the jitter
    // reservoir, and this sets how much sits in the device queue behind it.
    std::size_t playback_prime_frames{0};
    // Discard the ring overshoot at prime time. The ring is only checked on
    // capture wakeups, so it can sail past the prime threshold by most of a
    // capture period, and that excess becomes permanent pipeline depth because
    // depth is conserved after priming. Off by default: historical behaviour.
    bool prime_trim{false};
    // Per-direction overrides of playback_prime_frames; zero inherits it. The
    // two directions do not carry the same slack -- measured at prime 192, RX's
    // queue floor sat at 285 while TX's was 113 -- so one shared prime tunes
    // the roomy direction and the binding one together. tx is usb-to-ravenna
    // (RAVENNA playback), rx is ravenna-to-usb (USB playback).
    std::size_t tx_playback_prime_frames{0};
    std::size_t rx_playback_prime_frames{0};
    int priority{90};
    unsigned int seconds{0};
};

[[noreturn]] void usage(const char* executable, const std::string& error = {}) {
    if (!error.empty()) {
        std::cerr << "error: " << error << "\n\n";
    }
    std::cerr
        << "usage: " << executable << " [options]\n"
        << "  --usb DEVICE           raw UAC2 ALSA device\n"
        << "  --ravenna DEVICE       raw RAVENNA ALSA device\n"
        << "  --period FRAMES        requested ALSA period (48 or 96; default 96)\n"
        << "  --buffer FRAMES        requested ALSA buffer (default 384)\n"
        << "  --ring FRAMES          elastic-ring capacity (default 768)\n"
        << "  --target FRAMES        elastic-ring target (default 192)\n"
        << "  --playback-prime N     frames primed into the ALSA playback queue\n"
        << "                         (default 0 = the whole playback buffer)\n"
        << "  --tx-playback-prime N  usb-to-ravenna override (0 = use --playback-prime)\n"
        << "  --rx-playback-prime N  ravenna-to-usb override (0 = use --playback-prime)\n"
        << "  --prime-trim 0|1       discard the ring overshoot at prime time\n"
        << "                         (default 0 = keep it, historical behaviour)\n"
        << "  --priority N           SCHED_FIFO priority (default 90)\n"
        << "  --seconds N            stop after N seconds; zero runs until signalled\n";
    std::exit(error.empty() ? EXIT_SUCCESS : EXIT_FAILURE);
}

unsigned long parse_unsigned(const char* value, const std::string_view name) {
    char* end = nullptr;
    errno = 0;
    const unsigned long parsed = std::strtoul(value, &end, 10);
    if (errno != 0 || end == value || *end != '\0') {
        throw std::runtime_error("invalid " + std::string(name));
    }
    return parsed;
}

Options parse_options(const int argc, char** argv) {
    Options options;
    for (int index = 1; index < argc; ++index) {
        const std::string_view argument(argv[index]);
        if (argument == "--help") {
            usage(argv[0]);
        }
        if (index + 1 >= argc) {
            usage(argv[0], "missing value for " + std::string(argument));
        }
        const char* value = argv[++index];
        if (argument == "--usb") {
            options.usb_device = value;
        } else if (argument == "--ravenna") {
            options.ravenna_device = value;
        } else if (argument == "--period") {
            options.requested_period = parse_unsigned(value, "period");
        } else if (argument == "--buffer") {
            options.requested_buffer = parse_unsigned(value, "buffer");
        } else if (argument == "--ring") {
            options.ring_frames = parse_unsigned(value, "ring");
        } else if (argument == "--target") {
            options.target_frames = parse_unsigned(value, "target");
        } else if (argument == "--playback-prime") {
            options.playback_prime_frames = parse_unsigned(value, "playback-prime");
        } else if (argument == "--tx-playback-prime") {
            options.tx_playback_prime_frames = parse_unsigned(value, "tx-playback-prime");
        } else if (argument == "--rx-playback-prime") {
            options.rx_playback_prime_frames = parse_unsigned(value, "rx-playback-prime");
        } else if (argument == "--prime-trim") {
            const unsigned long parsed = parse_unsigned(value, "prime-trim");
            if (parsed > 1) {
                throw std::runtime_error("prime-trim must be 0 or 1");
            }
            options.prime_trim = parsed != 0;
        } else if (argument == "--priority") {
            options.priority = static_cast<int>(parse_unsigned(value, "priority"));
        } else if (argument == "--seconds") {
            options.seconds = parse_unsigned(value, "seconds");
        } else {
            usage(argv[0], "unknown option " + std::string(argument));
        }
    }
    if (options.rate != 48000 || (options.requested_period != 48 && options.requested_period != 96)) {
        throw std::runtime_error("only 48 kHz with 48- or 96-frame requested periods is supported");
    }
    if (options.requested_buffer < options.requested_period * 2 ||
        options.ring_frames < options.target_frames + 8 ||
        options.target_frames < options.requested_period) {
        throw std::runtime_error("invalid buffer/ring/target relationship");
    }
    if (options.priority < 1 || options.priority > 98) {
        throw std::runtime_error("priority must be 1..98");
    }
    return options;
}

void alsa_check(const int result, const std::string& operation) {
    if (result < 0) {
        throw std::runtime_error(operation + ": " + snd_strerror(result));
    }
}

class Pcm {
public:
    Pcm(std::string label,
        const std::string& device,
        const snd_pcm_stream_t stream,
        const SampleFormat format,
        const Options& options)
        : label_(std::move(label)), stream_(stream), format_(format) {
        alsa_check(snd_pcm_open(&handle_, device.c_str(), stream, SND_PCM_NONBLOCK),
                   label_ + " open " + device);
        configure(options);
    }

    ~Pcm() {
        if (handle_ != nullptr) {
            snd_pcm_close(handle_);
        }
    }

    Pcm(const Pcm&) = delete;
    Pcm& operator=(const Pcm&) = delete;

    [[nodiscard]] snd_pcm_t* handle() const noexcept { return handle_; }
    [[nodiscard]] const std::string& label() const noexcept { return label_; }
    [[nodiscard]] SampleFormat format() const noexcept { return format_; }
    [[nodiscard]] snd_pcm_uframes_t period() const noexcept { return period_; }
    [[nodiscard]] snd_pcm_uframes_t buffer() const noexcept { return buffer_; }
    [[nodiscard]] snd_pcm_state_t state() const noexcept { return snd_pcm_state(handle_); }

    void prepare() { alsa_check(snd_pcm_prepare(handle_), label_ + " prepare"); }
    void drop() noexcept { snd_pcm_drop(handle_); }
    [[nodiscard]] int start() noexcept { return snd_pcm_start(handle_); }
    void start_capture() {
        if (stream_ == SND_PCM_STREAM_CAPTURE) {
            alsa_check(snd_pcm_start(handle_), label_ + " start");
        }
    }

    [[nodiscard]] snd_pcm_sframes_t available() noexcept {
        return snd_pcm_avail_update(handle_);
    }

    [[nodiscard]] int delay(snd_pcm_sframes_t& frames) noexcept {
        return snd_pcm_delay(handle_, &frames);
    }

private:
    void configure(const Options& options) {
        snd_pcm_hw_params_t* hardware = nullptr;
        snd_pcm_sw_params_t* software = nullptr;
        snd_pcm_hw_params_alloca(&hardware);
        snd_pcm_sw_params_alloca(&software);

        alsa_check(snd_pcm_hw_params_any(handle_, hardware), label_ + " hw_params_any");
        alsa_check(snd_pcm_hw_params_set_access(handle_, hardware, SND_PCM_ACCESS_MMAP_INTERLEAVED),
                   label_ + " require MMAP_INTERLEAVED");
        const snd_pcm_format_t alsa_format =
            format_ == SampleFormat::s24_3le ? SND_PCM_FORMAT_S24_3LE : SND_PCM_FORMAT_S32_LE;
        alsa_check(snd_pcm_hw_params_set_format(handle_, hardware, alsa_format), label_ + " format");
        alsa_check(snd_pcm_hw_params_set_channels(handle_, hardware, kChannels), label_ + " channels");

        unsigned int rate = options.rate;
        int direction = 0;
        alsa_check(snd_pcm_hw_params_set_rate_near(handle_, hardware, &rate, &direction), label_ + " rate");
        if (rate != options.rate) {
            throw std::runtime_error(label_ + " did not negotiate exactly 48000 Hz");
        }

        period_ = options.requested_period;
        direction = 0;
        alsa_check(snd_pcm_hw_params_set_period_size_near(handle_, hardware, &period_, &direction),
                   label_ + " period");
        buffer_ = options.requested_buffer;
        alsa_check(snd_pcm_hw_params_set_buffer_size_near(handle_, hardware, &buffer_), label_ + " buffer");
        alsa_check(snd_pcm_hw_params(handle_, hardware), label_ + " apply hardware params");

        alsa_check(snd_pcm_hw_params_get_period_size(hardware, &period_, &direction), label_ + " read period");
        alsa_check(snd_pcm_hw_params_get_buffer_size(hardware, &buffer_), label_ + " read buffer");
        if (buffer_ > 2048) {
            throw std::runtime_error(label_ + " negotiated an unsafe buffer above 2048 frames");
        }

        alsa_check(snd_pcm_sw_params_current(handle_, software), label_ + " sw current");
        alsa_check(snd_pcm_sw_params_set_avail_min(handle_, software, std::min(period_, options.requested_period)),
                   label_ + " avail_min");
        if (stream_ == SND_PCM_STREAM_PLAYBACK) {
            alsa_check(snd_pcm_sw_params_set_start_threshold(handle_, software, period_), label_ + " start threshold");
        } else {
            alsa_check(snd_pcm_sw_params_set_start_threshold(handle_, software, 1), label_ + " start threshold");
        }
        alsa_check(snd_pcm_sw_params(handle_, software), label_ + " apply software params");
        prepare();
    }

    std::string label_;
    snd_pcm_stream_t stream_;
    SampleFormat format_;
    snd_pcm_t* handle_{};
    snd_pcm_uframes_t period_{};
    snd_pcm_uframes_t buffer_{};
};

struct Telemetry {
    std::atomic<std::int64_t> ppm_milli{0};
    std::atomic<std::int64_t> observed_ppm_milli{0};
    std::atomic<std::int64_t> phase_error_milli{0};
    std::atomic<std::uint32_t> tx_occupancy{0};
    std::atomic<std::uint32_t> rx_occupancy{0};
    std::atomic<std::int64_t> tx_playback_delay{0};
    std::atomic<std::int64_t> rx_playback_delay{0};
    std::atomic<std::uint64_t> tx_restarts{0};
    std::atomic<std::uint64_t> rx_restarts{0};
    std::atomic<std::uint64_t> tx_input_frames{0};
    std::atomic<std::uint64_t> rx_input_frames{0};
    std::atomic<std::uint64_t> tx_consumed_frames{0};
    std::atomic<std::uint64_t> rx_consumed_frames{0};
    std::atomic<std::uint64_t> tx_dropped_frames{0};
    std::atomic<std::uint64_t> rx_dropped_frames{0};
    std::atomic<std::uint64_t> tx_short_begin_frames{0};
    std::atomic<std::uint64_t> rx_short_begin_frames{0};
    // -1 means not yet observed.
    std::atomic<std::int64_t> tx_queue_floor{-1};
    std::atomic<std::int64_t> rx_queue_floor{-1};
    std::atomic<std::int64_t> tx_depth_floor{-1};
    std::atomic<std::int64_t> rx_depth_floor{-1};
    std::atomic<std::uint64_t> tx_queue_below_period{0};
    std::atomic<std::uint64_t> rx_queue_below_period{0};
    std::atomic<std::uint64_t> tx_queue_samples{0};
    std::atomic<std::uint64_t> rx_queue_samples{0};
    std::atomic<std::uint64_t> tx_capture_peak{0};
    std::atomic<std::uint64_t> rx_capture_peak{0};
    std::atomic<std::uint64_t> tx_capture_total{0};
    std::atomic<std::uint64_t> rx_capture_total{0};
    std::atomic<std::uint64_t> tx_capture_samples{0};
    std::atomic<std::uint64_t> rx_capture_samples{0};
    std::atomic<std::uint64_t> tx_frames{0};
    std::atomic<std::uint64_t> rx_frames{0};
};

enum class IoResult { idle, progressed, recover };

struct Direction {
    std::string_view name;
    Pcm& capture;
    Pcm& playback;
    usb16x16::AudioRing ring;
    usb16x16::FarrowResampler resampler;
    bool primed{false};
    bool playback_started{false};
    // Frames to prime into the ALSA playback queue; zero means the whole
    // playback buffer.
    std::size_t playback_prime_frames{0};
    bool prime_trim{false};
    // Worst case playback-queue and total-pipeline depth seen, sampled on every
    // loop iteration rather than at telemetry time. The 1 Hz telemetry prints
    // one sample in roughly a hundred, so its apparent minimum is not the
    // floor; these are. Needed to relate the queue floor to the depth the
    // prime sets, which is the open question about how much slack is real.
    std::size_t queue_floor{std::numeric_limits<std::size_t>::max()};
    std::size_t depth_floor{std::numeric_limits<std::size_t>::max()};
    std::uint64_t queue_below_period{0};
    std::uint64_t queue_samples{0};
    // Frames captured but not yet read out of the ALSA capture buffer. This is
    // the one stage of the pipeline the depth accounting never covered: the
    // depth metric is ring plus playback queue only, and the buffer-192 run
    // measured roughly 5 ms of latency change that depth could not explain
    // while its RAVENNA capture buffer moved 384 -> 288. Sampled from the
    // available() call capture_into_ring already makes every iteration, so it
    // costs no extra syscall on the real-time path.
    std::size_t capture_backlog_peak{0};
    std::uint64_t capture_backlog_total{0};
    std::uint64_t capture_backlog_samples{0};
    std::uint64_t input_frames{};
    std::uint64_t output_frames{};
    // Frames the resampler produced, and consumed ring input for, that
    // snd_pcm_mmap_begin then refused to take. They are discarded. Rendering
    // is now sized from mmap_begin rather than the reverse, so this is a
    // regression guard and must stay at zero.
    std::uint64_t dropped_frames{};
    // Frames snd_pcm_mmap_begin declined to grant, whether or not any were
    // lost. Records that the short-begin condition still occurs.
    std::uint64_t short_begin_frames{};
    std::uint64_t restarts{};
    const char* recovery_stage{"unknown"};
    snd_pcm_sframes_t recovery_code{};
    snd_pcm_sframes_t playback_delay{};
    std::array<float, kScratchFrames * kChannels> capture_scratch{};
    std::array<float, kScratchFrames * kChannels> playback_scratch{};

    Direction(const std::string_view direction_name,
              Pcm& capture_pcm,
              Pcm& playback_pcm,
              const std::size_t ring_frames)
        : name(direction_name), capture(capture_pcm), playback(playback_pcm), ring(ring_frames) {}
};

IoResult request_recovery(Direction& direction,
                          const char* stage,
                          const snd_pcm_sframes_t code) noexcept {
    direction.recovery_stage = stage;
    direction.recovery_code = code;
    return IoResult::recover;
}

float read_area_sample(const snd_pcm_channel_area_t& area,
                       const snd_pcm_uframes_t offset,
                       const SampleFormat format) noexcept {
    const auto* address = static_cast<const std::uint8_t*>(area.addr) + area.first / 8U + offset * area.step / 8U;
    if (format == SampleFormat::s24_3le) {
        return usb16x16::s24_to_float(address);
    }
    std::int32_t value{};
    std::memcpy(&value, address, sizeof(value));
    return usb16x16::s32_to_float(value);
}

void write_area_sample(const snd_pcm_channel_area_t& area,
                       const snd_pcm_uframes_t offset,
                       const SampleFormat format,
                       const float sample) noexcept {
    auto* address = static_cast<std::uint8_t*>(area.addr) + area.first / 8U + offset * area.step / 8U;
    if (format == SampleFormat::s24_3le) {
        usb16x16::float_to_s24(sample, address);
        return;
    }
    const std::int32_t value = usb16x16::float_to_s32(sample);
    std::memcpy(address, &value, sizeof(value));
}

IoResult capture_into_ring(Direction& direction) noexcept {
    const snd_pcm_sframes_t available = direction.capture.available();
    if (available == -EPIPE || available == -ESTRPIPE) {
        return request_recovery(direction, "capture-avail", available);
    }
    if (available >= 0) {
        // Sample before the zero-backlog early return below, so the mean is
        // over every iteration rather than only the ones that found data. The
        // latter would bias it upward and overstate the capture contribution.
        const auto backlog = static_cast<std::size_t>(available);
        direction.capture_backlog_peak = std::max(direction.capture_backlog_peak, backlog);
        direction.capture_backlog_total += backlog;
        ++direction.capture_backlog_samples;
    }
    if (available < 0 || available == 0) {
        return available < 0 && available != -EAGAIN
            ? request_recovery(direction, "capture-avail", available)
            : IoResult::idle;
    }
    if (direction.ring.free() == 0) {
        return request_recovery(direction, "capture-ring-full",
                                static_cast<snd_pcm_sframes_t>(direction.ring.size()));
    }

    snd_pcm_uframes_t frames = std::min<snd_pcm_uframes_t>(
        static_cast<snd_pcm_uframes_t>(available),
        std::min<snd_pcm_uframes_t>(kScratchFrames, direction.ring.free()));
    const snd_pcm_channel_area_t* areas = nullptr;
    snd_pcm_uframes_t offset = 0;
    const int begin = snd_pcm_mmap_begin(direction.capture.handle(), &areas, &offset, &frames);
    if (begin < 0) {
        return begin == -EAGAIN ? IoResult::idle
                                : request_recovery(direction, "capture-mmap-begin", begin);
    }
    for (snd_pcm_uframes_t frame = 0; frame < frames; ++frame) {
        for (std::size_t channel = 0; channel < kChannels; ++channel) {
            direction.capture_scratch[frame * kChannels + channel] =
                read_area_sample(areas[channel], offset + frame, direction.capture.format());
        }
    }
    const snd_pcm_sframes_t committed = snd_pcm_mmap_commit(direction.capture.handle(), offset, frames);
    if (committed < 0 || static_cast<snd_pcm_uframes_t>(committed) != frames) {
        return request_recovery(direction, "capture-mmap-commit", committed);
    }
    if (!direction.ring.push(direction.capture_scratch.data(), frames)) {
        return request_recovery(direction, "capture-ring-push",
                                static_cast<snd_pcm_sframes_t>(direction.ring.size()));
    }
    direction.input_frames += frames;
    return IoResult::progressed;
}

IoResult render_to_playback(Direction& direction,
                            const std::size_t target_frames,
                            const double source_step) noexcept {
    if (!direction.primed) {
        // Prime the ALSA playback queue before allowing it to auto-start. A
        // period-sized initial write leaves only a couple of milliseconds of
        // runway and both directions can underrun in lockstep before the next
        // capture wakeup. Retain the process-local target plus Farrow lookahead
        // while making one near-full-buffer initial commit.
        const std::size_t queue_prime = direction.playback_prime_frames != 0
            ? direction.playback_prime_frames
            : static_cast<std::size_t>(direction.playback.buffer());
        const std::size_t prime_frames = target_frames + queue_prime + 3;
        if (direction.ring.size() < prime_frames) {
            return IoResult::idle;
        }
        // The ring is checked on capture wakeups, so it can overshoot the
        // threshold by a whole capture period before this is reached. Whatever
        // it overshoots by becomes permanent pipeline depth: total depth is set
        // here and then conserved, because there is no restoring force on the
        // common mode. Report it rather than infer it from occupancy later.
        const std::size_t ring_at_prime = direction.ring.size();
        const std::size_t overshoot = ring_at_prime - prime_frames;
        std::size_t trimmed = 0;
        if (direction.prime_trim && overshoot > 0) {
            // Discard the oldest frames so the pipeline starts at exactly the
            // intended depth. This runs once, before the playback queue has
            // been started and before any of this audio could have been heard,
            // and the resampler has not rendered yet, so its position still
            // refers to the front of the ring. The alternative is carrying the
            // overshoot as permanent latency for the life of the process.
            direction.ring.pop(overshoot);
            trimmed = overshoot;
        }
        std::cerr << "PRIMED direction=" << direction.name
                  << " intended=" << prime_frames
                  << " ring_at_prime=" << ring_at_prime
                  << " overshoot=" << overshoot
                  << " trimmed=" << trimmed
                  << " queue_prime=" << queue_prime << '\n';
        direction.primed = true;
    }

    const snd_pcm_sframes_t available = direction.playback.available();
    if (available == -EPIPE || available == -ESTRPIPE) {
        return request_recovery(direction, "playback-avail", available);
    }
    if (available < 0 || available == 0) {
        return available < 0 && available != -EAGAIN
            ? request_recovery(direction, "playback-avail", available)
            : IoResult::idle;
    }

    // Sample the queue and total depth here, before any early return, because
    // this runs on every loop iteration. Only once playback is started: during
    // priming the queue is deliberately empty and would floor the statistic at
    // zero for reasons that say nothing about steady-state headroom.
    if (direction.playback_started) {
        const auto buffer_frames = static_cast<std::size_t>(direction.playback.buffer());
        const auto free_frames = static_cast<std::size_t>(available);
        const std::size_t queue_depth =
            buffer_frames > free_frames ? buffer_frames - free_frames : 0;
        direction.queue_floor = std::min(direction.queue_floor, queue_depth);
        direction.depth_floor =
            std::min(direction.depth_floor, direction.ring.size() + queue_depth);
        if (queue_depth < static_cast<std::size_t>(direction.playback.period())) {
            ++direction.queue_below_period;
        }
        ++direction.queue_samples;
    }

    // Keep the target occupancy in the process-local elastic ring. ALSA may
    // expose an entire playback buffer at once; draining the ring into that
    // hidden queue would recreate the large, movable latency this bridge is
    // intended to remove.
    //
    // 2026-09-01: an attempt to regulate the ALSA playback queue here instead,
    // holding it at the target and letting the ring float, was reverted. It
    // drained the ring to the interpolator's 8-frame lookahead and left the
    // pipeline with no elastic reserve at all, so the first scheduling hiccup
    // underran: XRUN at 22 s against 331 s for this law. It did show that the
    // pipeline is carrying roughly 380 frames of slack -- latency fell from
    // 41.6 ms to 23.2 ms -- so the ring/queue split is worth tuning
    // deliberately, but not by starving the ring.
    if (direction.ring.size() <= target_frames + 3) {
        return IoResult::idle;
    }
    const double excess_source_frames = static_cast<double>(direction.ring.size() - target_frames - 3);
    const std::size_t safe_output_frames = static_cast<std::size_t>(excess_source_frames / source_step);
    const std::size_t wanted = std::min<std::size_t>(
        std::min<std::size_t>(available, kScratchFrames), safe_output_frames);
    if (wanted == 0) {
        return IoResult::idle;
    }
    // Ask ALSA how many frames it will actually take BEFORE consuming any ring
    // input. snd_pcm_mmap_begin hands back fewer frames than requested when the
    // playback buffer wraps, and the resampler cannot un-consume what it has
    // already popped, so rendering first could only discard the difference:
    // 583 frames of real audio on TX in 252 s (run 172034Z), which both lost
    // samples and inverted the direction's apparent rate. Asking first makes
    // that structurally impossible.
    snd_pcm_uframes_t frames = wanted;
    const snd_pcm_channel_area_t* areas = nullptr;
    snd_pcm_uframes_t offset = 0;
    const int begin = snd_pcm_mmap_begin(direction.playback.handle(), &areas, &offset, &frames);
    if (begin < 0) {
        return begin == -EAGAIN ? IoResult::idle
                                : request_recovery(direction, "playback-mmap-begin", begin);
    }
    // Frames ALSA declined at begin time. Behaviour-free, and it is what
    // separates "the short-begin condition no longer happens" from "it still
    // happens and is now absorbed", which a zero drop count alone cannot say.
    direction.short_begin_frames += wanted - static_cast<std::uint64_t>(frames);

    const std::size_t produced = direction.resampler.render(
        direction.ring, direction.playback_scratch.data(), frames, source_step);
    // Frames the resampler consumed ring input for that never reached the
    // device. The render above is capped at what mmap_begin already granted,
    // so this is now a structural zero; it stays as the regression guard for
    // that ordering and should read 0 in both directions.
    if (produced > frames) {
        direction.dropped_frames += produced - static_cast<std::uint64_t>(frames);
    }
    if (produced == 0) {
        // Release the region we reserved but did not fill.
        snd_pcm_mmap_commit(direction.playback.handle(), offset, 0);
        return IoResult::idle;
    }
    frames = static_cast<snd_pcm_uframes_t>(produced);
    for (snd_pcm_uframes_t frame = 0; frame < frames; ++frame) {
        for (std::size_t channel = 0; channel < kChannels; ++channel) {
            write_area_sample(areas[channel], offset + frame, direction.playback.format(),
                              direction.playback_scratch[frame * kChannels + channel]);
        }
    }
    const snd_pcm_sframes_t committed = snd_pcm_mmap_commit(direction.playback.handle(), offset, frames);
    if (committed < 0 || static_cast<snd_pcm_uframes_t>(committed) != frames) {
        return request_recovery(direction, "playback-mmap-commit", committed);
    }
    if (!direction.playback_started) {
        // MMAP commits do not auto-start these two hardware PCMs even after
        // the software start threshold is crossed. Without an explicit start,
        // each queue remains full in PREPARED state until the elastic ring
        // overflows and recovery repeats.
        const int start_result = direction.playback.start();
        if (start_result < 0) {
            return request_recovery(direction, "playback-start", start_result);
        }
        direction.playback_started = true;
    }
    direction.output_frames += frames;
    return IoResult::progressed;
}

void restart_direction(Direction& direction) {
    std::cerr << "RECOVER direction=" << direction.name
              << " stage=" << direction.recovery_stage
              << " code=" << direction.recovery_code
              << " error="
              << (direction.recovery_code < 0 ? snd_strerror(static_cast<int>(direction.recovery_code)) : "none")
              << " capture_state=" << snd_pcm_state_name(direction.capture.state())
              << " playback_state=" << snd_pcm_state_name(direction.playback.state())
              << " ring=" << direction.ring.size() << '\n';
    direction.capture.drop();
    direction.playback.drop();
    direction.capture.prepare();
    direction.playback.prepare();
    direction.ring.clear();
    direction.resampler.reset();
    direction.primed = false;
    direction.playback_started = false;
    ++direction.restarts;
    direction.capture.start_capture();
}

std::vector<pollfd> make_poll_descriptors(const std::array<Pcm*, 2>& pcms) {
    std::vector<pollfd> descriptors;
    for (Pcm* pcm : pcms) {
        const int count = snd_pcm_poll_descriptors_count(pcm->handle());
        if (count < 0) {
            throw std::runtime_error(pcm->label() + " poll descriptor count: " + snd_strerror(count));
        }
        const std::size_t start = descriptors.size();
        descriptors.resize(start + static_cast<std::size_t>(count));
        alsa_check(snd_pcm_poll_descriptors(pcm->handle(), descriptors.data() + start, count),
                   pcm->label() + " poll descriptors");
    }
    return descriptors;
}

void configure_realtime(const int priority) {
    if (mlockall(MCL_CURRENT | MCL_FUTURE) != 0) {
        throw std::runtime_error("mlockall failed: " + std::string(std::strerror(errno)));
    }
    sched_param parameters{};
    parameters.sched_priority = priority;
    const int result = pthread_setschedparam(pthread_self(), SCHED_FIFO, &parameters);
    if (result != 0) {
        throw std::runtime_error("SCHED_FIFO failed: " + std::string(std::strerror(result)));
    }
}

void publish_telemetry(const Direction& tx,
                       const Direction& rx,
                       const usb16x16::SharedDriftEstimator& estimator,
                       Telemetry& telemetry) noexcept {
    telemetry.ppm_milli.store(static_cast<std::int64_t>(std::llround(estimator.ppm() * 1000.0)),
                              std::memory_order_relaxed);
    telemetry.observed_ppm_milli.store(
        static_cast<std::int64_t>(std::llround(estimator.observed_ppm() * 1000.0)),
        std::memory_order_relaxed);
    telemetry.phase_error_milli.store(
        static_cast<std::int64_t>(std::llround(estimator.phase_error() * 1000.0)),
        std::memory_order_relaxed);
    telemetry.tx_occupancy.store(tx.ring.size(), std::memory_order_relaxed);
    telemetry.rx_occupancy.store(rx.ring.size(), std::memory_order_relaxed);
    telemetry.tx_playback_delay.store(tx.playback_delay, std::memory_order_relaxed);
    telemetry.rx_playback_delay.store(rx.playback_delay, std::memory_order_relaxed);
    telemetry.tx_restarts.store(tx.restarts, std::memory_order_relaxed);
    telemetry.rx_restarts.store(rx.restarts, std::memory_order_relaxed);
    telemetry.tx_input_frames.store(tx.input_frames, std::memory_order_relaxed);
    telemetry.rx_input_frames.store(rx.input_frames, std::memory_order_relaxed);
    telemetry.tx_consumed_frames.store(tx.resampler.consumed_frames(), std::memory_order_relaxed);
    telemetry.rx_consumed_frames.store(rx.resampler.consumed_frames(), std::memory_order_relaxed);
    telemetry.tx_dropped_frames.store(tx.dropped_frames, std::memory_order_relaxed);
    telemetry.rx_dropped_frames.store(rx.dropped_frames, std::memory_order_relaxed);
    telemetry.tx_short_begin_frames.store(tx.short_begin_frames, std::memory_order_relaxed);
    telemetry.rx_short_begin_frames.store(rx.short_begin_frames, std::memory_order_relaxed);
    const auto publish_floor = [](const std::size_t value) {
        return value == std::numeric_limits<std::size_t>::max()
            ? std::int64_t{-1}
            : static_cast<std::int64_t>(value);
    };
    telemetry.tx_queue_floor.store(publish_floor(tx.queue_floor), std::memory_order_relaxed);
    telemetry.rx_queue_floor.store(publish_floor(rx.queue_floor), std::memory_order_relaxed);
    telemetry.tx_depth_floor.store(publish_floor(tx.depth_floor), std::memory_order_relaxed);
    telemetry.rx_depth_floor.store(publish_floor(rx.depth_floor), std::memory_order_relaxed);
    telemetry.tx_queue_below_period.store(tx.queue_below_period, std::memory_order_relaxed);
    telemetry.rx_queue_below_period.store(rx.queue_below_period, std::memory_order_relaxed);
    telemetry.tx_queue_samples.store(tx.queue_samples, std::memory_order_relaxed);
    telemetry.rx_queue_samples.store(rx.queue_samples, std::memory_order_relaxed);
    telemetry.tx_capture_peak.store(tx.capture_backlog_peak, std::memory_order_relaxed);
    telemetry.rx_capture_peak.store(rx.capture_backlog_peak, std::memory_order_relaxed);
    telemetry.tx_capture_total.store(tx.capture_backlog_total, std::memory_order_relaxed);
    telemetry.rx_capture_total.store(rx.capture_backlog_total, std::memory_order_relaxed);
    telemetry.tx_capture_samples.store(tx.capture_backlog_samples, std::memory_order_relaxed);
    telemetry.rx_capture_samples.store(rx.capture_backlog_samples, std::memory_order_relaxed);
    telemetry.tx_frames.store(tx.output_frames, std::memory_order_relaxed);
    telemetry.rx_frames.store(rx.output_frames, std::memory_order_relaxed);
}

double capture_mean(const std::uint64_t total, const std::uint64_t samples) noexcept {
    return samples == 0 ? 0.0 : static_cast<double>(total) / static_cast<double>(samples);
}

void telemetry_loop(const Telemetry& telemetry) {
    while (!stop_requested.load(std::memory_order_relaxed)) {
        std::this_thread::sleep_for(std::chrono::seconds(1));
        std::cout << std::fixed << std::setprecision(3)
                  << "BRIDGE ppm=" << static_cast<double>(telemetry.ppm_milli.load()) / 1000.0
                  << " observed_ppm="
                  << static_cast<double>(telemetry.observed_ppm_milli.load()) / 1000.0
                  << " phase_error="
                  << static_cast<double>(telemetry.phase_error_milli.load()) / 1000.0
                  << " tx_occ=" << telemetry.tx_occupancy.load()
                  << " rx_occ=" << telemetry.rx_occupancy.load()
                  << " tx_queue=" << telemetry.tx_playback_delay.load()
                  << " rx_queue=" << telemetry.rx_playback_delay.load()
                  << " tx_restarts=" << telemetry.tx_restarts.load()
                  << " rx_restarts=" << telemetry.rx_restarts.load()
                  << " tx_input=" << telemetry.tx_input_frames.load()
                  << " rx_input=" << telemetry.rx_input_frames.load()
                  << " tx_consumed=" << telemetry.tx_consumed_frames.load()
                  << " rx_consumed=" << telemetry.rx_consumed_frames.load()
                  << " tx_dropped=" << telemetry.tx_dropped_frames.load()
                  << " rx_dropped=" << telemetry.rx_dropped_frames.load()
                  << " tx_short=" << telemetry.tx_short_begin_frames.load()
                  << " rx_short=" << telemetry.rx_short_begin_frames.load()
                  << " tx_qfloor=" << telemetry.tx_queue_floor.load()
                  << " rx_qfloor=" << telemetry.rx_queue_floor.load()
                  << " tx_dfloor=" << telemetry.tx_depth_floor.load()
                  << " rx_dfloor=" << telemetry.rx_depth_floor.load()
                  << " tx_qlow=" << telemetry.tx_queue_below_period.load()
                  << " rx_qlow=" << telemetry.rx_queue_below_period.load()
                  << " tx_qn=" << telemetry.tx_queue_samples.load()
                  << " rx_qn=" << telemetry.rx_queue_samples.load()
                  << " tx_cappeak=" << telemetry.tx_capture_peak.load()
                  << " rx_cappeak=" << telemetry.rx_capture_peak.load()
                  << " tx_capmean=" << capture_mean(telemetry.tx_capture_total.load(),
                                                    telemetry.tx_capture_samples.load())
                  << " rx_capmean=" << capture_mean(telemetry.rx_capture_total.load(),
                                                    telemetry.rx_capture_samples.load())
                  << " tx_frames=" << telemetry.tx_frames.load()
                  << " rx_frames=" << telemetry.rx_frames.load() << '\n';
    }
}

int run(const Options& options) {
    Pcm usb_capture("USB capture", options.usb_device, SND_PCM_STREAM_CAPTURE, SampleFormat::s24_3le, options);
    Pcm usb_playback("USB playback", options.usb_device, SND_PCM_STREAM_PLAYBACK, SampleFormat::s24_3le, options);
    Pcm ravenna_capture("RAVENNA capture", options.ravenna_device, SND_PCM_STREAM_CAPTURE, SampleFormat::s32_le, options);
    Pcm ravenna_playback("RAVENNA playback", options.ravenna_device, SND_PCM_STREAM_PLAYBACK, SampleFormat::s32_le, options);

    // Resolve the prime depth per direction: the direction override if set,
    // then the shared --playback-prime, then that direction's own negotiated
    // playback buffer. Validate against the buffer the direction actually got
    // rather than the larger of the two; the devices need not agree, and in
    // practice they do not.
    const auto resolve_prime = [&options](const std::size_t override_frames,
                                          const snd_pcm_uframes_t buffer) {
        const std::size_t requested =
            override_frames != 0 ? override_frames : options.playback_prime_frames;
        return requested != 0 ? requested : static_cast<std::size_t>(buffer);
    };
    const std::size_t tx_prime =
        resolve_prime(options.tx_playback_prime_frames, ravenna_playback.buffer());
    const std::size_t rx_prime =
        resolve_prime(options.rx_playback_prime_frames, usb_playback.buffer());
    if (tx_prime > static_cast<std::size_t>(ravenna_playback.buffer())) {
        throw std::runtime_error("usb-to-ravenna prime exceeds the RAVENNA playback buffer");
    }
    if (rx_prime > static_cast<std::size_t>(usb_playback.buffer())) {
        throw std::runtime_error("ravenna-to-usb prime exceeds the USB playback buffer");
    }
    if (options.ring_frames < options.target_frames + std::max(tx_prime, rx_prime) + 4) {
        throw std::runtime_error("elastic ring is too small to prime the ALSA playback queues");
    }

    std::cout << "NEGOTIATED"
              << " usb_capture=" << usb_capture.period() << '/' << usb_capture.buffer()
              << " usb_playback=" << usb_playback.period() << '/' << usb_playback.buffer()
              << " ravenna_capture=" << ravenna_capture.period() << '/' << ravenna_capture.buffer()
              << " ravenna_playback=" << ravenna_playback.period() << '/' << ravenna_playback.buffer() << '\n';

    Direction tx("usb-to-ravenna", usb_capture, ravenna_playback, options.ring_frames);
    Direction rx("ravenna-to-usb", ravenna_capture, usb_playback, options.ring_frames);
    tx.playback_prime_frames = tx_prime;
    rx.playback_prime_frames = rx_prime;
    tx.prime_trim = options.prime_trim;
    rx.prime_trim = options.prime_trim;
    usb16x16::SharedDriftEstimator estimator;
    Telemetry telemetry;

    // Capture readiness drives both pipelines. Including playback descriptors
    // makes poll return immediately whenever an ALSA output queue has space but
    // its elastic ring has no excess, producing a SCHED_FIFO busy loop.
    auto poll_descriptors = make_poll_descriptors({&usb_capture, &ravenna_capture});

    usb_capture.start_capture();
    ravenna_capture.start_capture();
    configure_realtime(options.priority);

    std::thread telemetry_thread(telemetry_loop, std::cref(telemetry));
    const auto started = std::chrono::steady_clock::now();
    std::uint64_t last_telemetry_frame = 0;
    std::size_t rate_update_samples = 0;
    usb16x16::WindowedLinearRegression rate_regression;
    auto last_rate_integral_time = started;
    double applied_ppm_seconds = 0.0;

    try {
        while (!stop_requested.load(std::memory_order_relaxed)) {
            if (options.seconds != 0 &&
                std::chrono::steady_clock::now() - started >= std::chrono::seconds(options.seconds)) {
                stop_requested.store(true, std::memory_order_relaxed);
                break;
            }

            bool progressed = false;
            bool restarted = false;
            const IoResult tx_capture = capture_into_ring(tx);
            const IoResult rx_capture = capture_into_ring(rx);
            if (tx_capture == IoResult::recover) {
                restart_direction(tx);
                restarted = true;
            }
            if (rx_capture == IoResult::recover) {
                restart_direction(rx);
                restarted = true;
            }
            progressed = tx_capture == IoResult::progressed || rx_capture == IoResult::progressed;

            const double ratio = estimator.clock_ratio();
            const IoResult tx_playback = render_to_playback(tx, options.target_frames, ratio);
            const IoResult rx_playback = render_to_playback(rx, options.target_frames, 1.0 / ratio);
            if (tx_playback == IoResult::recover) {
                restart_direction(tx);
                restarted = true;
            }
            if (rx_playback == IoResult::recover) {
                restart_direction(rx);
                restarted = true;
            }
            progressed = progressed || tx_playback == IoResult::progressed || rx_playback == IoResult::progressed;

            if (restarted) {
                rate_update_samples = 0;
                rate_regression.clear();
                estimator.reset(estimator.ppm());
                last_rate_integral_time = std::chrono::steady_clock::now();
                applied_ppm_seconds = 0.0;
            }

            const std::uint64_t telemetry_frame = std::min(tx.output_frames, rx.output_frames);
            if (telemetry_frame - last_telemetry_frame >= kTelemetryIntervalFrames) {
                last_telemetry_frame = telemetry_frame;
                const auto rate_sample_time = std::chrono::steady_clock::now();
                applied_ppm_seconds += estimator.ppm() *
                    std::chrono::duration<double>(rate_sample_time - last_rate_integral_time).count();
                last_rate_integral_time = rate_sample_time;
                snd_pcm_sframes_t tx_playback_delay = 0;
                snd_pcm_sframes_t rx_playback_delay = 0;
                const bool have_playback_delays =
                    tx.playback_started && rx.playback_started &&
                    tx.playback.delay(tx_playback_delay) == 0 &&
                    rx.playback.delay(rx_playback_delay) == 0 &&
                    tx_playback_delay >= 0 && rx_playback_delay >= 0;
                if (have_playback_delays) {
                    tx.playback_delay = tx_playback_delay;
                    rx.playback_delay = rx_playback_delay;
                }
                ++rate_update_samples;
                if (have_playback_delays && rate_update_samples >= kServoSamplesPerUpdate) {
                    rate_update_samples = 0;
                    const double elapsed_seconds =
                        std::chrono::duration<double>(rate_sample_time - started).count();
                    const double differential_pipeline_frames =
                        static_cast<double>(tx.ring.size()) + static_cast<double>(tx_playback_delay) -
                        static_cast<double>(rx.ring.size()) - static_cast<double>(rx_playback_delay);
                    const double corrected_differential_frames =
                        differential_pipeline_frames +
                        kDifferentialFramesPerSecondPerPpm * applied_ppm_seconds;
                    rate_regression.add(elapsed_seconds, corrected_differential_frames);
                    double corrected_slope = 0.0;
                    if (rate_regression.size() >= kMinimumRateSamples &&
                        rate_regression.slope(corrected_slope)) {
                        estimator.update_rate_observation(
                            corrected_slope / kDifferentialFramesPerSecondPerPpm);
                    }
                }
                publish_telemetry(tx, rx, estimator, telemetry);
            }

            if (!progressed) {
                const int poll_result = ::poll(poll_descriptors.data(), poll_descriptors.size(), 5);
                if (poll_result < 0 && errno != EINTR) {
                    throw std::runtime_error("poll failed: " + std::string(std::strerror(errno)));
                }
            }
        }
    } catch (...) {
        stop_requested.store(true, std::memory_order_relaxed);
        telemetry_thread.join();
        throw;
    }

    telemetry_thread.join();
    publish_telemetry(tx, rx, estimator, telemetry);
    const auto summary_floor = [](const std::size_t value) {
        return value == std::numeric_limits<std::size_t>::max()
            ? std::int64_t{-1}
            : static_cast<std::int64_t>(value);
    };
    std::cout << "SUMMARY {\"ppm\":" << std::fixed << std::setprecision(3) << estimator.ppm()
              << ",\"tx_restarts\":" << tx.restarts
              << ",\"rx_restarts\":" << rx.restarts
              << ",\"tx_input_frames\":" << tx.input_frames
              << ",\"rx_input_frames\":" << rx.input_frames
              << ",\"tx_consumed_frames\":" << tx.resampler.consumed_frames()
              << ",\"rx_consumed_frames\":" << rx.resampler.consumed_frames()
              << ",\"tx_dropped_frames\":" << tx.dropped_frames
              << ",\"rx_dropped_frames\":" << rx.dropped_frames
              << ",\"tx_frames\":" << tx.output_frames
              << ",\"rx_frames\":" << rx.output_frames
              << ",\"tx_queue_floor\":" << summary_floor(tx.queue_floor)
              << ",\"rx_queue_floor\":" << summary_floor(rx.queue_floor)
              << ",\"tx_depth_floor\":" << summary_floor(tx.depth_floor)
              << ",\"rx_depth_floor\":" << summary_floor(rx.depth_floor)
              << ",\"tx_queue_below_period\":" << tx.queue_below_period
              << ",\"rx_queue_below_period\":" << rx.queue_below_period
              << ",\"tx_queue_samples\":" << tx.queue_samples
              << ",\"rx_queue_samples\":" << rx.queue_samples
              << ",\"tx_capture_peak\":" << tx.capture_backlog_peak
              << ",\"rx_capture_peak\":" << rx.capture_backlog_peak
              << ",\"tx_capture_mean\":"
              << capture_mean(tx.capture_backlog_total, tx.capture_backlog_samples)
              << ",\"rx_capture_mean\":"
              << capture_mean(rx.capture_backlog_total, rx.capture_backlog_samples)
              << ",\"tx_capture_samples\":" << tx.capture_backlog_samples
              << ",\"rx_capture_samples\":" << rx.capture_backlog_samples << "}\n";
    return tx.restarts == 0 && rx.restarts == 0 ? EXIT_SUCCESS : 2;
}

} // namespace

int main(int argc, char** argv) {
    try {
        std::cout.setf(std::ios::unitbuf);
        std::cerr.setf(std::ios::unitbuf);
        std::signal(SIGINT, signal_handler);
        std::signal(SIGTERM, signal_handler);
        std::signal(SIGHUP, signal_handler);
        return run(parse_options(argc, argv));
    } catch (const std::exception& error) {
        std::cerr << "fatal: " << error.what() << '\n';
        return EXIT_FAILURE;
    }
}
