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
#include <time.h>
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
// The pull-burst and capture-avail histograms are binned in AES67 packets:
// the RAVENNA device moves 48 frames per 1 ms packet and the USB gadget 48
// frames per 1 ms USB frame, so 48 is the quantum both devices work in.
constexpr std::size_t kHistogramBinFrames = 48;
// 0, 1-48, 49-96, 97-144, 145-192, 193+
constexpr std::size_t kPullHistogramBins = 6;
// 0, 1-48, 49-96, 97-144, 145+
constexpr std::size_t kCaptureHistogramBins = 5;
// A DEPTHSTEP line is emitted when the depth floor drops by at least this
// much; the steps seen in the logs are 48 and about 85-90 frames.
constexpr std::size_t kDepthStepReportFrames = 24;
// Aligned start: wakeups timed before the RAVENNA capture is re-prepared, the
// default and largest offset from the reference wakeup to the prepare call.
// Eight wakeups are seven intervals, an odd count for the median, and 8 ms
// of observation. 600 us sits past the wake latency and well inside the
// 1 ms tick; anything up to ten ticks is allowed for experiments.
constexpr std::size_t kAlignWakeups = 8;
// A cold boot starts the RAVENNA capture in XRUN (every boot on record, and
// the 2026-09-03 reboot logged ALIGN reason=drain for it), so an attempt
// that meets an error recovers the capture and tries again; warm starts
// align on the first attempt. Each attempt is at most about 200 ms.
constexpr int kAlignAttempts = 4;
constexpr std::int64_t kAlignOffsetDefaultUs = 600;
constexpr std::int64_t kAlignOffsetMaximumUs = 10000;
std::chrono::steady_clock::time_point process_started{};

std::uint64_t elapsed_us() noexcept {
    return static_cast<std::uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(
        std::chrono::steady_clock::now() - process_started).count());
}

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
    // Buffer request for the RAVENNA playback PCM alone; zero means --buffer.
    // The RAVENNA playback buffer caps TX's queue floor at buffer minus one
    // push minus one pull (288 - 96 - 48 = 144 at buffer 288), and the device
    // pulls three packets, 144 frames, between wakeups when it skips. Raising
    // this PCM alone lifts that ceiling without moving the capture buffer,
    // which is where the 5 ms attributed to buffer 384 may live.
    snd_pcm_uframes_t ravenna_playback_buffer{0};
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
    // Phase 5, step 1. Instead of resampling each direction by the shared
    // estimator's ratio, drive the UAC2 gadget's "Capture Pitch 1000000" and
    // "Playback Pitch 1000000" controls with it, so the Mac's USB stream runs
    // at the PTP rate and both converters sit at exactly 1.0. At ratio 1.0
    // the Farrow kernel reduces to a one-frame delay, so the audio path is
    // bit transparent. A slow level term on the differential depth absorbs
    // the 1 ppm pitch quantisation. Off by default: the deployed behaviour.
    bool usb_pitch_servo{false};
    // Mode 2: the split servo. Capture Pitch and Playback Pitch are driven
    // separately, each with its own level loop, so TX and RX hold their own
    // depths (ring plus playback queue). The shared estimator still supplies
    // the common rate term. Mode 1 is unchanged.
    bool split_pitch_servo{false};
    // Absolute depth setpoints for mode 2, in frames; 0 captures the depth
    // at engagement, which is mode 1's behaviour per direction.
    std::size_t tx_depth_frames{0};
    std::size_t rx_depth_frames{0};
    double level_gain_ppm_per_frame{0.05};
    double level_clamp_ppm{2.0};
    // Aligned start. The RAVENNA driver fixes its capture reader's phase at
    // snd_pcm_prepare (capture_buffer_pos = SAC mod L) anywhere inside one
    // 1 ms tick, so a packet's arrival lead over its read slot is a
    // per-session draw of up to 48 frames, and the sink delay that clears
    // the wrap moves with it (2026-09-03 sweeps: 96 cleared in one session
    // and wrapped in the next). With this on, the bridge first watches the
    // tick through RAVENNA capture period wakeups, then re-prepares that
    // capture a fixed offset after a wakeup, so the phase is a constant.
    // Off by default: the historical start order. TX is untouched.
    bool align_start{false};
    std::int64_t align_offset_us{kAlignOffsetDefaultUs};
    int priority{90};
    unsigned int seconds{0};
};

// Control interface name for the USB gadget card, derived from its PCM name:
// "hw:CARD=UAC2Gadget,DEV=0" -> "hw:CARD=UAC2Gadget".
std::string control_name_of(const std::string& pcm_device) {
    const auto comma = pcm_device.find(',');
    return comma == std::string::npos ? pcm_device : pcm_device.substr(0, comma);
}

constexpr int kNominalPitch = 1000000;
// Level loop for the pitch servo: ppm of bias per frame of differential depth
// away from the setpoint captured when the servo engaged, and its clamp. The
// differential moves 0.096 frames/s per ppm, so 0.05 ppm/frame is a time
// constant of about 210 s: slow against the Mac's feedback loop and the
// estimator's 2 ppm/s slew, and enough to hold the 1 ppm quantisation
// residual to about +-10 frames of wander.
constexpr double kLevelBiasPpmPerFrame = 0.05;
constexpr double kLevelBiasMaximumPpm = 3.0;

// Writes the two UAC2 gadget pitch controls. Used from the telemetry thread
// only; the audio thread publishes the wanted value through an atomic.
class PitchControl {
public:
    explicit PitchControl(const std::string& control_device) {
        alsa_check_static(snd_ctl_open(&ctl_, control_device.c_str(), 0),
                          "control open " + control_device);
        snd_ctl_elem_value_malloc(&capture_);
        snd_ctl_elem_value_malloc(&playback_);
        prepare(capture_, "Capture Pitch 1000000");
        prepare(playback_, "Playback Pitch 1000000");
        // Read once so a missing control fails at startup, not on the first write.
        alsa_check_static(snd_ctl_elem_read(ctl_, capture_), "read Capture Pitch 1000000");
        alsa_check_static(snd_ctl_elem_read(ctl_, playback_), "read Playback Pitch 1000000");
    }

    ~PitchControl() {
        // Never leave the gadget pitched for whatever runs next.
        (void)write(kNominalPitch);
        snd_ctl_elem_value_free(capture_);
        snd_ctl_elem_value_free(playback_);
        snd_ctl_close(ctl_);
    }

    PitchControl(const PitchControl&) = delete;
    PitchControl& operator=(const PitchControl&) = delete;

    // Returns the first ALSA error, or 0.
    [[nodiscard]] int write(const int pitch) noexcept { return write(pitch, pitch); }

    [[nodiscard]] int write(const int capture_pitch, const int playback_pitch) noexcept {
        snd_ctl_elem_value_set_integer(capture_, 0, capture_pitch);
        snd_ctl_elem_value_set_integer(playback_, 0, playback_pitch);
        const int first = snd_ctl_elem_write(ctl_, capture_);
        const int second = snd_ctl_elem_write(ctl_, playback_);
        return first < 0 ? first : (second < 0 ? second : 0);
    }

private:
    static void alsa_check_static(const int result, const std::string& operation) {
        if (result < 0) {
            throw std::runtime_error(operation + ": " + snd_strerror(result));
        }
    }

    static void prepare(snd_ctl_elem_value_t* value, const char* name) {
        snd_ctl_elem_id_t* id = nullptr;
        snd_ctl_elem_id_alloca(&id);
        snd_ctl_elem_id_set_interface(id, SND_CTL_ELEM_IFACE_PCM);
        snd_ctl_elem_id_set_name(id, name);
        snd_ctl_elem_value_set_id(value, id);
    }

    snd_ctl_t* ctl_{};
    snd_ctl_elem_value_t* capture_{};
    snd_ctl_elem_value_t* playback_{};
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
        << "  --ravenna-playback-buffer FRAMES\n"
        << "                         buffer request for RAVENNA playback alone (0 = --buffer)\n"
        << "  --ring FRAMES          elastic-ring capacity (default 768)\n"
        << "  --target FRAMES        elastic-ring target (default 192)\n"
        << "  --playback-prime N     frames primed into the ALSA playback queue\n"
        << "                         (default 0 = the whole playback buffer)\n"
        << "  --tx-playback-prime N  usb-to-ravenna override (0 = use --playback-prime)\n"
        << "  --rx-playback-prime N  ravenna-to-usb override (0 = use --playback-prime)\n"
        << "  --prime-trim 0|1       discard the ring overshoot at prime time\n"
        << "                         (default 0 = keep it, historical behaviour)\n"
        << "  --usb-pitch-servo 0|1|2\n"
        << "                         1: steer both USB gadget pitch controls together to the PTP\n"
        << "                         rate and run both converters at exactly 1.0; 2: the same,\n"
        << "                         with Capture and Playback Pitch driven separately so each\n"
        << "                         direction holds its own depth (default 0)\n"
        << "  --tx-depth FRAMES      mode 2 setpoint for usb-to-ravenna depth, ring plus queue\n"
        << "                         (default 0 = capture the depth at engagement)\n"
        << "  --rx-depth FRAMES      mode 2 setpoint for ravenna-to-usb depth (default 0)\n"
        << "  --level-gain PPM       mode 2 level gain in ppm per frame (default 0.05)\n"
        << "  --level-clamp PPM      mode 2 level bias clamp in ppm (default 2)\n"
        << "  --align-start 0|1      re-prepare RAVENNA capture a fixed offset after one of its\n"
        << "                         period wakeups, so the driver's reader phase is constant\n"
        << "                         (default 0)\n"
        << "  --align-offset-us N    that offset, microseconds after the reference wakeup\n"
        << "                         (default 600, at most 10000)\n"
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

double parse_double(const char* value, const std::string_view name) {
    char* end = nullptr;
    errno = 0;
    const double parsed = std::strtod(value, &end);
    if (errno != 0 || end == value || *end != '\0' || !std::isfinite(parsed)) {
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
        } else if (argument == "--ravenna-playback-buffer") {
            options.ravenna_playback_buffer = parse_unsigned(value, "ravenna-playback-buffer");
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
        } else if (argument == "--usb-pitch-servo") {
            const unsigned long parsed = parse_unsigned(value, "usb-pitch-servo");
            if (parsed > 2) {
                throw std::runtime_error("usb-pitch-servo must be 0, 1 or 2");
            }
            options.usb_pitch_servo = parsed != 0;
            options.split_pitch_servo = parsed == 2;
        } else if (argument == "--tx-depth") {
            options.tx_depth_frames = parse_unsigned(value, "tx-depth");
        } else if (argument == "--rx-depth") {
            options.rx_depth_frames = parse_unsigned(value, "rx-depth");
        } else if (argument == "--level-gain") {
            options.level_gain_ppm_per_frame = parse_double(value, "level-gain");
        } else if (argument == "--level-clamp") {
            options.level_clamp_ppm = parse_double(value, "level-clamp");
        } else if (argument == "--align-start") {
            const unsigned long parsed = parse_unsigned(value, "align-start");
            if (parsed > 1) {
                throw std::runtime_error("align-start must be 0 or 1");
            }
            options.align_start = parsed != 0;
        } else if (argument == "--align-offset-us") {
            options.align_offset_us = static_cast<std::int64_t>(parse_unsigned(value, "align-offset-us"));
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
    if (options.ravenna_playback_buffer != 0 &&
        (options.ravenna_playback_buffer < options.requested_period * 2 ||
         options.ravenna_playback_buffer > 2048)) {
        throw std::runtime_error("ravenna-playback-buffer must be 0 or between 2 periods and 2048");
    }
    if (options.priority < 1 || options.priority > 98) {
        throw std::runtime_error("priority must be 1..98");
    }
    if (options.align_offset_us > kAlignOffsetMaximumUs) {
        throw std::runtime_error("align-offset-us must be 0..10000");
    }
    if (!options.align_start && options.align_offset_us != kAlignOffsetDefaultUs) {
        throw std::runtime_error("--align-offset-us needs --align-start 1");
    }
    if (options.tx_depth_frames != 0 || options.rx_depth_frames != 0 ||
        options.level_gain_ppm_per_frame != 0.05 || options.level_clamp_ppm != 2.0) {
        if (!options.split_pitch_servo) {
            throw std::runtime_error("--tx-depth, --rx-depth, --level-gain and --level-clamp need --usb-pitch-servo 2");
        }
    }
    if (options.split_pitch_servo) {
        // A TX setpoint must leave the ring its target plus the 144-frame
        // RAVENNA skip plus one period of push sawtooth in the queue; RX
        // must leave the target plus two periods.
        const std::size_t tx_minimum = options.target_frames + 144 + options.requested_period;
        const std::size_t rx_minimum = options.target_frames + 2 * options.requested_period;
        if (options.tx_depth_frames != 0 && options.tx_depth_frames < tx_minimum) {
            throw std::runtime_error("tx-depth is below the target plus the skip cover plus one period");
        }
        if (options.rx_depth_frames != 0 && options.rx_depth_frames < rx_minimum) {
            throw std::runtime_error("rx-depth is below the target plus two periods");
        }
        if (options.level_gain_ppm_per_frame <= 0.0 || options.level_gain_ppm_per_frame > 0.1 ||
            options.level_clamp_ppm <= 0.0 || options.level_clamp_ppm > 10.0) {
            throw std::runtime_error("level-gain must be in (0, 0.1] and level-clamp in (0, 10]");
        }
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
        const Options& options,
        const snd_pcm_uframes_t requested_buffer)
        : label_(std::move(label)), stream_(stream), format_(format) {
        alsa_check(snd_pcm_open(&handle_, device.c_str(), stream, SND_PCM_NONBLOCK),
                   label_ + " open " + device);
        configure(options, requested_buffer);
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
    void configure(const Options& options, const snd_pcm_uframes_t requested_buffer) {
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
        buffer_ = requested_buffer;
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
    std::atomic<std::uint64_t> tx_pull_max{0};
    std::atomic<std::uint64_t> rx_pull_max{0};
    std::atomic<std::uint64_t> tx_pull_max_gap_us{0};
    std::atomic<std::uint64_t> rx_pull_max_gap_us{0};
    std::atomic<std::uint64_t> tx_gap_max_us{0};
    std::atomic<std::uint64_t> rx_gap_max_us{0};
    std::array<std::atomic<std::uint64_t>, kPullHistogramBins> tx_pull_histogram{};
    std::array<std::atomic<std::uint64_t>, kPullHistogramBins> rx_pull_histogram{};
    std::atomic<std::uint64_t> tx_depth_total{0};
    std::atomic<std::uint64_t> rx_depth_total{0};
    std::atomic<std::uint64_t> tx_queue_total{0};
    std::atomic<std::uint64_t> rx_queue_total{0};
    std::array<std::atomic<std::uint64_t>, kCaptureHistogramBins> tx_capture_histogram{};
    std::array<std::atomic<std::uint64_t>, kCaptureHistogramBins> rx_capture_histogram{};
    // Samples the integer converters had to clamp on the way out. Non-zero
    // on hot material through the resampler; must be a structural zero once
    // the pitch servo holds both converters at 1.0.
    std::atomic<std::uint64_t> tx_clipped_samples{0};
    std::atomic<std::uint64_t> rx_clipped_samples{0};
    // Pitch servo: the value the audio thread wants applied, the value the
    // telemetry thread last wrote, and the level bias in milli-ppm.
    std::atomic<int> wanted_pitch{kNominalPitch};
    std::atomic<int> applied_pitch{kNominalPitch};
    std::atomic<std::int64_t> level_bias_ppm_milli{0};
    std::atomic<std::uint64_t> pitch_write_errors{0};
    // Mode 2: wanted_pitch/applied_pitch carry Capture Pitch, these carry
    // Playback Pitch and the two level loops.
    std::atomic<int> wanted_playback_pitch{kNominalPitch};
    std::atomic<int> applied_playback_pitch{kNominalPitch};
    std::atomic<std::int64_t> tx_bias_ppm_milli{0};
    std::atomic<std::int64_t> rx_bias_ppm_milli{0};
    std::atomic<std::int64_t> tx_depth_setpoint{-1};
    std::atomic<std::int64_t> rx_depth_setpoint{-1};
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
    // What the playback device consumed between two consecutive bridge
    // observations of its queue: the "pull burst". The queue floor is only
    // ever sampled when the bridge is awake, so the device-side minimum is the
    // sampled floor minus whatever the device pulls before the next wakeup.
    // That gap is the number the XRUN depends on, and the floors cannot see
    // it. Tracked from the available() call already made every iteration plus
    // the frames committed since, so it costs one clock read per iteration.
    bool have_queue_observation{false};
    std::size_t queue_after_last_commit{0};
    std::chrono::steady_clock::time_point last_queue_observation{};
    std::size_t pull_max{0};
    std::uint64_t pull_max_gap_us{0};
    std::uint64_t observation_gap_max_us{0};
    std::array<std::uint64_t, kPullHistogramBins> pull_histogram{};
    std::size_t last_queue_depth{0};
    std::uint64_t last_observation_gap_us{0};
    // Running totals of queue depth and ring-plus-queue depth at the same
    // sample point as the floors, so the telemetry thread can print a
    // per-second mean. The mean is the conservation test: a real depth loss
    // moves it, an early pull does not.
    std::uint64_t depth_total{0};
    std::uint64_t queue_total{0};
    std::size_t depth_floor_reported{std::numeric_limits<std::size_t>::max()};
    // Capture backlog at each observation, binned in packets, to show whether
    // the capture pointer advances in sub-period steps at all.
    std::array<std::uint64_t, kCaptureHistogramBins> capture_histogram{};
    std::size_t last_capture_backlog{0};
    // The floors as they stood at the first recovery. SUMMARY reports the
    // floors over the whole process, which on a failed run includes the
    // recovery cascade; run 224517Z read 89 in SUMMARY against 116 for the
    // entire pre-XRUN run.
    std::size_t queue_floor_before_recovery{std::numeric_limits<std::size_t>::max()};
    std::size_t depth_floor_before_recovery{std::numeric_limits<std::size_t>::max()};
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
    // Output samples at or beyond full scale that the converter clamped.
    std::uint64_t clipped_samples{};
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
        direction.last_capture_backlog = backlog;
        ++direction.capture_histogram[std::min(
            (backlog + kHistogramBinFrames - 1) / kHistogramBinFrames, kCaptureHistogramBins - 1)];
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
    bool observed = false;
    if (direction.playback_started) {
        observed = true;
        const auto buffer_frames = static_cast<std::size_t>(direction.playback.buffer());
        const auto free_frames = static_cast<std::size_t>(available);
        const std::size_t queue_depth =
            buffer_frames > free_frames ? buffer_frames - free_frames : 0;
        const auto now = std::chrono::steady_clock::now();
        std::size_t pull = 0;
        std::uint64_t gap_us = 0;
        if (direction.have_queue_observation) {
            // Frames the device consumed since we last looked: what we left
            // in the queue after our last commit, less what is there now.
            pull = direction.queue_after_last_commit > queue_depth
                ? direction.queue_after_last_commit - queue_depth
                : 0;
            gap_us = static_cast<std::uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(
                now - direction.last_queue_observation).count());
            if (pull > direction.pull_max) {
                direction.pull_max = pull;
                direction.pull_max_gap_us = gap_us;
            }
            direction.observation_gap_max_us = std::max(direction.observation_gap_max_us, gap_us);
            ++direction.pull_histogram[std::min(
                (pull + kHistogramBinFrames - 1) / kHistogramBinFrames, kPullHistogramBins - 1)];
        }
        direction.have_queue_observation = true;
        direction.last_queue_observation = now;
        direction.queue_after_last_commit = queue_depth;
        direction.last_queue_depth = queue_depth;
        direction.last_observation_gap_us = gap_us;
        direction.queue_floor = std::min(direction.queue_floor, queue_depth);
        direction.depth_floor =
            std::min(direction.depth_floor, direction.ring.size() + queue_depth);
        if (queue_depth < static_cast<std::size_t>(direction.playback.period())) {
            ++direction.queue_below_period;
        }
        ++direction.queue_samples;
        direction.queue_total += queue_depth;
        direction.depth_total += direction.ring.size() + queue_depth;
        if (direction.depth_floor + kDepthStepReportFrames <= direction.depth_floor_reported) {
            // Rare by construction: only when the floor steps down by a
            // packet or more, a handful of lines per run. Same path PRIMED
            // and RECOVER already take.
            direction.depth_floor_reported = direction.depth_floor;
            std::cerr << "DEPTHSTEP direction=" << direction.name
                      << " t_us=" << elapsed_us()
                      << " depth_floor=" << direction.depth_floor
                      << " ring=" << direction.ring.size()
                      << " queue=" << queue_depth
                      << " avail=" << available
                      << " capture_backlog=" << direction.last_capture_backlog
                      << " pull=" << pull
                      << " gap_us=" << gap_us << '\n';
        }
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
    std::uint64_t clipped = 0;
    for (snd_pcm_uframes_t frame = 0; frame < frames; ++frame) {
        for (std::size_t channel = 0; channel < kChannels; ++channel) {
            const float sample = direction.playback_scratch[frame * kChannels + channel];
            clipped += usb16x16::exceeds_full_scale(sample) ? 1U : 0U;
            write_area_sample(areas[channel], offset + frame, direction.playback.format(), sample);
        }
    }
    direction.clipped_samples += clipped;
    const snd_pcm_sframes_t committed = snd_pcm_mmap_commit(direction.playback.handle(), offset, frames);
    if (committed < 0 || static_cast<snd_pcm_uframes_t>(committed) != frames) {
        return request_recovery(direction, "playback-mmap-commit", committed);
    }
    if (observed) {
        direction.queue_after_last_commit += frames;
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
              << " ring=" << direction.ring.size()
              << " last_queue=" << direction.last_queue_depth
              << " last_gap_us=" << direction.last_observation_gap_us
              << " t_us=" << elapsed_us() << '\n';
    if (direction.restarts == 0) {
        direction.queue_floor_before_recovery = direction.queue_floor;
        direction.depth_floor_before_recovery = direction.depth_floor;
    }
    direction.have_queue_observation = false;
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

std::vector<pollfd> make_poll_descriptors(const std::vector<Pcm*>& pcms) {
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

std::int64_t monotonic_now_ns() noexcept {
    timespec now{};
    clock_gettime(CLOCK_MONOTONIC, &now);
    return static_cast<std::int64_t>(now.tv_sec) * 1000000000LL + now.tv_nsec;
}

struct AlignResult {
    bool ok{false};
    int attempts{0};
    std::int64_t tick_period_us{0};
    std::int64_t wake_to_prepare_us{0};
    std::int64_t prepare_us{0};
    std::string intervals_us;
    std::string reason;
};

// Discard everything a capture holds so its poll descriptor blocks until the
// next period wakeup. Returns 0, or the ALSA error (EAGAIN is not one).
int drain_capture(Pcm& capture) noexcept {
    for (int pass = 0; pass < 8; ++pass) {
        const snd_pcm_sframes_t available = capture.available();
        if (available == 0 || available == -EAGAIN) {
            return 0;
        }
        if (available < 0) {
            return static_cast<int>(available);
        }
        snd_pcm_uframes_t frames = static_cast<snd_pcm_uframes_t>(available);
        const snd_pcm_channel_area_t* areas = nullptr;
        snd_pcm_uframes_t offset = 0;
        const int begin = snd_pcm_mmap_begin(capture.handle(), &areas, &offset, &frames);
        if (begin < 0) {
            return begin == -EAGAIN ? 0 : begin;
        }
        if (frames == 0) {
            return 0;
        }
        const snd_pcm_sframes_t committed = snd_pcm_mmap_commit(capture.handle(), offset, frames);
        if (committed < 0) {
            return static_cast<int>(committed);
        }
    }
    return 0;
}

// Times kAlignWakeups period wakeups of the capture into wakes, draining
// after each so the next poll blocks until the next tick. On failure the
// reason names the stage and the ALSA error as a number (-32 is EPIPE, the
// XRUN), because the candidate wrapper reads the error's text as a failure
// marker and an XRUN the alignment recovers from is not one.
bool observe_wakes(Pcm& capture,
                   std::vector<pollfd>& descriptors,
                   std::vector<std::int64_t>& wakes,
                   std::string& reason) {
    wakes.clear();
    const int drained = drain_capture(capture);
    if (drained < 0) {
        reason = "drain error=" + std::to_string(drained);
        return false;
    }
    int timeouts = 0;
    while (wakes.size() < kAlignWakeups) {
        if (stop_requested.load(std::memory_order_relaxed)) {
            reason = "stopped";
            return false;
        }
        const int poll_result = ::poll(descriptors.data(), descriptors.size(), 20);
        if (poll_result < 0) {
            if (errno == EINTR) {
                continue;
            }
            reason = std::string("poll ") + std::strerror(errno);
            return false;
        }
        if (poll_result == 0) {
            if (++timeouts > 10) {
                reason = "no wakeups";
                return false;
            }
            continue;
        }
        const snd_pcm_sframes_t available = capture.available();
        if (available < 0 && available != -EAGAIN) {
            reason = "avail error=" + std::to_string(available);
            return false;
        }
        if (available <= 0) {
            continue;
        }
        wakes.push_back(monotonic_now_ns());
        const int after = drain_capture(capture);
        if (after < 0) {
            reason = "drain error=" + std::to_string(after);
            return false;
        }
    }
    return true;
}

// The aligned start. Times kAlignWakeups period wakeups of the RAVENNA
// capture, which arrive once per driver tick; the median interval is the
// tick and the last wakeup the reference. Sleeps on the monotonic clock to
// the reference plus the offset, then drops, prepares and starts the
// capture, so the reader phase the driver fixes at prepare is the same
// every session instead of anywhere inside a tick. Runs at SCHED_FIFO before
// the audio loop with the USB capture not yet started: its 4 ms buffer would
// not survive the 8 ms of observation. An attempt that meets an ALSA error
// (the cold-boot XRUN) recovers the capture and tries again, up to
// kAlignAttempts; if none succeeds the capture is restarted unaligned and
// the run continues, and the ALIGN line says so either way.
AlignResult align_ravenna_capture(Pcm& capture, const std::int64_t offset_us) {
    AlignResult result;
    auto descriptors = make_poll_descriptors({&capture});
    std::vector<std::int64_t> wakes;
    wakes.reserve(kAlignWakeups);
    const auto restart_capture = [&capture]() {
        capture.drop();
        capture.prepare();
        alsa_check(capture.start(), capture.label() + " start");
    };
    bool observed = false;
    for (result.attempts = 1; result.attempts <= kAlignAttempts; ++result.attempts) {
        if (result.attempts > 1) {
            restart_capture();
        }
        if (observe_wakes(capture, descriptors, wakes, result.reason)) {
            observed = true;
            break;
        }
        if (result.reason == "stopped") {
            break;
        }
    }
    if (!observed) {
        result.attempts = std::min(result.attempts, kAlignAttempts);
        restart_capture();
        return result;
    }
    for (std::size_t index = 1; index < wakes.size(); ++index) {
        if (index != 1) {
            result.intervals_us += '/';
        }
        result.intervals_us += std::to_string((wakes[index] - wakes[index - 1]) / 1000);
    }
    result.tick_period_us = (usb16x16::median_wake_interval(wakes) + 500) / 1000;

    const std::int64_t reference_ns = wakes.back();
    const std::int64_t target_ns = reference_ns + offset_us * 1000;
    timespec target{};
    target.tv_sec = static_cast<time_t>(target_ns / 1000000000LL);
    target.tv_nsec = static_cast<long>(target_ns % 1000000000LL);
    int sleep_result = 0;
    do {
        sleep_result = clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &target, nullptr);
    } while (sleep_result == EINTR && !stop_requested.load(std::memory_order_relaxed));
    if (sleep_result != 0) {
        result.reason = std::string("sleep ") + std::strerror(sleep_result);
        restart_capture();
        return result;
    }
    capture.drop();
    const std::int64_t before_prepare_ns = monotonic_now_ns();
    capture.prepare();
    const std::int64_t after_prepare_ns = monotonic_now_ns();
    alsa_check(capture.start(), capture.label() + " start");
    result.wake_to_prepare_us = (before_prepare_ns - reference_ns) / 1000;
    result.prepare_us = (after_prepare_ns - before_prepare_ns) / 1000;
    result.ok = true;
    return result;
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
    telemetry.tx_pull_max.store(tx.pull_max, std::memory_order_relaxed);
    telemetry.rx_pull_max.store(rx.pull_max, std::memory_order_relaxed);
    telemetry.tx_pull_max_gap_us.store(tx.pull_max_gap_us, std::memory_order_relaxed);
    telemetry.rx_pull_max_gap_us.store(rx.pull_max_gap_us, std::memory_order_relaxed);
    telemetry.tx_gap_max_us.store(tx.observation_gap_max_us, std::memory_order_relaxed);
    telemetry.rx_gap_max_us.store(rx.observation_gap_max_us, std::memory_order_relaxed);
    for (std::size_t bin = 0; bin < kPullHistogramBins; ++bin) {
        telemetry.tx_pull_histogram[bin].store(tx.pull_histogram[bin], std::memory_order_relaxed);
        telemetry.rx_pull_histogram[bin].store(rx.pull_histogram[bin], std::memory_order_relaxed);
    }
    telemetry.tx_depth_total.store(tx.depth_total, std::memory_order_relaxed);
    telemetry.rx_depth_total.store(rx.depth_total, std::memory_order_relaxed);
    telemetry.tx_queue_total.store(tx.queue_total, std::memory_order_relaxed);
    telemetry.rx_queue_total.store(rx.queue_total, std::memory_order_relaxed);
    for (std::size_t bin = 0; bin < kCaptureHistogramBins; ++bin) {
        telemetry.tx_capture_histogram[bin].store(tx.capture_histogram[bin], std::memory_order_relaxed);
        telemetry.rx_capture_histogram[bin].store(rx.capture_histogram[bin], std::memory_order_relaxed);
    }
    telemetry.tx_clipped_samples.store(tx.clipped_samples, std::memory_order_relaxed);
    telemetry.rx_clipped_samples.store(rx.clipped_samples, std::memory_order_relaxed);
}

template <typename Array>
std::string format_histogram(const Array& histogram) {
    std::string text;
    for (std::size_t bin = 0; bin < histogram.size(); ++bin) {
        if (bin != 0) {
            text += '/';
        }
        text += std::to_string(static_cast<std::uint64_t>(histogram[bin]));
    }
    return text;
}

// Mean over the samples added since the previous call, for the per-second
// window means. Returns 0 when no samples arrived in the window.
struct WindowMean {
    std::uint64_t last_total{0};
    std::uint64_t last_samples{0};
    double update(const std::uint64_t total, const std::uint64_t samples) noexcept {
        const std::uint64_t delta_samples = samples - last_samples;
        const double mean = delta_samples == 0
            ? 0.0
            : static_cast<double>(total - last_total) / static_cast<double>(delta_samples);
        last_total = total;
        last_samples = samples;
        return mean;
    }
};

double capture_mean(const std::uint64_t total, const std::uint64_t samples) noexcept {
    return samples == 0 ? 0.0 : static_cast<double>(total) / static_cast<double>(samples);
}

// The pitch servo's control writes live here, off the audio thread: the
// audio thread publishes wanted_pitch and this thread applies it, at most
// once per second, which is well inside the estimator's own update rate.
void apply_wanted_pitch(Telemetry& telemetry, PitchControl* pitch_control) noexcept {
    if (pitch_control == nullptr) {
        return;
    }
    const int wanted = telemetry.wanted_pitch.load(std::memory_order_relaxed);
    const int wanted_playback = telemetry.wanted_playback_pitch.load(std::memory_order_relaxed);
    if (wanted == telemetry.applied_pitch.load(std::memory_order_relaxed) &&
        wanted_playback == telemetry.applied_playback_pitch.load(std::memory_order_relaxed)) {
        return;
    }
    const int result = pitch_control->write(wanted, wanted_playback);
    if (result < 0) {
        telemetry.pitch_write_errors.fetch_add(1, std::memory_order_relaxed);
        std::cerr << "PITCH write failed: " << snd_strerror(result) << '\n';
        return;
    }
    telemetry.applied_pitch.store(wanted, std::memory_order_relaxed);
    telemetry.applied_playback_pitch.store(wanted_playback, std::memory_order_relaxed);
}

void telemetry_loop(Telemetry& telemetry, PitchControl* pitch_control) {
    WindowMean tx_depth_mean;
    WindowMean rx_depth_mean;
    WindowMean tx_queue_mean;
    WindowMean rx_queue_mean;
    while (!stop_requested.load(std::memory_order_relaxed)) {
        std::this_thread::sleep_for(std::chrono::seconds(1));
        apply_wanted_pitch(telemetry, pitch_control);
        // Read the sample count once per direction so both window means in a
        // line divide by the same count.
        const std::uint64_t tx_samples = telemetry.tx_queue_samples.load();
        const std::uint64_t rx_samples = telemetry.rx_queue_samples.load();
        const double tx_dmean = tx_depth_mean.update(telemetry.tx_depth_total.load(), tx_samples);
        const double rx_dmean = rx_depth_mean.update(telemetry.rx_depth_total.load(), rx_samples);
        const double tx_qmean = tx_queue_mean.update(telemetry.tx_queue_total.load(), tx_samples);
        const double rx_qmean = rx_queue_mean.update(telemetry.rx_queue_total.load(), rx_samples);
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
                  << " rx_frames=" << telemetry.rx_frames.load()
                  << " tx_dmean=" << tx_dmean
                  << " rx_dmean=" << rx_dmean
                  << " tx_qmean=" << tx_qmean
                  << " rx_qmean=" << rx_qmean
                  << " tx_pullmax=" << telemetry.tx_pull_max.load()
                  << " rx_pullmax=" << telemetry.rx_pull_max.load()
                  << " tx_pullmax_gap_us=" << telemetry.tx_pull_max_gap_us.load()
                  << " rx_pullmax_gap_us=" << telemetry.rx_pull_max_gap_us.load()
                  << " tx_gapmax_us=" << telemetry.tx_gap_max_us.load()
                  << " rx_gapmax_us=" << telemetry.rx_gap_max_us.load()
                  << " tx_pullhist=" << format_histogram(telemetry.tx_pull_histogram)
                  << " rx_pullhist=" << format_histogram(telemetry.rx_pull_histogram)
                  << " tx_caphist=" << format_histogram(telemetry.tx_capture_histogram)
                  << " rx_caphist=" << format_histogram(telemetry.rx_capture_histogram)
                  << " tx_clip=" << telemetry.tx_clipped_samples.load()
                  << " rx_clip=" << telemetry.rx_clipped_samples.load()
                  << " pitch=" << telemetry.applied_pitch.load()
                  << " bias_ppm="
                  << static_cast<double>(telemetry.level_bias_ppm_milli.load()) / 1000.0
                  << " pitch_errors=" << telemetry.pitch_write_errors.load()
                  << " pitch_p=" << telemetry.applied_playback_pitch.load()
                  << " tx_bias=" << static_cast<double>(telemetry.tx_bias_ppm_milli.load()) / 1000.0
                  << " rx_bias=" << static_cast<double>(telemetry.rx_bias_ppm_milli.load()) / 1000.0
                  << " tx_set=" << telemetry.tx_depth_setpoint.load()
                  << " rx_set=" << telemetry.rx_depth_setpoint.load() << '\n';
    }
}

int run(const Options& options) {
    const snd_pcm_uframes_t ravenna_playback_request = options.ravenna_playback_buffer != 0
        ? options.ravenna_playback_buffer
        : options.requested_buffer;
    Pcm usb_capture("USB capture", options.usb_device, SND_PCM_STREAM_CAPTURE, SampleFormat::s24_3le, options,
                    options.requested_buffer);
    Pcm usb_playback("USB playback", options.usb_device, SND_PCM_STREAM_PLAYBACK, SampleFormat::s24_3le, options,
                     options.requested_buffer);
    Pcm ravenna_capture("RAVENNA capture", options.ravenna_device, SND_PCM_STREAM_CAPTURE, SampleFormat::s32_le, options,
                        options.requested_buffer);
    Pcm ravenna_playback("RAVENNA playback", options.ravenna_device, SND_PCM_STREAM_PLAYBACK, SampleFormat::s32_le, options,
                         ravenna_playback_request);

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

    // Pitch servo state. The control handle is opened before memory is locked
    // and the thread goes real-time, and it starts at nominal so the gadget is
    // in a known state whatever the previous process left behind.
    std::unique_ptr<PitchControl> pitch_control;
    if (options.usb_pitch_servo) {
        pitch_control = std::make_unique<PitchControl>(control_name_of(options.usb_device));
        const int reset = pitch_control->write(kNominalPitch);
        if (reset < 0) {
            throw std::runtime_error(std::string("pitch reset: ") + snd_strerror(reset));
        }
        std::cout << "PITCHSERVO enabled control=" << control_name_of(options.usb_device)
                  << " mode=" << (options.split_pitch_servo ? 2 : 1)
                  << " level_gain_ppm_per_frame="
                  << (options.split_pitch_servo ? options.level_gain_ppm_per_frame : kLevelBiasPpmPerFrame)
                  << " level_clamp_ppm="
                  << (options.split_pitch_servo ? options.level_clamp_ppm : kLevelBiasMaximumPpm)
                  << " tx_depth=" << options.tx_depth_frames
                  << " rx_depth=" << options.rx_depth_frames << '\n';
    }
    bool have_rate_estimate = false;
    bool have_level_setpoint = false;
    double level_setpoint_frames = 0.0;
    double level_bias_ppm = 0.0;
    // Mode 2 level loops, one per direction.
    usb16x16::LevelServo::Config level_config;
    level_config.gain_ppm_per_frame = options.level_gain_ppm_per_frame;
    level_config.clamp_ppm = options.level_clamp_ppm;
    usb16x16::LevelServo tx_level(level_config);
    usb16x16::LevelServo rx_level(level_config);

    // Capture readiness drives both pipelines. Including playback descriptors
    // makes poll return immediately whenever an ALSA output queue has space but
    // its elastic ring has no excess, producing a SCHED_FIFO busy loop.
    auto poll_descriptors = make_poll_descriptors({&usb_capture, &ravenna_capture});

    AlignResult align;
    if (options.align_start) {
        // RAVENNA capture first and alone, so its wakeups are all the
        // alignment poll sees and the USB capture cannot overrun while the
        // tick is observed; USB capture starts once the phase is set.
        ravenna_capture.start_capture();
        configure_realtime(options.priority);
        align = align_ravenna_capture(ravenna_capture, options.align_offset_us);
        std::cout << "ALIGN status=" << (align.ok ? "ok" : "failed")
                  << " offset_us=" << options.align_offset_us
                  << " attempts=" << align.attempts
                  << " wakeups=" << kAlignWakeups
                  << " tick_period_us=" << align.tick_period_us
                  << " wake_to_prepare_us=" << align.wake_to_prepare_us
                  << " prepare_us=" << align.prepare_us
                  << " intervals_us=" << align.intervals_us
                  << (align.ok ? "" : " reason=" + align.reason) << '\n';
        usb_capture.start_capture();
    } else {
        usb_capture.start_capture();
        ravenna_capture.start_capture();
        configure_realtime(options.priority);
    }

    std::thread telemetry_thread(telemetry_loop, std::ref(telemetry), pitch_control.get());
    const auto started = std::chrono::steady_clock::now();
    process_started = started;
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

            // With the pitch servo the correction is applied at the USB
            // endpoints, so both converters run at exactly 1.0 and are bit
            // transparent; without it, the historical reciprocal ratios.
            const double ratio = options.usb_pitch_servo ? 1.0 : estimator.clock_ratio();
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
                // The regression removes the trajectory of whatever correction
                // is actually applied. With the servo that is the integer
                // pitch the telemetry thread last wrote (nominal minus pitch
                // has the same sign and gain on the differential as the
                // resampler ratio), including the level bias, so the level
                // loop's movements are not read back as drift.
                // In mode 2 the two controls differ by the level terms; the
                // differential sees their mean, exactly.
                const double applied_ppm = options.usb_pitch_servo
                    ? static_cast<double>(kNominalPitch) -
                        0.5 * (static_cast<double>(telemetry.applied_pitch.load(std::memory_order_relaxed)) +
                               static_cast<double>(telemetry.applied_playback_pitch.load(std::memory_order_relaxed)))
                    : estimator.ppm();
                applied_ppm_seconds += applied_ppm *
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
                        have_rate_estimate = true;
                    }
                    if (options.split_pitch_servo && have_rate_estimate) {
                        // Mode 2. TX depth rate is r_usb(1 + pi_c) - r_rav, so
                        // a TX depth above its setpoint wants a lower Capture
                        // Pitch: pitch_c = nominal - (ppm + tx_bias). RX depth
                        // rate is r_rav - r_usb(1 + pi_p), so an RX depth above
                        // its setpoint wants a higher Playback Pitch:
                        // pitch_p = nominal - (ppm - rx_bias). The estimator's
                        // correction integrates the mean of the two, above.
                        const double tx_depth =
                            static_cast<double>(tx.ring.size()) + static_cast<double>(tx_playback_delay);
                        const double rx_depth =
                            static_cast<double>(rx.ring.size()) + static_cast<double>(rx_playback_delay);
                        if (!have_level_setpoint) {
                            tx_level.set_setpoint(options.tx_depth_frames != 0
                                ? static_cast<double>(options.tx_depth_frames) : tx_depth);
                            rx_level.set_setpoint(options.rx_depth_frames != 0
                                ? static_cast<double>(options.rx_depth_frames) : rx_depth);
                            have_level_setpoint = true;
                            telemetry.tx_depth_setpoint.store(
                                static_cast<std::int64_t>(std::llround(tx_level.setpoint())), std::memory_order_relaxed);
                            telemetry.rx_depth_setpoint.store(
                                static_cast<std::int64_t>(std::llround(rx_level.setpoint())), std::memory_order_relaxed);
                            std::cerr << "PITCHSERVO engaged mode=2 tx_setpoint=" << tx_level.setpoint()
                                      << " rx_setpoint=" << rx_level.setpoint()
                                      << " tx_depth=" << tx_depth << " rx_depth=" << rx_depth
                                      << " ppm=" << estimator.ppm() << " t_us=" << elapsed_us() << '\n';
                        }
                        const double tx_bias = tx_level.update(tx_depth);
                        const double rx_bias = rx_level.update(rx_depth);
                        const auto to_pitch = [](const double wanted) {
                            return static_cast<int>(std::clamp(std::lrint(wanted),
                                                               long{kNominalPitch - 250},
                                                               long{kNominalPitch + 250}));
                        };
                        telemetry.wanted_pitch.store(
                            to_pitch(static_cast<double>(kNominalPitch) - (estimator.ppm() + tx_bias)),
                            std::memory_order_relaxed);
                        telemetry.wanted_playback_pitch.store(
                            to_pitch(static_cast<double>(kNominalPitch) - (estimator.ppm() - rx_bias)),
                            std::memory_order_relaxed);
                        telemetry.tx_bias_ppm_milli.store(
                            static_cast<std::int64_t>(std::llround(tx_bias * 1000.0)), std::memory_order_relaxed);
                        telemetry.rx_bias_ppm_milli.store(
                            static_cast<std::int64_t>(std::llround(rx_bias * 1000.0)), std::memory_order_relaxed);
                    } else if (options.usb_pitch_servo && have_rate_estimate) {
                        // Mode 1. Level term: hold the differential where it
                        // sat when the rate estimate first engaged. A positive
                        // pitch offset raises the differential (TX fills
                        // faster, RX drains faster), so a differential above
                        // the setpoint wants a lower pitch, which is a higher
                        // subtracted ppm. Both controls get the same value.
                        if (!have_level_setpoint) {
                            level_setpoint_frames = differential_pipeline_frames;
                            have_level_setpoint = true;
                            std::cerr << "PITCHSERVO engaged setpoint_frames=" << level_setpoint_frames
                                      << " ppm=" << estimator.ppm() << " t_us=" << elapsed_us() << '\n';
                        }
                        level_bias_ppm = std::clamp(
                            kLevelBiasPpmPerFrame * (differential_pipeline_frames - level_setpoint_frames),
                            -kLevelBiasMaximumPpm, kLevelBiasMaximumPpm);
                        const double wanted = static_cast<double>(kNominalPitch) -
                            (estimator.ppm() + level_bias_ppm);
                        const int pitch = static_cast<int>(std::clamp(std::lrint(wanted),
                                                                      long{kNominalPitch - 250},
                                                                      long{kNominalPitch + 250}));
                        telemetry.wanted_pitch.store(pitch, std::memory_order_relaxed);
                        telemetry.wanted_playback_pitch.store(pitch, std::memory_order_relaxed);
                        telemetry.level_bias_ppm_milli.store(
                            static_cast<std::int64_t>(std::llround(level_bias_ppm * 1000.0)),
                            std::memory_order_relaxed);
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
              << ",\"rx_capture_samples\":" << rx.capture_backlog_samples
              << ",\"tx_queue_floor_before_recovery\":" << summary_floor(tx.queue_floor_before_recovery)
              << ",\"rx_queue_floor_before_recovery\":" << summary_floor(rx.queue_floor_before_recovery)
              << ",\"tx_depth_floor_before_recovery\":" << summary_floor(tx.depth_floor_before_recovery)
              << ",\"rx_depth_floor_before_recovery\":" << summary_floor(rx.depth_floor_before_recovery)
              << ",\"tx_depth_mean\":" << capture_mean(tx.depth_total, tx.queue_samples)
              << ",\"rx_depth_mean\":" << capture_mean(rx.depth_total, rx.queue_samples)
              << ",\"tx_queue_mean\":" << capture_mean(tx.queue_total, tx.queue_samples)
              << ",\"rx_queue_mean\":" << capture_mean(rx.queue_total, rx.queue_samples)
              << ",\"tx_pull_max\":" << tx.pull_max
              << ",\"rx_pull_max\":" << rx.pull_max
              << ",\"tx_pull_max_gap_us\":" << tx.pull_max_gap_us
              << ",\"rx_pull_max_gap_us\":" << rx.pull_max_gap_us
              << ",\"tx_gap_max_us\":" << tx.observation_gap_max_us
              << ",\"rx_gap_max_us\":" << rx.observation_gap_max_us
              << ",\"tx_pull_histogram\":\"" << format_histogram(tx.pull_histogram) << '"'
              << ",\"rx_pull_histogram\":\"" << format_histogram(rx.pull_histogram) << '"'
              << ",\"tx_capture_histogram\":\"" << format_histogram(tx.capture_histogram) << '"'
              << ",\"rx_capture_histogram\":\"" << format_histogram(rx.capture_histogram) << '"'
              << ",\"tx_clipped_samples\":" << tx.clipped_samples
              << ",\"rx_clipped_samples\":" << rx.clipped_samples
              << ",\"usb_pitch_servo\":" << (options.split_pitch_servo ? 2 : (options.usb_pitch_servo ? 1 : 0))
              << ",\"pitch\":" << telemetry.applied_pitch.load()
              << ",\"level_bias_ppm\":" << level_bias_ppm
              << ",\"level_setpoint_frames\":" << level_setpoint_frames
              << ",\"pitch_write_errors\":" << telemetry.pitch_write_errors.load()
              << ",\"playback_pitch\":" << telemetry.applied_playback_pitch.load()
              << ",\"tx_bias_ppm\":" << tx_level.bias()
              << ",\"rx_bias_ppm\":" << rx_level.bias()
              << ",\"tx_depth_setpoint\":" << telemetry.tx_depth_setpoint.load()
              << ",\"rx_depth_setpoint\":" << telemetry.rx_depth_setpoint.load()
              << ",\"align_start\":" << (options.align_start ? 1 : 0)
              << ",\"align_ok\":" << (align.ok ? 1 : 0)
              << ",\"align_attempts\":" << align.attempts
              << ",\"align_tick_period_us\":" << align.tick_period_us
              << ",\"align_wake_to_prepare_us\":" << align.wake_to_prepare_us
              << ",\"align_prepare_us\":" << align.prepare_us << "}\n";
    // pitch_control's destructor restores nominal pitch after this returns.
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
