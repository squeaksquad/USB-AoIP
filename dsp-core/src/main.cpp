#include "usb16x16/bridge_core.hpp"

#include <alsa/asoundlib.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <cmath>
#include <csignal>
#include <fcntl.h>
#include <fstream>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <iomanip>
#include <iostream>
#include <limits>
#include <memory>
#include <optional>
#include <poll.h>
#include <pthread.h>
#include <sched.h>
#include <sstream>
#include <stdexcept>
#include <string>
#include <string_view>
#include <sys/mman.h>
#include <sys/stat.h>
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
// A recovery re-prepares the RAVENNA capture no sooner than this after the
// decision, so the prepare call can land on the chosen instant.
constexpr std::int64_t kAlignRecoveryMarginNs = 50000;
constexpr std::int64_t kAlignOffsetDefaultUs = 600;
constexpr std::int64_t kAlignOffsetMaximumUs = 10000;
// The aligned TX trigger projects the tick grid forward from its reference
// wake; the tick is known to the microsecond, so a reference older than
// this could be off by more than the wake jitter and the trigger runs
// unaligned instead (reason=stale-reference).
constexpr std::int64_t kAlignReferenceMaximumAgeNs = 100000000;
// The aligned TX prime computes its trigger target at the prime wake and
// then renders the prime before sleeping to it, so the target is placed
// this far ahead rather than kAlignRecoveryMarginNs. The longest aligned
// wait the prime allows for, margin + 2 ticks - offset, is age the front
// frame carries into the first tick, so the margin is a latency term.
// 200 us until 2026-09-06; 50 us for one session, which measured the
// prime path from placing the target to entering the trigger (the drop,
// the PRIMED line, the 192-frame render, the commit) at about 104 us, so
// one prime in twenty would have missed; 150 us since, 46 us of slack
// over that. The ALIGN trigger line's target= and slack_us= say whether
// the render finished inside it; a missed target moves the start to the
// next tick, one period later.
constexpr std::int64_t kAlignPrimeMarginNs = 150000;
// How much of that margin the front age prices. The age the aligned prime
// makes constant is the prime depth plus the longest wait it allows for,
// and that wait bound is this margin plus two ticks less the offset, not
// the placement margin above (2026-09-07). The difference between the two
// (100 us, 5 frames at 950/1000) is the render path's own time: it sits
// inside the placement margin as real slack and is no longer aged. In the
// sessions whose placed target falls inside that difference (about one in
// ten at 950/1000) the drop cuts the ring under the prime level by those
// frames and the render hands the queue that much under its prime; the USB
// capture wake that falls inside the trigger sleep in exactly those
// sessions (the wait is over a tick there) refills it at the start.
// --align-prime-age-margin-us: 150 by default, the placement margin, the
// 2026-09-06 behaviour (front age 301 at 950/1000, prime 243); 50 for the
// age50 profile (296).
constexpr std::int64_t kAlignPrimeAgeMarginDefaultUs = kAlignPrimeMarginNs / 1000;
// Aligned RX prime: how long the prime may wait for the first fresh wake of
// its reference grid (the USB capture) before priming unaligned. 5 ms is
// five USB frames; the ring has room for it (target + prime + 240 < 768).
constexpr std::int64_t kAlignPrimeReferenceWaitNs = 5000000;
// The USB frame grid the RX alignment uses: 48 frames at 48 kHz, one host
// frame, whatever the negotiated period.
constexpr std::int64_t kUsbFrameTickNs = 1000000;
// Zero-run detector window. 8 frames is far above anything dithered
// material or the channel-2 noise probe produces by chance and far below
// the 41-sample holes; 480 frames (ten packets, 10 ms) and longer is a gap
// in the material, counted but not reported. Both are flags.
constexpr std::size_t kZeroRunMinimumDefault = 8;
constexpr std::size_t kZeroRunMaximumDefault = 480;
constexpr std::size_t kZeroRunMaximumLimit = 48000;
// ZERORUN lines per direction per process; the counters keep going after.
// One hole every three minutes is 480 a day, so this is pathology cover.
constexpr std::uint64_t kZeroRunLineCap = 4096;
// Impulse trace defaults: the harness impulse is 0.25 full scale on channel
// 1, one sample, 12000 frames apart; the other channels carry noise at up
// to 0.1. Threshold 0.15 sits between them; the hold-off of 2400 frames
// (50 ms) makes one impulse one event at every stage. IMPULSE lines per
// direction per process: 800 impulses x 2 stages is 1600 per run, a 600 s
// soak 4800, so this is many sessions of cover.
constexpr std::size_t kImpulseChannelDefault = 1;
constexpr double kImpulseThresholdDefault = 0.15;
constexpr std::uint64_t kImpulseHoldoffDefault = 2400;
constexpr std::uint64_t kImpulseLineCap = 200000;
std::chrono::steady_clock::time_point process_started{};

std::uint64_t elapsed_us() noexcept {
    return static_cast<std::uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(
        std::chrono::steady_clock::now() - process_started).count());
}

std::int64_t monotonic_now_ns() noexcept {
    timespec now{};
    clock_gettime(CLOCK_MONOTONIC, &now);
    return static_cast<std::int64_t>(now.tv_sec) * 1000000000LL + now.tv_nsec;
}

std::atomic<bool> stop_requested{false};

void signal_handler(int) {
    stop_requested.store(true, std::memory_order_relaxed);
}

enum class SampleFormat { s24_3le, s32_le };

struct Options {
    // Coefficient artifact from `usb16x16-dsp-compile --bridge`. Empty means
    // direct mode, which is the absence of the stage rather than a preset with
    // everything switched off: nothing reads or writes the buffer on its way
    // through, and the accepted profile must measure what it measures today.
    std::string dsp_preset;
    // Live coefficient updates (2026-09-13, LIVE_COEFFICIENTS_DESIGN.md step
    // 3). A root-written artifact the control thread polls every 50 ms and
    // publishes into the running stage when its shape matches; the outcome
    // goes to the status file by rename. Empty means no control thread
    // starts and nothing on the audio path changes. Needs --dsp-preset.
    std::string dsp_live_file;
    std::string dsp_live_status;
    // Level meter snapshot file (2026-09-11). Empty means no tap: nothing
    // reads the blocks, no publisher thread starts, and the audio path is
    // the accepted one byte for byte.
    std::string meter_file;
    // AoIP loop mode (2026-09-12, AOIP_LOOP_DESIGN.md). One direction,
    // RAVENNA capture -> DSP -> RAVENNA playback, with no USB device opened:
    // both PCMs are on the RAVENNA card, so the converters run at exactly
    // 1.0 with no estimator and no pitch servo. Off by default, and with it
    // off nothing reads the flag on the audio path: the duplex bridge is
    // the accepted one, argument for argument.
    bool aoip_loop{false};
    // The loop's measurement injector: one 0.25 full-scale sample on this
    // channel (1..16, 0 = off) every loop_impulse_period_frames of output,
    // written after the DSP stage so the preset's gain does not touch it.
    // A candidate tool for the wire instrument (rtp-impulses.py); the
    // supervisor never passes it.
    std::size_t loop_impulse_channel{0};
    std::uint64_t loop_impulse_period_frames{0};
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
    // RX-only prime trim (2026-09-06, the RX prime overshoot lever). The RX
    // prime is checked at the USB capture's wakes, where the ring grows by a
    // capture period at a time, so it lands at ring 192 whatever the intended
    // level is (187 at target 64, 171 at target 48) and the overshoot is
    // permanent RX depth: at target 48 the RX queue started 21 frames over its
    // prime and the RX floor read 93 against 77. With this on, ravenna-to-usb
    // alone discards ring_at_prime - intended from the ring's front at prime
    // time (the same code --prime-trim runs for both directions), so the RX
    // queue starts at exactly its prime. usb-to-ravenna is never trimmed
    // here: its aligned drop already sets the front frame's age at the first
    // tick, and a second cut would move the start. Off by default.
    bool rx_prime_trim{false};
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
    // Phase 5 Stage B2. The estimator needs 60 observations before it
    // steers, and pitch sits at nominal for those 60 s while the clocks
    // differ by about 15 ppm, so 46 frames per direction move from TX to
    // RX in every session and the level loop then holds that split
    // (handoff "Phase 5 Stage A"). A non-zero seed writes nominal minus
    // seed to both pitch controls before the prime and starts the estimator
    // there, so the first minute runs at the rate the last session
    // converged to. Off at 0. Needs --usb-pitch-servo.
    double pitch_seed_ppm{0.0};
    // Phase 5 Stage B3. Mode 1 holds the TX-minus-RX differential where it
    // sat when the rate estimate engaged. This moves that setpoint: a
    // positive shift moves this many frames of servo-held depth from TX to
    // RX (the differential setpoint drops by twice the shift), a negative
    // one the other way. Servo-held depth is invisible on the device
    // timeline (handoff 2026-09-03), so it repartitions the floors without
    // moving the round trip. 0 = capture the differential unchanged.
    double level_shift_frames{0.0};
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
    // Aligned TX trigger, needs --align-start 1. In the driver a playback
    // trigger only raises a flag; the next tick copies the first period
    // from position 0 and stamps it SAC - 48 whatever the trigger's phase
    // inside that tick, so the phase between the bridge's snd_pcm_start and
    // the tick grid is a per-session draw of up to 48 frames on TX, the one
    // draw the aligned capture start leaves (seven aligned sessions at sink
    // delay 96 spanned 53 samples). With this on, the RAVENNA playback
    // trigger, at start and at every TX recovery, sleeps to the next
    // reference wake + offset + n * tick on the grid the aligned start
    // measured (at most one tick) before snd_pcm_start. Off by default.
    bool align_tx_trigger{false};
    std::int64_t align_tx_offset_us{kAlignOffsetDefaultUs};
    // Aligned TX prime, needs --align-tx-trigger 1. What the aligned trigger
    // does not fix: the first tick after the trigger copies position 0
    // whatever the trigger's phase inside that tick, so the TX playout is
    // the age of the ring's front frame at that first tick, and that age is
    // set by the prime instant (a USB capture wake) relative to the tick
    // grid: a per-session draw of one tick. With this on, the prime waits
    // for one more period of ring, computes the trigger target and the
    // first tick from the grid, and drops from the ring's front exactly the
    // frames that make the front frame's age at the first tick a constant
    // (prime depth plus the longest possible wait). Off by default.
    bool align_tx_prime{false};
    // The margin the aligned prime's front age prices, in microseconds
    // (kAlignPrimeAgeMarginDefaultUs); at most the placement margin. Any
    // other value needs an aligned prime.
    std::int64_t align_prime_age_margin_us{kAlignPrimeAgeMarginDefaultUs};
    // Aligned RX trigger and prime (2026-09-05, Phase 5), need --align-start
    // 1. RX plays out into the USB playback queue that the host drains on
    // its own 1 ms frame grid, so the phase between the RAVENNA tick grid
    // (redrawn at every stack start) and the host's frames is a per-session
    // draw of up to one frame on RX, the one draw the aligned TX prime
    // leaves: sessions with identical PRIMED numbers measured 34-64 samples
    // apart. With these on, RX mirrors TX with the roles swapped: the USB
    // playback trigger sleeps to the next USB capture fresh wake + offset +
    // n * 1 ms (the USB capture's period wakes are locked to the host's
    // frames), and the RX prime drops from the ring's front the frames that
    // make the front frame's age at the first host frame after the trigger
    // a constant. Off by default.
    bool align_rx_trigger{false};
    std::int64_t align_rx_offset_us{kAlignOffsetDefaultUs};
    bool align_rx_prime{false};
    // RX prime phase window (2026-09-05). The RAVENNA tick grid and the
    // host's USB frame grid drift at the crystal offset the pitch servo
    // corrects in the data rate, so their phase slides through a full 1 ms
    // cycle in about a minute, and the level a session starts at is set by
    // where that phase sits when RX primes (the aligned RX prime makes it a
    // constant by paying the worst case; this picks the draw instead). With
    // a window set, the RX prime holds, discarding ring excess, until the
    // phase of its own fresh wake against the USB capture's lies inside
    // [low, high] microseconds (high < low wraps), or the timeout passes and
    // it primes anyway with a logged line. The phase is reported every
    // second as phase_us whether or not a window is set.
    bool rx_prime_phase_window{false};
    std::int64_t rx_prime_phase_low_us{0};
    std::int64_t rx_prime_phase_high_us{0};
    std::int64_t rx_prime_phase_timeout_s{80};
    // Zero-run detector (2026-09-04). Exactly-41-sample runs of zeros on
    // the loop, phase-locked to the Pi's 48-frame grid, that neither the
    // bridge's counters nor the driver's flags see. With this on, every
    // block of audio entering (USB capture, RAVENNA capture) and leaving
    // (RAVENNA playback, USB playback) the bridge is scanned per channel
    // for runs of exact zeros between the two lengths, and each run is
    // logged as a ZERORUN line naming its stage; the stage where the zeros
    // first appear is the leg they are made on. Off by default: the audio
    // path is byte-for-byte the previous behaviour with it off or on.
    bool zero_run_detect{false};
    std::size_t zero_run_minimum_frames{kZeroRunMinimumDefault};
    std::size_t zero_run_maximum_frames{kZeroRunMaximumDefault};
    // Impulse trace (2026-09-06): every block entering and leaving the
    // bridge is scanned on one channel for a sample over the threshold, and
    // each hit is logged as an IMPULSE line with its stage, stream position
    // and monotonic time, so one harness impulse is stamped four times round
    // the loop. Off by default; behaviour-free like the zero-run detector.
    bool impulse_trace{false};
    std::size_t impulse_trace_channel{kImpulseChannelDefault};
    double impulse_trace_threshold{kImpulseThresholdDefault};
    std::uint64_t impulse_trace_holdoff{kImpulseHoldoffDefault};
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
        << "  --mode usb-duplex|aoip-loop\n"
        << "                         usb-duplex (default): USB <-> RAVENNA, both directions;\n"
        << "                         aoip-loop: RAVENNA capture -> DSP -> RAVENNA playback, one\n"
        << "                         direction, no USB device opened, converters at 1.0\n"
        << "  --loop-impulse CH,SECONDS\n"
        << "                         aoip-loop only: write one 0.25 full-scale sample on channel\n"
        << "                         CH (1..16) every SECONDS of output, after the DSP stage,\n"
        << "                         for the wire instrument (default: off)\n"
        << "  --period FRAMES        requested ALSA period (48 or 96; default 96)\n"
        << "  --buffer FRAMES        requested ALSA buffer (default 384)\n"
        << "  --ravenna-playback-buffer FRAMES\n"
        << "                         buffer request for RAVENNA playback alone (0 = --buffer)\n"
        << "  --ring FRAMES          elastic-ring capacity (default 768)\n"
        << "  --target FRAMES        elastic-ring target (default 192)\n"
        << "  --dsp-preset FILE      DSP coefficients on the RAVENNA playback direction\n"
        << "                         (usb-to-ravenna, or the loop) (default: no DSP)\n"
        << "  --dsp-live-file PATH   poll PATH (50 ms) for a same-shape artifact and publish its\n"
        << "                         coefficients into the running stage (default: no control thread)\n"
        << "  --dsp-live-status PATH where the outcome of each live file is written (default:\n"
        << "                         --dsp-live-file with .status appended)\n"
        << "  --meter-file PATH      publish per-channel levels of all four stages to PATH\n"
        << "                         every 50 ms window, rewritten atomically (default: no tap)\n"
        << "  --playback-prime N     frames primed into the ALSA playback queue\n"
        << "                         (default 0 = the whole playback buffer)\n"
        << "  --tx-playback-prime N  usb-to-ravenna override (0 = use --playback-prime)\n"
        << "  --rx-playback-prime N  ravenna-to-usb override (0 = use --playback-prime)\n"
        << "  --prime-trim 0|1       discard the ring overshoot at prime time\n"
        << "                         (default 0 = keep it, historical behaviour)\n"
        << "  --rx-prime-trim 0|1    discard the ravenna-to-usb ring overshoot at prime time\n"
        << "                         alone; usb-to-ravenna keeps its aligned drop (default 0)\n"
        << "  --usb-pitch-servo 0|1|2\n"
        << "                         1: steer both USB gadget pitch controls together to the PTP\n"
        << "                         rate and run both converters at exactly 1.0; 2: the same,\n"
        << "                         with Capture and Playback Pitch driven separately so each\n"
        << "                         direction holds its own depth (default 0)\n"
        << "  --tx-depth FRAMES      mode 2 setpoint for usb-to-ravenna depth, ring plus queue\n"
        << "                         (default 0 = capture the depth at engagement)\n"
        << "  --rx-depth FRAMES      mode 2 setpoint for ravenna-to-usb depth (default 0)\n"
        << "  --level-gain PPM       mode 2 level gain in ppm per frame (default 0.05)\n"
        << "  --pitch-seed PPM       start both pitch controls at nominal minus PPM and the\n"
        << "                         estimator at PPM, before the prime (default 0 = nominal)\n"
        << "  --level-shift FRAMES   mode 1: move this many frames of servo-held depth from\n"
        << "                         usb-to-ravenna to ravenna-to-usb (negative: the other\n"
        << "                         way) by lowering the differential setpoint captured at\n"
        << "                         engagement by twice FRAMES (default 0)\n"
        << "  --level-clamp PPM      mode 2 level bias clamp in ppm (default 2)\n"
        << "  --align-start 0|1      re-prepare RAVENNA capture a fixed offset after one of its\n"
        << "                         period wakeups, so the driver's reader phase is constant\n"
        << "                         (default 0)\n"
        << "  --align-offset-us N    that offset, microseconds after the reference wakeup\n"
        << "                         (default 600, at most 10000)\n"
        << "  --align-tx-trigger 0|1 trigger RAVENNA playback a fixed offset after a tick on\n"
        << "                         the grid the aligned start measured (default 0; needs\n"
        << "                         --align-start 1)\n"
        << "  --align-tx-offset-us N that offset, microseconds after the reference wakeup\n"
        << "                         (default 600, at most 10000)\n"
        << "  --align-rx-trigger 0|1\n"
        << "                         trigger the USB playback on the host's 1 ms frame grid\n"
        << "                         (USB capture fresh wakes) plus --align-rx-offset-us\n"
        << "  --align-rx-offset-us N offset on that grid (default 600)\n"
        << "  --align-rx-prime 0|1   drop from the RX ring at prime so the front frame's age\n"
        << "                         at the first host frame after the trigger is a constant\n"
        << "  --rx-prime-phase-window LOW,HIGH\n"
        << "                         hold the RX prime until the RAVENNA tick's phase against\n"
        << "                         the USB frame grid is inside [LOW,HIGH] us (HIGH<LOW wraps)\n"
        << "  --rx-prime-phase-timeout-s N\n"
        << "                         prime anyway after N seconds of holding (default 80)\n"
        << "  --align-tx-prime 0|1   drop ring front frames at the TX prime so the front\n"
        << "                         frame's age at the first tick is constant (default 0;\n"
        << "                         needs --align-tx-trigger 1)\n"
        << "  --align-prime-age-margin-us N\n"
        << "                         the margin the aligned prime's front age prices: the\n"
        << "                         longest wait it allows for is N + 2 ticks - offset, while\n"
        << "                         the trigger target is placed 150 us ahead whatever N\n"
        << "                         (default 150, at most 150; needs an aligned prime)\n"
        << "  --zero-run-detect 0|1  scan every block entering and leaving the bridge for runs\n"
        << "                         of exact zeros per channel and log each as ZERORUN with its\n"
        << "                         stage (default 0; behaviour-free instrument)\n"
        << "  --zero-run-min N       shortest run reported, frames (default 8; needs\n"
        << "                         --zero-run-detect 1)\n"
        << "  --zero-run-max N       longest run reported, frames; longer is silence, counted\n"
        << "                         not reported (default 480, at most 48000)\n"
        << "  --impulse-trace 0|1    stamp every sample over a threshold on one channel at each\n"
        << "                         of the four stages as an IMPULSE line with its stream\n"
        << "                         position and monotonic time (default 0; behaviour-free)\n"
        << "  --impulse-channel N    channel the trace watches, 1..16 (default 1, the harness\n"
        << "                         impulse channel; needs --impulse-trace 1)\n"
        << "  --impulse-threshold F  magnitude a sample must exceed, 0..1 (default 0.15)\n"
        << "  --impulse-holdoff N    frames ignored after a hit (default 2400)\n"
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
        } else if (argument == "--dsp-preset") {
            options.dsp_preset = value;
        } else if (argument == "--dsp-live-file") {
            options.dsp_live_file = value;
        } else if (argument == "--dsp-live-status") {
            options.dsp_live_status = value;
        } else if (argument == "--meter-file") {
            options.meter_file = value;
        } else if (argument == "--ravenna") {
            options.ravenna_device = value;
        } else if (argument == "--mode") {
            const std::string_view mode(value);
            if (mode == "usb-duplex") {
                options.aoip_loop = false;
            } else if (mode == "aoip-loop") {
                options.aoip_loop = true;
            } else {
                throw std::runtime_error("mode must be usb-duplex or aoip-loop");
            }
        } else if (argument == "--loop-impulse") {
            const std::string text(value);
            const auto comma = text.find(',');
            if (comma == std::string::npos) {
                throw std::runtime_error("loop-impulse must be CHANNEL,SECONDS");
            }
            options.loop_impulse_channel = parse_unsigned(text.substr(0, comma).c_str(), "loop-impulse channel");
            const unsigned long seconds = parse_unsigned(text.substr(comma + 1).c_str(), "loop-impulse seconds");
            if (options.loop_impulse_channel < 1 || options.loop_impulse_channel > kChannels) {
                throw std::runtime_error("loop-impulse channel must be 1..16");
            }
            if (seconds < 1 || seconds > 60) {
                throw std::runtime_error("loop-impulse seconds must be 1..60");
            }
            options.loop_impulse_period_frames = static_cast<std::uint64_t>(seconds) * 48000ULL;
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
        } else if (argument == "--rx-prime-trim") {
            const unsigned long parsed = parse_unsigned(value, "rx-prime-trim");
            if (parsed > 1) {
                throw std::runtime_error("rx-prime-trim must be 0 or 1");
            }
            options.rx_prime_trim = parsed != 0;
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
        } else if (argument == "--pitch-seed") {
            options.pitch_seed_ppm = parse_double(value, "pitch-seed");
            if (!(options.pitch_seed_ppm >= -250.0 && options.pitch_seed_ppm <= 250.0)) {
                throw std::runtime_error("pitch-seed must be within -250..250 ppm");
            }
        } else if (argument == "--level-shift") {
            options.level_shift_frames = parse_double(value, "level-shift");
            if (!(options.level_shift_frames >= -480.0 && options.level_shift_frames <= 480.0)) {
                throw std::runtime_error("level-shift must be within -480..480 frames");
            }
        } else if (argument == "--align-start") {
            const unsigned long parsed = parse_unsigned(value, "align-start");
            if (parsed > 1) {
                throw std::runtime_error("align-start must be 0 or 1");
            }
            options.align_start = parsed != 0;
        } else if (argument == "--align-offset-us") {
            options.align_offset_us = static_cast<std::int64_t>(parse_unsigned(value, "align-offset-us"));
        } else if (argument == "--align-tx-trigger") {
            const unsigned long parsed = parse_unsigned(value, "align-tx-trigger");
            if (parsed > 1) {
                throw std::runtime_error("align-tx-trigger must be 0 or 1");
            }
            options.align_tx_trigger = parsed != 0;
        } else if (argument == "--align-tx-offset-us") {
            options.align_tx_offset_us = static_cast<std::int64_t>(parse_unsigned(value, "align-tx-offset-us"));
        } else if (argument == "--align-tx-prime") {
            const unsigned long parsed = parse_unsigned(value, "align-tx-prime");
            if (parsed > 1) {
                throw std::runtime_error("align-tx-prime must be 0 or 1");
            }
            options.align_tx_prime = parsed != 0;
        } else if (argument == "--rx-prime-phase-window") {
            const std::string text(value);
            const auto comma = text.find(',');
            if (comma == std::string::npos) {
                throw std::runtime_error("rx-prime-phase-window must be LOW,HIGH in microseconds");
            }
            options.rx_prime_phase_low_us = static_cast<std::int64_t>(parse_unsigned(text.substr(0, comma).c_str(), "rx-prime-phase-window low"));
            options.rx_prime_phase_high_us = static_cast<std::int64_t>(parse_unsigned(text.substr(comma + 1).c_str(), "rx-prime-phase-window high"));
            if (options.rx_prime_phase_low_us > 999 || options.rx_prime_phase_high_us > 999) {
                throw std::runtime_error("rx-prime-phase-window bounds must be 0..999 us");
            }
            options.rx_prime_phase_window = true;
        } else if (argument == "--rx-prime-phase-timeout-s") {
            options.rx_prime_phase_timeout_s = static_cast<std::int64_t>(parse_unsigned(value, "rx-prime-phase-timeout-s"));
            if (options.rx_prime_phase_timeout_s < 1 || options.rx_prime_phase_timeout_s > 600) {
                throw std::runtime_error("rx-prime-phase-timeout-s must be 1..600");
            }
        } else if (argument == "--align-rx-trigger") {
            const unsigned long parsed = parse_unsigned(value, "align-rx-trigger");
            if (parsed > 1) {
                throw std::runtime_error("align-rx-trigger must be 0 or 1");
            }
            options.align_rx_trigger = parsed != 0;
        } else if (argument == "--align-rx-offset-us") {
            options.align_rx_offset_us = static_cast<std::int64_t>(parse_unsigned(value, "align-rx-offset-us"));
        } else if (argument == "--align-rx-prime") {
            const unsigned long parsed = parse_unsigned(value, "align-rx-prime");
            if (parsed > 1) {
                throw std::runtime_error("align-rx-prime must be 0 or 1");
            }
            options.align_rx_prime = parsed != 0;
        } else if (argument == "--align-prime-age-margin-us") {
            options.align_prime_age_margin_us = static_cast<std::int64_t>(parse_unsigned(value, "align-prime-age-margin-us"));
            if (options.align_prime_age_margin_us > kAlignPrimeAgeMarginDefaultUs) {
                throw std::runtime_error("align-prime-age-margin-us must be 0..150, the placement margin");
            }
        } else if (argument == "--zero-run-detect") {
            const unsigned long parsed = parse_unsigned(value, "zero-run-detect");
            if (parsed > 1) {
                throw std::runtime_error("zero-run-detect must be 0 or 1");
            }
            options.zero_run_detect = parsed != 0;
        } else if (argument == "--zero-run-min") {
            options.zero_run_minimum_frames = parse_unsigned(value, "zero-run-min");
        } else if (argument == "--zero-run-max") {
            options.zero_run_maximum_frames = parse_unsigned(value, "zero-run-max");
        } else if (argument == "--impulse-trace") {
            const unsigned long parsed = parse_unsigned(value, "impulse-trace");
            if (parsed > 1) {
                throw std::runtime_error("impulse-trace must be 0 or 1");
            }
            options.impulse_trace = parsed != 0;
        } else if (argument == "--impulse-channel") {
            options.impulse_trace_channel = parse_unsigned(value, "impulse-channel");
        } else if (argument == "--impulse-threshold") {
            options.impulse_trace_threshold = parse_double(value, "impulse-threshold");
        } else if (argument == "--impulse-holdoff") {
            options.impulse_trace_holdoff = parse_unsigned(value, "impulse-holdoff");
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
    if (options.align_tx_offset_us > kAlignOffsetMaximumUs) {
        throw std::runtime_error("align-tx-offset-us must be 0..10000");
    }
    if (!options.align_tx_trigger && options.align_tx_offset_us != kAlignOffsetDefaultUs) {
        throw std::runtime_error("--align-tx-offset-us needs --align-tx-trigger 1");
    }
    if (options.align_tx_trigger && !options.align_start) {
        throw std::runtime_error("--align-tx-trigger needs --align-start 1");
    }
    if (options.align_tx_prime && !options.align_tx_trigger) {
        throw std::runtime_error("--align-tx-prime needs --align-tx-trigger 1");
    }
    if (options.align_rx_offset_us > kAlignOffsetMaximumUs) {
        throw std::runtime_error("align-rx-offset-us must be 0..10000");
    }
    if (!options.align_rx_trigger && options.align_rx_offset_us != kAlignOffsetDefaultUs) {
        throw std::runtime_error("--align-rx-offset-us needs --align-rx-trigger 1");
    }
    if (options.align_rx_trigger && !options.align_start) {
        throw std::runtime_error("--align-rx-trigger needs --align-start 1");
    }
    if (options.align_rx_prime && !options.align_rx_trigger) {
        throw std::runtime_error("--align-rx-prime needs --align-rx-trigger 1");
    }
    if (options.align_prime_age_margin_us != kAlignPrimeAgeMarginDefaultUs &&
        !options.align_tx_prime && !options.align_rx_prime) {
        throw std::runtime_error("--align-prime-age-margin-us needs --align-tx-prime 1 or --align-rx-prime 1");
    }
    if (options.rx_prime_trim && options.align_rx_prime) {
        throw std::runtime_error("--rx-prime-trim and --align-rx-prime both cut the RX ring at prime time; use one");
    }
    if (options.rx_prime_phase_window && !options.align_start) {
        throw std::runtime_error("--rx-prime-phase-window needs --align-start 1");
    }
    if (options.zero_run_minimum_frames < 1 ||
        options.zero_run_maximum_frames < options.zero_run_minimum_frames ||
        options.zero_run_maximum_frames > kZeroRunMaximumLimit) {
        throw std::runtime_error("zero-run-min must be at least 1 and zero-run-max between it and 48000");
    }
    if (!options.zero_run_detect &&
        (options.zero_run_minimum_frames != kZeroRunMinimumDefault ||
         options.zero_run_maximum_frames != kZeroRunMaximumDefault)) {
        throw std::runtime_error("--zero-run-min and --zero-run-max need --zero-run-detect 1");
    }
    if (options.impulse_trace_channel < 1 || options.impulse_trace_channel > kChannels) {
        throw std::runtime_error("impulse-channel must be 1..16");
    }
    if (!(options.impulse_trace_threshold > 0.0) || options.impulse_trace_threshold > 1.0) {
        throw std::runtime_error("impulse-threshold must be in (0, 1]");
    }
    if (options.impulse_trace_holdoff < 1) {
        throw std::runtime_error("impulse-holdoff must be at least 1");
    }
    if (!options.impulse_trace &&
        (options.impulse_trace_channel != kImpulseChannelDefault ||
         options.impulse_trace_threshold != kImpulseThresholdDefault ||
         options.impulse_trace_holdoff != kImpulseHoldoffDefault)) {
        throw std::runtime_error("--impulse-channel, --impulse-threshold and --impulse-holdoff need --impulse-trace 1");
    }
    if (options.aoip_loop) {
        // No gadget: nothing to steer, and no second clock to estimate.
        if (options.usb_pitch_servo || options.pitch_seed_ppm != 0.0 || options.level_shift_frames != 0.0) {
            throw std::runtime_error("--mode aoip-loop opens no USB gadget: --usb-pitch-servo, --pitch-seed and --level-shift must be 0");
        }
        // No ravenna-to-usb direction: its prime, trim, trigger and window
        // have nothing to act on.
        if (options.align_rx_trigger || options.align_rx_prime || options.rx_prime_phase_window ||
            options.rx_prime_trim || options.rx_playback_prime_frames != 0) {
            throw std::runtime_error("--mode aoip-loop has no ravenna-to-usb direction: the --rx-* and --align-rx-* options must be off");
        }
    } else if (options.loop_impulse_channel != 0) {
        throw std::runtime_error("--loop-impulse needs --mode aoip-loop");
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
    // The DSP stage's cost on the audio thread, usb-to-ravenna only.
    std::atomic<std::int64_t> tx_dsp_ns_max{0};
    std::atomic<std::uint64_t> tx_dsp_ns_total{0};
    std::atomic<std::uint64_t> tx_dsp_calls{0};
    std::atomic<std::uint64_t> tx_dsp_frames{0};
    // Live coefficient updates: publishes the audio thread has taken, the
    // first 16 hex digits of the live artifact's SHA-256 (0 = none), and
    // files refused. Written by the control thread, read by the BRIDGE line.
    std::atomic<std::uint64_t> dsp_live_generation{0};
    std::atomic<std::uint64_t> dsp_live_sha_prefix{0};
    std::atomic<std::uint64_t> dsp_live_refused{0};
    // The level meter tap's cost on the audio thread, both stages of each
    // direction together; the maximum is the figure that matters.
    std::atomic<std::int64_t> tx_meter_ns_max{0};
    std::atomic<std::int64_t> rx_meter_ns_max{0};
    std::atomic<std::uint64_t> tx_meter_ns_total{0};
    std::atomic<std::uint64_t> rx_meter_ns_total{0};
    std::atomic<std::uint64_t> tx_meter_calls{0};
    std::atomic<std::uint64_t> rx_meter_calls{0};
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
    // Loop-mode injector: impulses written so far (0 in duplex mode).
    std::atomic<std::uint64_t> tx_loop_impulses{0};
    // Pitch servo: the value the audio thread wants applied, the value the
    // telemetry thread last wrote, and the level bias in milli-ppm.
    std::atomic<int> wanted_pitch{kNominalPitch};
    std::atomic<int> applied_pitch{kNominalPitch};
    std::atomic<std::int64_t> level_bias_ppm_milli{0};
    // RAVENNA tick grid phase against the USB frame grid, microseconds in
    // [0, 1000), or -1 before both grids have a fresh wake.
    std::atomic<std::int64_t> grid_phase_us{-1};
    std::atomic<std::uint64_t> pitch_write_errors{0};
    // Mode 2: wanted_pitch/applied_pitch carry Capture Pitch, these carry
    // Playback Pitch and the two level loops.
    std::atomic<int> wanted_playback_pitch{kNominalPitch};
    std::atomic<int> applied_playback_pitch{kNominalPitch};
    std::atomic<std::int64_t> tx_bias_ppm_milli{0};
    std::atomic<std::int64_t> rx_bias_ppm_milli{0};
    std::atomic<std::int64_t> tx_depth_setpoint{-1};
    std::atomic<std::int64_t> rx_depth_setpoint{-1};
    // Zero-run detector, one set per stage: events, frames inside events,
    // longest event, per-channel runs beyond the maximum (silence).
    struct ZeroRunCounters {
        std::atomic<std::uint64_t> events{0};
        std::atomic<std::uint64_t> frames{0};
        std::atomic<std::uint64_t> longest{0};
        std::atomic<std::uint64_t> long_runs{0};
    };
    ZeroRunCounters usb_capture_zero;
    ZeroRunCounters ravenna_playback_zero;
    ZeroRunCounters ravenna_capture_zero;
    ZeroRunCounters usb_playback_zero;
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
    // Aligned recovery (RX only, with --align-start). The tick phase is
    // kept from this capture's own wakeups: the iteration start time of the
    // last wake that found exactly one period after an empty look, which is
    // a fresh tick and not a backlog serviced late. A recovery then sleeps
    // to the next reference + offset + n * tick before re-preparing, at most
    // one tick, which the other direction survives where the start
    // procedure's 8 ms would not. Zero align_tick_ns means the historical
    // unaligned recovery.
    std::int64_t align_tick_ns{0};
    std::int64_t align_offset_ns{0};
    std::int64_t last_fresh_wake_ns{0};
    std::uint64_t realigned_recoveries{0};
    // Aligned playback trigger (TX only, with --align-tx-trigger). The grid
    // is the tick the aligned start measured; the reference is the RAVENNA
    // capture direction's last fresh wake, read through tick_source, or the
    // start alignment's own reference wake before the loop has seen one.
    // Zero align_trigger_tick_ns means the historical trigger, straight
    // after the first commit.
    const Direction* tick_source{nullptr};
    std::int64_t align_trigger_tick_ns{0};
    std::int64_t align_trigger_offset_ns{0};
    std::int64_t align_trigger_seed_ns{0};
    // The margin the front age prices (kAlignPrimeAgeMarginDefaultUs).
    std::int64_t align_prime_age_margin_ns{kAlignPrimeMarginNs};
    std::uint64_t aligned_triggers{0};
    std::uint64_t unaligned_triggers{0};
    std::int64_t last_trigger_wake_to_start_us{-1};
    // Aligned TX prime (--align-tx-prime). The prime records the instant it
    // ran (a capture wake), its phase on the grid, the first tick that will
    // follow the planned trigger, and the frames it dropped; the planned
    // trigger target is handed to the trigger so both use one grid point.
    bool align_prime{false};
    // Aligned prime without a start-reference seed (RX): the instant the
    // prime first found its ring full enough while the reference grid had
    // no fresh wake yet, plus the wait allowance; 0 = not waiting.
    std::int64_t align_prime_wait_deadline_ns{0};
    // Grid phase (RX only): this direction's fresh wake against the phase
    // reference direction's fresh wake, modulo one USB frame; reported as
    // phase_us and, with a window, gating the prime.
    const Direction* phase_reference{nullptr};
    bool phase_window{false};
    std::int64_t phase_window_low_ns{0};
    std::int64_t phase_window_high_ns{0};
    std::int64_t phase_wait_deadline_ns{0};
    std::int64_t phase_wait_started_ns{0};
    std::int64_t last_prime_grid_phase_us{-1};
    std::uint64_t phase_wait_discarded{0};
    std::int64_t pending_trigger_target_ns{0};
    std::int64_t last_prime_ns{0};
    std::int64_t last_prime_phase_us{-1};
    std::int64_t last_first_tick_wait_us{-1};
    std::size_t last_ring_at_prime{0};
    std::size_t last_prime_dropped{0};
    std::int64_t last_front_age_frames{-1};
    std::int64_t last_capture_wake_ns{0};
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
    // The DSP stage, on usb-to-ravenna only. Loaded before the audio thread
    // starts; process() allocates nothing and cannot throw.
    usb16x16::DspStage dsp;
    bool dsp_enabled{false};
    bool dsp_announced{false};
    // Renders since this direction primed. The prime render is 192 frames --
    // 4 ms of audio -- inside a 150 us placement margin that already spends
    // about 104 us, so filtering it would miss the target every time and move
    // the aligned start a period later. It is therefore rendered unfiltered
    // and the stage engages from the next render on. Reset by a re-prime.
    std::uint64_t renders_after_prime{};
    // Loop-mode injector (Options::loop_impulse_*): the output position of
    // the next impulse, zero until the first filtered render after a prime
    // sets it one period ahead; and the count written.
    std::size_t loop_impulse_channel{0};
    std::uint64_t loop_impulse_period_frames{0};
    std::uint64_t next_loop_impulse_frame{0};
    std::uint64_t loop_impulses{0};
    // What the stage costs on the audio thread. The maximum is the figure
    // that matters: a mean hides exactly the cycle that missed a deadline.
    std::int64_t dsp_ns_max{};
    std::uint64_t dsp_ns_total{};
    std::uint64_t dsp_calls{};
    std::uint64_t dsp_frames{};
    // Level meter taps on the block read from this direction's capture and
    // on the block written to its playback (after the DSP stage on TX), off
    // unless --meter-file names a snapshot file. Timed like the stage: the
    // maximum is what a missed deadline would show.
    bool meter_enabled{false};
    usb16x16::LevelMeter capture_meter;
    usb16x16::LevelMeter playback_meter;
    std::int64_t meter_ns_max{};
    std::uint64_t meter_ns_total{};
    std::uint64_t meter_calls{};
    // Zero-run detectors on the block read from this direction's capture
    // and on the block written to its playback, with the stage names the
    // ZERORUN lines carry. Off unless --zero-run-detect 1.
    bool zero_run_detect{false};
    std::string_view capture_stage;
    std::string_view playback_stage;
    usb16x16::ZeroRunDetector capture_zero;
    usb16x16::ZeroRunDetector playback_zero;
    std::uint64_t zero_run_lines{0};
    std::uint64_t zero_run_lines_suppressed{0};
    // Impulse trace on the same two blocks. Off unless --impulse-trace 1.
    bool impulse_trace{false};
    usb16x16::ImpulseTraceDetector capture_impulse;
    usb16x16::ImpulseTraceDetector playback_impulse;
    std::uint64_t impulse_lines{0};
    std::uint64_t impulse_lines_suppressed{0};

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

// Wall-clock stamp for a ZERORUN line, so a hole can be set beside the
// Mac's dump timestamps and the Ferrofish's counters without the journal.
// Formats into a fixed buffer; no allocation.
void format_utc_now(char* buffer, const std::size_t size) noexcept {
    timespec now{};
    clock_gettime(CLOCK_REALTIME, &now);
    tm parts{};
    gmtime_r(&now.tv_sec, &parts);
    const int milliseconds = static_cast<int>((now.tv_nsec / 1000000L) % 1000L);
    std::snprintf(buffer, size, "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
                  parts.tm_year + 1900, parts.tm_mon + 1, parts.tm_mday,
                  parts.tm_hour, parts.tm_min, parts.tm_sec, milliseconds);
}

// Drains a detector's events as ZERORUN lines. Runs on the audio thread,
// the same path PRIMED, RECOVER and DEPTHSTEP take, because a hole is
// about one event in three minutes; the per-direction cap bounds it.
// start_mod48 is the run's phase on the bridge's own 48-frame count, a
// per-session constant when the holes sit on the RAVENNA packet grid.
void report_zero_runs(Direction& direction,
                      usb16x16::ZeroRunDetector& detector,
                      const std::string_view stage) noexcept {
    usb16x16::ZeroRunDetector::Event event{};
    while (detector.pop_event(event)) {
        if (direction.zero_run_lines >= kZeroRunLineCap) {
            ++direction.zero_run_lines_suppressed;
            continue;
        }
        ++direction.zero_run_lines;
        std::size_t channels = 0;
        for (std::size_t channel = 0; channel < kChannels; ++channel) {
            channels += (event.channel_mask >> channel) & 1U;
        }
        // Sized for GCC's format-range analysis, which cannot bound tm
        // fields; the stamp itself is 24 bytes.
        char utc[96];
        format_utc_now(utc, sizeof(utc));
        char mask[16];
        std::snprintf(mask, sizeof(mask), "0x%04x", event.channel_mask & 0xFFFFU);
        std::cerr << "ZERORUN stage=" << stage
                  << " direction=" << direction.name
                  << " start=" << event.start_frame
                  << " length=" << event.length
                  << " channels=" << mask
                  << " nchan=" << channels
                  << " start_mod48=" << event.start_frame % 48
                  << " events=" << detector.events()
                  << " t_us=" << elapsed_us()
                  << " utc=" << utc << '\n';
    }
}

// Drains an impulse detector's events as IMPULSE lines, on the audio thread
// like ZERORUN. block_ns is the monotonic instant the block belongs to: the
// capture wake that found it, or the write of it to the playback; offset
// is the hit's frame inside that block. depth is the capture backlog the
// wake found, or the playback queue as last sampled, in frames.
void report_impulses(Direction& direction,
                     usb16x16::ImpulseTraceDetector& detector,
                     const std::string_view stage,
                     const std::uint64_t block_first_frame,
                     const std::size_t block_frames,
                     const std::int64_t block_ns,
                     const std::int64_t depth,
                     const char* depth_source) noexcept {
    usb16x16::ImpulseTraceDetector::Event event{};
    while (detector.pop_event(event)) {
        if (direction.impulse_lines >= kImpulseLineCap) {
            ++direction.impulse_lines_suppressed;
            continue;
        }
        ++direction.impulse_lines;
        std::cerr << "IMPULSE stage=" << stage
                  << " direction=" << direction.name
                  << " position=" << event.position
                  << " value=" << event.value
                  << " block_first=" << block_first_frame
                  << " block_frames=" << block_frames
                  << " offset=" << event.position - block_first_frame
                  << " depth=" << depth
                  << " depth_src=" << depth_source
                  << " block_ns=" << block_ns
                  << " now_ns=" << monotonic_now_ns()
                  << " events=" << detector.events()
                  << " t_us=" << elapsed_us() << '\n';
    }
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

// One timed meter observation. Two clock reads a call, the same instrument
// the DSP stage carries, so meter_us_max on the BRIDGE line is the tap's own
// worst case and not an estimate.
void meter_observe(Direction& direction, usb16x16::LevelMeter& meter,
                   const float* block, const std::size_t frames) noexcept {
    const std::int64_t started_ns = monotonic_now_ns();
    meter.observe(block, frames);
    const std::int64_t spent_ns = monotonic_now_ns() - started_ns;
    direction.meter_ns_max = std::max(direction.meter_ns_max, spent_ns);
    direction.meter_ns_total += static_cast<std::uint64_t>(spent_ns);
    ++direction.meter_calls;
}

IoResult capture_into_ring(Direction& direction, const std::int64_t iteration_ns) noexcept {
    const snd_pcm_sframes_t available = direction.capture.available();
    if (available == -EPIPE || available == -ESTRPIPE) {
        return request_recovery(direction, "capture-avail", available);
    }
    if (available >= 0) {
        // Sample before the zero-backlog early return below, so the mean is
        // over every iteration rather than only the ones that found data. The
        // latter would bias it upward and overstate the capture contribution.
        const auto backlog = static_cast<std::size_t>(available);
        if (backlog > 0) {
            direction.last_capture_wake_ns = iteration_ns;
        }
        if (backlog == static_cast<std::size_t>(direction.capture.period()) &&
            direction.last_capture_backlog == 0) {
            direction.last_fresh_wake_ns = iteration_ns;
        }
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
    if (direction.meter_enabled) {
        meter_observe(direction, direction.capture_meter, direction.capture_scratch.data(), frames);
    }
    if (direction.zero_run_detect) {
        // The block as the device delivered it, positioned on this
        // direction's cumulative input count.
        direction.capture_zero.observe(direction.capture_scratch.data(), frames, direction.input_frames);
        report_zero_runs(direction, direction.capture_zero, direction.capture_stage);
    }
    if (direction.impulse_trace) {
        direction.capture_impulse.observe(direction.capture_scratch.data(), frames, direction.input_frames);
        report_impulses(direction, direction.capture_impulse, direction.capture_stage,
                        direction.input_frames, frames, iteration_ns, available, "avail");
    }
    direction.input_frames += frames;
    return IoResult::progressed;
}

// Sleeps to the next reference wake + offset + n * tick before the caller
// triggers the playback, at most one tick plus the margin. Returns the
// reference wake used, or 0 when the trigger had to run unaligned (no
// reference yet, or one older than kAlignReferenceMaximumAgeNs), which is
// logged as such so an unaligned session is never mistaken for an aligned
// one. Runs on the audio thread; the other direction holds at least two
// periods of playback queue across one tick of sleep, as the aligned RX
// recovery already relies on.
std::int64_t align_playback_trigger(Direction& direction, int& sleep_result) noexcept {
    std::int64_t wake_ns = direction.tick_source != nullptr ? direction.tick_source->last_fresh_wake_ns : 0;
    const char* source = "fresh-wake";
    if (wake_ns <= 0) {
        wake_ns = direction.align_trigger_seed_ns;
        source = "start-reference";
    }
    const std::int64_t now_ns = monotonic_now_ns();
    if (wake_ns <= 0 || now_ns - wake_ns > kAlignReferenceMaximumAgeNs) {
        ++direction.unaligned_triggers;
        std::cerr << "ALIGN trigger direction=" << direction.name
                  << " status=unaligned reason=" << (wake_ns <= 0 ? "no-reference" : "stale-reference")
                  << " wake_age_us=" << (wake_ns <= 0 ? -1 : (now_ns - wake_ns) / 1000)
                  << " t_us=" << elapsed_us() << '\n';
        return 0;
    }
    const std::int64_t reference_ns = wake_ns + direction.align_trigger_offset_ns;
    // The prime's target when it is still ahead; otherwise the next grid
    // point, which for a prime target the render overran is one tick later.
    const std::int64_t pending_ns = direction.pending_trigger_target_ns;
    const bool pending_hit = pending_ns > now_ns;
    const std::int64_t target_ns = pending_hit
        ? pending_ns
        : usb16x16::next_aligned_time(
              reference_ns, direction.align_trigger_tick_ns, now_ns + kAlignRecoveryMarginNs);
    const std::int64_t slack_us = (pending_ns > 0 ? pending_ns - now_ns : target_ns - now_ns) / 1000;
    direction.pending_trigger_target_ns = 0;
    timespec target{};
    target.tv_sec = static_cast<time_t>(target_ns / 1000000000LL);
    target.tv_nsec = static_cast<long>(target_ns % 1000000000LL);
    do {
        sleep_result = clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &target, nullptr);
    } while (sleep_result == EINTR && !stop_requested.load(std::memory_order_relaxed));
    const std::int64_t before_start_ns = monotonic_now_ns();
    direction.last_trigger_wake_to_start_us =
        (before_start_ns - (target_ns - direction.align_trigger_offset_ns)) / 1000;
    ++direction.aligned_triggers;
    std::cerr << "ALIGN trigger direction=" << direction.name
              << " status=ok source=" << source
              << " wake_age_us=" << (before_start_ns - wake_ns) / 1000
              << " wake_to_start_us=" << direction.last_trigger_wake_to_start_us
              << " target=" << (pending_ns > 0 ? (pending_hit ? "prime" : "prime-missed") : "next")
              << " slack_us=" << slack_us
              << " sleep_result=" << sleep_result
              << " t_us=" << elapsed_us() << '\n';
    return wake_ns;
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
        // Grid phase at this prime instant, for the record and, with a
        // window set, as the gate: hold and discard until the phase is
        // inside the window or the timeout passes.
        if (direction.phase_reference != nullptr) {
            const std::int64_t own_wake = direction.last_fresh_wake_ns;
            const std::int64_t reference_wake = direction.phase_reference->last_fresh_wake_ns;
            const std::int64_t now_ns = monotonic_now_ns();
            const bool have_phase = own_wake > 0 && reference_wake > 0;
            const std::int64_t phase_ns = have_phase ? usb16x16::grid_phase_ns(own_wake, reference_wake, kUsbFrameTickNs) : -1;
            if (direction.phase_window) {
                if (direction.phase_wait_started_ns == 0) {
                    direction.phase_wait_started_ns = now_ns;
                }
                const bool inside = have_phase &&
                    usb16x16::phase_in_window(phase_ns, direction.phase_window_low_ns, direction.phase_window_high_ns);
                if (!inside && now_ns < direction.phase_wait_deadline_ns) {
                    // Hold: drain the ring to the largest whole number of
                    // capture periods below the prime level, so the push that
                    // finally crosses the threshold lands the ring exactly
                    // where an unheld start lands (192 for a 187 threshold at
                    // period 48, not 235). Draining only to the threshold
                    // left the next push as a 48-frame overshoot, one bin
                    // more RX depth (measured 2026-09-05: RX floor 120 and
                    // level +43 on the first held session). The discarded
                    // frames are counted; no playback has started yet.
                    const std::size_t period = static_cast<std::size_t>(direction.capture.period());
                    const std::size_t hold_level = period > 0 ? ((prime_frames - 1) / period) * period : prime_frames;
                    if (direction.ring.size() > hold_level) {
                        const std::size_t excess = direction.ring.size() - hold_level;
                        direction.ring.pop(excess);
                        direction.phase_wait_discarded += excess;
                    }
                    return IoResult::idle;
                }
                std::cerr << "PRIME window direction=" << direction.name
                          << " status=" << (inside ? "hit" : "timeout")
                          << " ring=" << direction.ring.size()
                          << " phase_us=" << (have_phase ? phase_ns / 1000 : -1)
                          << " window_us=" << direction.phase_window_low_ns / 1000 << ',' << direction.phase_window_high_ns / 1000
                          << " waited_ms=" << (now_ns - direction.phase_wait_started_ns) / 1000000
                          << " discarded=" << direction.phase_wait_discarded
                          << " t_us=" << elapsed_us() << '\n';
            }
            direction.last_prime_grid_phase_us = have_phase ? phase_ns / 1000 : -1;
        }
        // Aligned TX prime: the wait from this instant to the first tick
        // after the planned trigger lies in (margin + tick - offset,
        // margin + 2 * tick - offset]; hold the prime until the ring can
        // absorb the longest wait, then drop from the front so that the
        // front frame's age at the first tick is prime_frames plus the
        // longest wait, whatever this session's draw of the wait.
        std::size_t align_drop = 0;
        if (direction.align_prime && direction.align_trigger_tick_ns > 0) {
            const std::int64_t wake_ns = direction.tick_source != nullptr && direction.tick_source->last_fresh_wake_ns > 0
                ? direction.tick_source->last_fresh_wake_ns
                : direction.align_trigger_seed_ns;
            const std::int64_t now_ns = monotonic_now_ns();
            const std::int64_t tick_ns = direction.align_trigger_tick_ns;
            // Frames per tick from the rate the bridge enforces (48 kHz), not the
            // period: 48 at a 1000 us tick whatever period was negotiated.
            const std::int64_t frames_per_tick = (48000LL * tick_ns + 500000000LL) / 1000000000LL;
            // Waits in frames: the shortest rounded down, the longest up.
            // The target is placed kAlignPrimeMarginNs ahead, so the wait
            // to the first tick lies in (min_wait, max_wait]; the age is
            // priced on the shorter bound the age margin gives, and the
            // difference is how far under the prime level the drop may
            // leave the ring in the sessions whose wait exceeds it (see
            // kAlignPrimeAgeMarginDefaultUs; zero at the default).
            const std::int64_t min_wait_ns = kAlignPrimeMarginNs + tick_ns - direction.align_trigger_offset_ns;
            const std::int64_t max_wait_ns = min_wait_ns + tick_ns;
            const std::int64_t aged_wait_ns = direction.align_prime_age_margin_ns + 2 * tick_ns - direction.align_trigger_offset_ns;
            const std::int64_t min_wait_frames = min_wait_ns * frames_per_tick / tick_ns;
            const std::int64_t max_wait_frames = (max_wait_ns * frames_per_tick + tick_ns - 1) / tick_ns;
            const std::int64_t aged_wait_frames = (aged_wait_ns * frames_per_tick + tick_ns - 1) / tick_ns;
            const std::int64_t under_prime_allowed = std::max<std::int64_t>(max_wait_frames - aged_wait_frames, 0);
            const std::int64_t age_frames = static_cast<std::int64_t>(prime_frames) + aged_wait_frames;
            if (wake_ns <= 0 && direction.align_trigger_seed_ns == 0) {
                // No seed and no fresh wake yet (RX, whose grid is the USB
                // capture): hold the prime briefly for the first one.
                if (direction.align_prime_wait_deadline_ns == 0) {
                    direction.align_prime_wait_deadline_ns = now_ns + kAlignPrimeReferenceWaitNs;
                }
                if (now_ns < direction.align_prime_wait_deadline_ns) {
                    return IoResult::idle;
                }
                std::cerr << "ALIGN prime direction=" << direction.name
                          << " status=unaligned reason=no-reference-wake t_us=" << elapsed_us() << '\n';
                direction.align_prime = false;
            } else if (wake_ns <= 0 || now_ns - wake_ns > kAlignReferenceMaximumAgeNs) {
                // No usable grid: prime and trigger as the aligned trigger alone would.
                direction.align_prime = false;
            } else if (static_cast<std::int64_t>(direction.ring.size()) < age_frames - min_wait_frames) {
                return IoResult::idle;
            } else {
                const std::int64_t target_ns = usb16x16::next_aligned_time(
                    wake_ns + direction.align_trigger_offset_ns, tick_ns, now_ns + kAlignPrimeMarginNs);
                const std::int64_t first_tick_ns = target_ns - direction.align_trigger_offset_ns + tick_ns;
                const std::int64_t wait_ns = first_tick_ns - now_ns;
                const std::int64_t wait_frames = wait_ns * frames_per_tick / tick_ns;
                const std::int64_t drop = static_cast<std::int64_t>(direction.ring.size()) + wait_frames - age_frames;
                const std::int64_t drop_limit = static_cast<std::int64_t>(direction.ring.size() - prime_frames) + under_prime_allowed;
                align_drop = static_cast<std::size_t>(std::clamp<std::int64_t>(drop, 0, drop_limit));
                direction.pending_trigger_target_ns = target_ns;
                direction.last_prime_ns = now_ns;
                direction.last_prime_phase_us = ((now_ns - wake_ns) % tick_ns) / 1000;
                direction.last_first_tick_wait_us = wait_ns / 1000;
                direction.last_front_age_frames = static_cast<std::int64_t>(direction.ring.size() - align_drop) + wait_frames;
                direction.last_prime_dropped = align_drop;
                if (align_drop > 0) {
                    direction.ring.pop(align_drop);
                }
            }
        }
        direction.last_ring_at_prime = direction.ring.size() + align_drop;
        // The ring is checked on capture wakeups, so it can overshoot the
        // threshold by a whole capture period before this is reached. Whatever
        // it overshoots by becomes permanent pipeline depth: total depth is set
        // here and then conserved, because there is no restoring force on the
        // common mode. Report it rather than infer it from occupancy later.
        const std::size_t ring_at_prime = direction.ring.size();
        // The aligned drop may leave the ring under the prime level by what
        // the age margin no longer prices; report it as under_prime.
        const std::size_t overshoot = ring_at_prime > prime_frames ? ring_at_prime - prime_frames : 0;
        const std::size_t under_prime = prime_frames > ring_at_prime ? prime_frames - ring_at_prime : 0;
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
                  << " grid_phase_us=" << direction.last_prime_grid_phase_us
                  << " intended=" << prime_frames
                  << " ring_at_prime=" << ring_at_prime
                  << " overshoot=" << overshoot
                  << " trimmed=" << trimmed
                  << " queue_prime=" << queue_prime
                  << " align_dropped=" << align_drop
                  << " prime_phase_us=" << direction.last_prime_phase_us
                  << " first_tick_wait_us=" << direction.last_first_tick_wait_us
                  << " front_age_frames=" << direction.last_front_age_frames
                  << " under_prime=" << under_prime
                  << " capture_wake_age_us=" << (direction.last_capture_wake_ns > 0 ? (monotonic_now_ns() - direction.last_capture_wake_ns) / 1000 : -1)
                  << " t_us=" << elapsed_us() << '\n';
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
    // The prime render: unfiltered and unmetered, see renders_after_prime.
    const bool prime_render = direction.renders_after_prime == 0;
    if (direction.dsp_enabled) {
        if (prime_render) {
            // The prime render, deliberately unfiltered: see renders_after_prime.
        } else {
            if (!direction.dsp_announced) {
                direction.dsp_announced = true;
                std::cerr << "DSP engaged direction=" << direction.name
                          << " preset=\"" << direction.dsp.preset() << "\""
                          << " biquads=" << direction.dsp.biquad_count()
                          << " t_us=" << elapsed_us() << '\n';
            }
            const std::int64_t started_ns = monotonic_now_ns();
            direction.dsp.process(direction.playback_scratch.data(), produced);
            const std::int64_t spent_ns = monotonic_now_ns() - started_ns;
            direction.dsp_ns_max = std::max(direction.dsp_ns_max, spent_ns);
            direction.dsp_ns_total += static_cast<std::uint64_t>(spent_ns);
            ++direction.dsp_calls;
            direction.dsp_frames += produced;
        }
    }
    ++direction.renders_after_prime;
    if (direction.loop_impulse_period_frames != 0 && !prime_render) {
        // The loop's injector, after the stage so the preset's gain does not
        // touch it: one 0.25 full-scale sample (the harness level the wire
        // instrument matches) replacing the sample at that output position,
        // every period frames of output, from one period after the first
        // filtered render of this prime.
        if (direction.next_loop_impulse_frame == 0) {
            direction.next_loop_impulse_frame = direction.output_frames + direction.loop_impulse_period_frames;
        }
        while (direction.next_loop_impulse_frame < direction.output_frames + produced) {
            const std::size_t frame =
                static_cast<std::size_t>(direction.next_loop_impulse_frame - direction.output_frames);
            direction.playback_scratch[frame * kChannels + direction.loop_impulse_channel - 1] = 0.25F;
            direction.next_loop_impulse_frame += direction.loop_impulse_period_frames;
            ++direction.loop_impulses;
        }
    }
    std::uint64_t clipped = 0;
    for (snd_pcm_uframes_t frame = 0; frame < frames; ++frame) {
        for (std::size_t channel = 0; channel < kChannels; ++channel) {
            const float sample = direction.playback_scratch[frame * kChannels + channel];
            clipped += usb16x16::exceeds_full_scale(sample) ? 1U : 0U;
            write_area_sample(areas[channel], offset + frame, direction.playback.format(), sample);
        }
    }
    direction.clipped_samples += clipped;
    if (direction.meter_enabled && !prime_render) {
        // The block as it leaves: after the stage on TX, so the output meters
        // read what the wire carries.
        meter_observe(direction, direction.playback_meter, direction.playback_scratch.data(), frames);
    }
    if (direction.zero_run_detect) {
        // The block as the bridge hands it to the device, positioned on
        // this direction's cumulative output count.
        direction.playback_zero.observe(direction.playback_scratch.data(), frames, direction.output_frames);
        report_zero_runs(direction, direction.playback_zero, direction.playback_stage);
    }
    if (direction.impulse_trace) {
        direction.playback_impulse.observe(direction.playback_scratch.data(), frames, direction.output_frames);
        // The queue this block lands behind: exact, from the device, on the
        // blocks that carry a hit (about four a second under the harness);
        // the 1 Hz telemetry sample otherwise, which the first session
        // showed is up to a period off at the write instant.
        std::int64_t depth = direction.playback_delay;
        const char* depth_source = "sampled";
        if (direction.playback_impulse.pending() > 0) {
            snd_pcm_sframes_t exact = 0;
            if (direction.playback.delay(exact) == 0 && exact >= 0) {
                depth = exact;
                depth_source = "delay";
            }
        }
        report_impulses(direction, direction.playback_impulse, direction.playback_stage,
                        direction.output_frames, frames, monotonic_now_ns(), depth, depth_source);
    }
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
        if (direction.align_trigger_tick_ns > 0) {
            int sleep_result = 0;
            align_playback_trigger(direction, sleep_result);
        }
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
    direction.playback.prepare();
    direction.ring.clear();
    direction.resampler.reset();
    // A run open across the restart is the cleared ring, not a hole.
    direction.capture_zero.reset();
    direction.playback_zero.reset();
    direction.capture_impulse.reset();
    direction.playback_impulse.reset();
    direction.primed = false;
    direction.playback_started = false;
    // The stream broke, so the next render is a prime again and must not
    // filter; and the filter state belongs to a stream that no longer exists,
    // so it is cleared rather than left to ring into the new one.
    direction.renders_after_prime = 0;
    direction.next_loop_impulse_frame = 0;
    if (direction.dsp_enabled) {
        direction.dsp.reset();
    }
    ++direction.restarts;
    if (direction.align_tick_ns > 0 && direction.last_fresh_wake_ns > 0) {
        // Re-prepare on the tick phase the start alignment chose: the next
        // reference + offset + n * tick from now, at most one tick away.
        const std::int64_t reference_ns = direction.last_fresh_wake_ns + direction.align_offset_ns;
        const std::int64_t target_ns = usb16x16::next_aligned_time(
            reference_ns, direction.align_tick_ns, monotonic_now_ns() + kAlignRecoveryMarginNs);
        timespec target{};
        target.tv_sec = static_cast<time_t>(target_ns / 1000000000LL);
        target.tv_nsec = static_cast<long>(target_ns % 1000000000LL);
        int sleep_result = 0;
        do {
            sleep_result = clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &target, nullptr);
        } while (sleep_result == EINTR && !stop_requested.load(std::memory_order_relaxed));
        const std::int64_t before_prepare_ns = monotonic_now_ns();
        direction.capture.prepare();
        const std::int64_t after_prepare_ns = monotonic_now_ns();
        direction.capture.start_capture();
        ++direction.realigned_recoveries;
        std::cerr << "ALIGN recovery direction=" << direction.name
                  << " wake_age_us=" << (before_prepare_ns - direction.last_fresh_wake_ns) / 1000
                  << " wake_to_prepare_us=" << (before_prepare_ns - (target_ns - direction.align_offset_ns)) / 1000
                  << " prepare_us=" << (after_prepare_ns - before_prepare_ns) / 1000
                  << " sleep_result=" << sleep_result
                  << " t_us=" << elapsed_us() << '\n';
        direction.last_fresh_wake_ns = 0;
        return;
    }
    direction.capture.prepare();
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

struct AlignResult {
    bool ok{false};
    int attempts{0};
    std::int64_t tick_period_us{0};
    std::int64_t wake_to_prepare_us{0};
    std::int64_t prepare_us{0};
    // The reference wake, monotonic ns: the last observed tick wakeup, which
    // seeds the aligned TX trigger's grid until the loop sees a fresh wake.
    std::int64_t reference_ns{0};
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
    result.reference_ns = reference_ns;
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
    telemetry.tx_dsp_ns_max.store(tx.dsp_ns_max, std::memory_order_relaxed);
    telemetry.tx_dsp_ns_total.store(tx.dsp_ns_total, std::memory_order_relaxed);
    telemetry.tx_dsp_calls.store(tx.dsp_calls, std::memory_order_relaxed);
    telemetry.tx_dsp_frames.store(tx.dsp_frames, std::memory_order_relaxed);
    telemetry.tx_meter_ns_max.store(tx.meter_ns_max, std::memory_order_relaxed);
    telemetry.rx_meter_ns_max.store(rx.meter_ns_max, std::memory_order_relaxed);
    telemetry.tx_meter_ns_total.store(tx.meter_ns_total, std::memory_order_relaxed);
    telemetry.rx_meter_ns_total.store(rx.meter_ns_total, std::memory_order_relaxed);
    telemetry.tx_meter_calls.store(tx.meter_calls, std::memory_order_relaxed);
    telemetry.rx_meter_calls.store(rx.meter_calls, std::memory_order_relaxed);
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
    telemetry.tx_loop_impulses.store(tx.loop_impulses, std::memory_order_relaxed);
    const auto publish_zero = [](const usb16x16::ZeroRunDetector& detector,
                                 Telemetry::ZeroRunCounters& counters) {
        counters.events.store(detector.events(), std::memory_order_relaxed);
        counters.frames.store(detector.zero_frames(), std::memory_order_relaxed);
        counters.longest.store(detector.longest(), std::memory_order_relaxed);
        counters.long_runs.store(detector.long_runs(), std::memory_order_relaxed);
    };
    publish_zero(tx.capture_zero, telemetry.usb_capture_zero);
    publish_zero(tx.playback_zero, telemetry.ravenna_playback_zero);
    publish_zero(rx.capture_zero, telemetry.ravenna_capture_zero);
    publish_zero(rx.playback_zero, telemetry.usb_playback_zero);
}

// events/frames/longest/long_runs, the BRIDGE and SUMMARY form.
std::string format_zero_counters(const Telemetry::ZeroRunCounters& counters) {
    return std::to_string(counters.events.load()) + '/' +
           std::to_string(counters.frames.load()) + '/' +
           std::to_string(counters.longest.load()) + '/' +
           std::to_string(counters.long_runs.load());
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

// Mean microseconds per DSP call. Reported beside the maximum, never instead
// of it: the mean is what the stage usually costs, the maximum is whether it
// fits.
// The meter tap's mean over both directions and both stages, microseconds.
double meter_mean_us(const Telemetry& telemetry) noexcept {
    const std::uint64_t calls = telemetry.tx_meter_calls.load(std::memory_order_relaxed) +
                                telemetry.rx_meter_calls.load(std::memory_order_relaxed);
    if (calls == 0) {
        return 0.0;
    }
    const std::uint64_t total = telemetry.tx_meter_ns_total.load(std::memory_order_relaxed) +
                                telemetry.rx_meter_ns_total.load(std::memory_order_relaxed);
    return static_cast<double>(total) / static_cast<double>(calls) / 1000.0;
}

double dsp_mean_us(const Telemetry& telemetry) noexcept {
    const std::uint64_t calls = telemetry.tx_dsp_calls.load(std::memory_order_relaxed);
    if (calls == 0) {
        return 0.0;
    }
    return static_cast<double>(telemetry.tx_dsp_ns_total.load(std::memory_order_relaxed)) /
           static_cast<double>(calls) / 1000.0;
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

void telemetry_loop(Telemetry& telemetry, PitchControl* pitch_control, const bool aoip_loop) {
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
        std::cout << std::fixed << std::setprecision(3) << "BRIDGE ";
        if (aoip_loop) {
            // The mode first, so a loop log cannot be read as a duplex one:
            // the single direction reports under the tx_ keys and the rx_
            // keys are the idle placeholder's zeros.
            std::cout << "mode=aoip-loop loop_impulses=" << telemetry.tx_loop_impulses.load() << ' ';
        }
        std::cout << "ppm=" << static_cast<double>(telemetry.ppm_milli.load()) / 1000.0
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
                  << " dsp_us_max=" << static_cast<double>(telemetry.tx_dsp_ns_max.load()) / 1000.0
                  << " dsp_us_mean=" << dsp_mean_us(telemetry)
                  << " dsp_calls=" << telemetry.tx_dsp_calls.load()
                  << " dsp_live_gen=" << telemetry.dsp_live_generation.load()
                  << " dsp_live_sha=" << std::hex << std::setfill('0') << std::setw(16)
                  << telemetry.dsp_live_sha_prefix.load() << std::dec << std::setfill(' ')
                  << " dsp_live_refused=" << telemetry.dsp_live_refused.load()
                  << " meter_us_max=" << static_cast<double>(std::max(telemetry.tx_meter_ns_max.load(),
                                                                     telemetry.rx_meter_ns_max.load())) / 1000.0
                  << " meter_us_mean=" << meter_mean_us(telemetry)
                  << " pitch=" << telemetry.applied_pitch.load()
                  << " phase_us=" << telemetry.grid_phase_us.load()
                  << " bias_ppm="
                  << static_cast<double>(telemetry.level_bias_ppm_milli.load()) / 1000.0
                  << " pitch_errors=" << telemetry.pitch_write_errors.load()
                  << " pitch_p=" << telemetry.applied_playback_pitch.load()
                  << " tx_bias=" << static_cast<double>(telemetry.tx_bias_ppm_milli.load()) / 1000.0
                  << " rx_bias=" << static_cast<double>(telemetry.rx_bias_ppm_milli.load()) / 1000.0
                  << " tx_set=" << telemetry.tx_depth_setpoint.load()
                  << " rx_set=" << telemetry.rx_depth_setpoint.load()
                  << " zr_usbcap=" << format_zero_counters(telemetry.usb_capture_zero)
                  << " zr_ravplay=" << format_zero_counters(telemetry.ravenna_playback_zero)
                  << " zr_ravcap=" << format_zero_counters(telemetry.ravenna_capture_zero)
                  << " zr_usbplay=" << format_zero_counters(telemetry.usb_playback_zero) << '\n';
    }
}

// The meter publisher (2026-09-11). Off the audio thread entirely: every
// 25 ms it copies the four taps' last windows through their seqlocks and,
// when any has moved, rewrites the snapshot file in one rename. Text, in
// the key=value form the BRIDGE line uses, one line per stage, dB with one
// decimal, so `cat` reads it and the web service parses it with what it
// already has. It demotes itself to SCHED_OTHER first: a std::thread
// inherits the audio thread's SCHED_FIFO, and a file writer has no claim
// on that.
struct MeterTap {
    std::string_view stage;
    const usb16x16::LevelMeter* meter;
};
using MeterTaps = std::vector<MeterTap>;

void write_meter_file(const std::string& path, const std::string& text, std::uint64_t& failures,
                      const char* const tag = "METERS") noexcept {
    const std::string temporary = path + ".tmp";
    const int descriptor = ::open(temporary.c_str(), O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (descriptor < 0) {
        if (failures++ == 0) {
            std::cerr << tag << " write failed: " << temporary << ": " << std::strerror(errno) << '\n';
        }
        return;
    }
    std::size_t written = 0;
    bool ok = true;
    while (written < text.size()) {
        const ssize_t result = ::write(descriptor, text.data() + written, text.size() - written);
        if (result < 0) {
            if (errno == EINTR) {
                continue;
            }
            ok = false;
            break;
        }
        written += static_cast<std::size_t>(result);
    }
    ::close(descriptor);
    if (!ok || std::rename(temporary.c_str(), path.c_str()) != 0) {
        if (failures++ == 0) {
            std::cerr << tag << " write failed: " << path << ": " << std::strerror(errno) << '\n';
        }
        ::unlink(temporary.c_str());
    }
}

void meter_loop(const std::string path, const MeterTaps taps) {
    {
        sched_param parameters{};
        parameters.sched_priority = 0;
        const int demoted = pthread_setschedparam(pthread_self(), SCHED_OTHER, &parameters);
        if (demoted != 0) {
            std::cerr << "METERS publisher kept the inherited scheduler: " << std::strerror(demoted) << '\n';
        }
    }
    std::vector<std::uint64_t> last_sequence(taps.size(), 0);
    std::vector<usb16x16::LevelMeter::Snapshot> snapshots(taps.size());
    std::uint64_t writes = 0;
    std::uint64_t failures = 0;
    std::string text;
    text.reserve(4096);
    while (!stop_requested.load(std::memory_order_relaxed)) {
        std::this_thread::sleep_for(std::chrono::milliseconds(25));
        bool moved = false;
        for (std::size_t tap = 0; tap < taps.size(); ++tap) {
            if (taps[tap].meter->read(snapshots[tap]) && snapshots[tap].sequence != last_sequence[tap]) {
                last_sequence[tap] = snapshots[tap].sequence;
                moved = true;
            }
        }
        if (!moved) {
            continue;
        }
        ++writes;
        std::ostringstream out;
        out << std::fixed << std::setprecision(1)
            << "METERS v=1 t_us=" << elapsed_us()
            << " window_frames=" << taps[0].meter->window_frames()
            << " writes=" << writes << '\n';
        for (std::size_t tap = 0; tap < taps.size(); ++tap) {
            const usb16x16::LevelMeter::Snapshot& snapshot = snapshots[tap];
            out << "TAP stage=" << taps[tap].stage
                << " seq=" << snapshot.sequence
                << " frames=" << snapshot.frames
                << " position=" << snapshot.position
                << " peak_dbfs=";
            for (std::size_t channel = 0; channel < kChannels; ++channel) {
                out << (channel == 0 ? "" : ",") << usb16x16::amplitude_to_dbfs(snapshot.peak[channel]);
            }
            out << " rms_dbfs=";
            for (std::size_t channel = 0; channel < kChannels; ++channel) {
                const double mean_square = snapshot.frames == 0
                    ? 0.0 : snapshot.sum_squares[channel] / static_cast<double>(snapshot.frames);
                out << (channel == 0 ? "" : ",") << usb16x16::amplitude_to_dbfs(std::sqrt(mean_square));
            }
            out << " clip=";
            for (std::size_t channel = 0; channel < kChannels; ++channel) {
                out << (channel == 0 ? "" : ",") << snapshot.clipped[channel];
            }
            out << '\n';
        }
        text = out.str();
        write_meter_file(path, text, failures);
    }
    if (writes > 0 || failures > 0) {
        std::cerr << "METERS stopped writes=" << writes << " failures=" << failures << '\n';
    }
}

struct MeterThreadContext {
    std::string path;
    MeterTaps taps;
};

void* meter_thread_entry(void* raw) {
    auto* context = static_cast<MeterThreadContext*>(raw);
    meter_loop(context->path, context->taps);
    delete context;
    return nullptr;
}

// The live coefficient control thread (2026-09-13, LIVE_COEFFICIENTS_DESIGN.md
// step 3). Off the audio thread entirely, built like the meter publisher:
// created before capture starts on a 256 KB stack, demoted to SCHED_OTHER.
// Every 50 ms it stats the live file; when the inode, size or mtime moved it
// reads the file, loads it through the same loader the preset went through
// (allocation is fine here), and hands the numbers to the running stage with
// publish(), which refuses without touching anything the audio thread reads
// when the shape differs. "previous update not yet taken" is retried on the
// next poll rather than waited for. A file that predates this process is
// ignored: a restart comes back on the installed preset, never on a preview
// left behind, which is what the design promises the applier.
//
// The outcome of every file is one line, rewritten by rename:
//
//   DSPLIVE gen=N sha256=HEX state=applied|refused|ignored reason="..." t_us=T
//
// where gen is the publish count the audio thread has taken so far.
struct DspLiveContext {
    std::string path;
    std::string status_path;
    usb16x16::DspStage* stage;
    Telemetry* telemetry;
    struct timespec started{};
    // Read back for the SUMMARY after the thread is joined.
    std::string last_sha;
    std::uint64_t applied{0};
    std::uint64_t refused{0};
    std::uint64_t ignored{0};
};

std::uint64_t sha_prefix(const std::string& hex) {
    std::uint64_t value = 0;
    for (std::size_t index = 0; index < 16 && index < hex.size(); ++index) {
        const char digit = hex[index];
        const unsigned nibble = digit >= 'a' ? static_cast<unsigned>(digit - 'a' + 10)
                                             : static_cast<unsigned>(digit - '0');
        value = (value << 4) | nibble;
    }
    return value;
}

void dsp_live_loop(DspLiveContext& context) {
    {
        sched_param parameters{};
        parameters.sched_priority = 0;
        const int demoted = pthread_setschedparam(pthread_self(), SCHED_OTHER, &parameters);
        if (demoted != 0) {
            std::cerr << "DSPLIVE control thread kept the inherited scheduler: " << std::strerror(demoted) << '\n';
        }
    }
    std::uint64_t failures = 0;
    struct Seen { ino_t inode{}; off_t size{}; struct timespec mtime{}; bool any{false}; } seen;
    // A loaded update the audio thread has not yet made room for.
    std::optional<usb16x16::DspStage> pending;
    std::string pending_sha;
    const auto write_status = [&](const std::string& sha, const char* const state, const std::string& reason) {
        std::ostringstream out;
        out << "DSPLIVE gen=" << context.stage->generation()
            << " sha256=" << (sha.empty() ? "none" : sha)
            << " state=" << state
            << " reason=\"" << reason << "\""
            << " t_us=" << elapsed_us() << '\n';
        write_meter_file(context.status_path, out.str(), failures, "DSPLIVE");
        context.telemetry->dsp_live_generation.store(context.stage->generation(), std::memory_order_relaxed);
    };
    write_status(std::string{}, "idle", "no live file yet");
    while (!stop_requested.load(std::memory_order_relaxed)) {
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
        context.telemetry->dsp_live_generation.store(context.stage->generation(), std::memory_order_relaxed);
        if (pending) {
            std::string reason;
            if (context.stage->publish(*pending, reason)) {
                ++context.applied;
                context.last_sha = pending_sha;
                context.telemetry->dsp_live_sha_prefix.store(sha_prefix(pending_sha), std::memory_order_relaxed);
                std::cerr << "DSPLIVE applied sha256=" << pending_sha << " t_us=" << elapsed_us() << '\n';
                write_status(pending_sha, "applied", "");
                pending.reset();
            } else if (reason != "previous update not yet taken") {
                ++context.refused;
                context.telemetry->dsp_live_refused.fetch_add(1, std::memory_order_relaxed);
                std::cerr << "DSPLIVE refused sha256=" << pending_sha << " reason=\"" << reason << "\"\n";
                write_status(pending_sha, "refused", reason);
                pending.reset();
            }
            continue;
        }
        struct stat status{};
        if (::stat(context.path.c_str(), &status) != 0) {
            continue;   // absent is not an event
        }
        if (seen.any && status.st_ino == seen.inode && status.st_size == seen.size &&
            status.st_mtim.tv_sec == seen.mtime.tv_sec && status.st_mtim.tv_nsec == seen.mtime.tv_nsec) {
            continue;
        }
        seen = {status.st_ino, status.st_size, status.st_mtim, true};
        std::ifstream file(context.path, std::ios::binary);
        std::ostringstream text;
        text << file.rdbuf();
        const std::string body = text.str();
        const std::string sha = usb16x16::sha256_hex(body);
        if (status.st_mtim.tv_sec < context.started.tv_sec ||
            (status.st_mtim.tv_sec == context.started.tv_sec &&
             status.st_mtim.tv_nsec < context.started.tv_nsec)) {
            ++context.ignored;
            std::cerr << "DSPLIVE ignored sha256=" << sha << " reason=\"predates start\"\n";
            write_status(sha, "ignored", "predates start");
            continue;
        }
        try {
            pending.emplace(usb16x16::DspStage::load(body));
        } catch (const std::exception& error) {
            ++context.refused;
            context.telemetry->dsp_live_refused.fetch_add(1, std::memory_order_relaxed);
            std::cerr << "DSPLIVE refused sha256=" << sha << " reason=\"" << error.what() << "\"\n";
            write_status(sha, "refused", error.what());
            continue;
        }
        pending_sha = sha;
        // Tried now rather than at the next poll, so the common case costs
        // one poll interval, not two.
        std::string reason;
        if (context.stage->publish(*pending, reason)) {
            ++context.applied;
            context.last_sha = pending_sha;
            context.telemetry->dsp_live_sha_prefix.store(sha_prefix(pending_sha), std::memory_order_relaxed);
            std::cerr << "DSPLIVE applied sha256=" << pending_sha << " t_us=" << elapsed_us() << '\n';
            write_status(pending_sha, "applied", "");
            pending.reset();
        } else if (reason != "previous update not yet taken") {
            ++context.refused;
            context.telemetry->dsp_live_refused.fetch_add(1, std::memory_order_relaxed);
            std::cerr << "DSPLIVE refused sha256=" << pending_sha << " reason=\"" << reason << "\"\n";
            write_status(pending_sha, "refused", reason);
            pending.reset();
        }
    }
    std::cerr << "DSPLIVE stopped applied=" << context.applied << " refused=" << context.refused
              << " ignored=" << context.ignored << " failures=" << failures << '\n';
}

void* dsp_live_thread_entry(void* raw) {
    dsp_live_loop(*static_cast<DspLiveContext*>(raw));
    return nullptr;
}

int run(const Options& options) {
    // Loaded before anything opens a device: a preset that will not load should
    // cost a message, not a PCM. A preset that will not load also stops the
    // bridge rather than starting it without one -- a session that silently ran
    // direct when it was asked for DSP would be measured as if it had filtered.
    usb16x16::DspStage dsp_stage;
    bool dsp_loaded = false;
    if (!options.dsp_live_file.empty() && options.dsp_preset.empty()) {
        std::cerr << "--dsp-live-file needs --dsp-preset: there is no stage to update\n";
        return 2;
    }
    if (!options.dsp_preset.empty()) {
        std::ifstream preset_file(options.dsp_preset, std::ios::binary);
        if (!preset_file) {
            std::cerr << "DSP preset " << options.dsp_preset << " cannot be read\n";
            return 2;
        }
        std::ostringstream preset_text;
        preset_text << preset_file.rdbuf();
        try {
            dsp_stage = usb16x16::DspStage::load(preset_text.str());
        } catch (const std::exception& error) {
            std::cerr << "DSP preset " << options.dsp_preset << ": " << error.what() << '\n';
            return 2;
        }
        dsp_loaded = true;
        std::cerr << "DSP loaded file=" << options.dsp_preset
                  << " preset=\"" << dsp_stage.preset() << "\""
                  << " internal=" << dsp_stage.internal_channels()
                  << " biquads=" << dsp_stage.biquad_count()
                  << " delay_frames=" << dsp_stage.delay_samples()
                  << " shape=" << dsp_stage.shape_key() << '\n';
        if (dsp_stage.delay_samples() > 0) {
            // The alignment delay is transport latency, all of it, on every
            // output: the block is not complete until the most delayed channel
            // has been produced. Said here as well as in the compiler, because
            // this is where it is actually paid.
            std::cerr << "DSP delay adds " << dsp_stage.delay_samples() << " frames ("
                      << static_cast<double>(dsp_stage.delay_samples()) / 48.0
                      << " ms) of latency to every output, not only the delayed ones\n";
        }
    }
    const snd_pcm_uframes_t ravenna_playback_request = options.ravenna_playback_buffer != 0
        ? options.ravenna_playback_buffer
        : options.requested_buffer;
    // The gadget PCMs, in the order they have always opened; not opened at
    // all in loop mode, which is the whole of that mode's footprint on the
    // host side.
    std::optional<Pcm> usb_capture;
    std::optional<Pcm> usb_playback;
    if (!options.aoip_loop) {
        usb_capture.emplace("USB capture", options.usb_device, SND_PCM_STREAM_CAPTURE, SampleFormat::s24_3le, options,
                            options.requested_buffer);
        usb_playback.emplace("USB playback", options.usb_device, SND_PCM_STREAM_PLAYBACK, SampleFormat::s24_3le, options,
                             options.requested_buffer);
    }
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
    const std::size_t rx_prime = options.aoip_loop
        ? 0
        : resolve_prime(options.rx_playback_prime_frames, usb_playback->buffer());
    if (tx_prime > static_cast<std::size_t>(ravenna_playback.buffer())) {
        throw std::runtime_error("usb-to-ravenna prime exceeds the RAVENNA playback buffer");
    }
    if (!options.aoip_loop && rx_prime > static_cast<std::size_t>(usb_playback->buffer())) {
        throw std::runtime_error("ravenna-to-usb prime exceeds the USB playback buffer");
    }
    if (options.ring_frames < options.target_frames + std::max(tx_prime, rx_prime) + 4) {
        throw std::runtime_error("elastic ring is too small to prime the ALSA playback queues");
    }

    std::cout << "NEGOTIATED";
    if (options.aoip_loop) {
        std::cout << " mode=aoip-loop";
    } else {
        std::cout << " usb_capture=" << usb_capture->period() << '/' << usb_capture->buffer()
                  << " usb_playback=" << usb_playback->period() << '/' << usb_playback->buffer();
    }
    std::cout << " ravenna_capture=" << ravenna_capture.period() << '/' << ravenna_capture.buffer()
              << " ravenna_playback=" << ravenna_playback.period() << '/' << ravenna_playback.buffer() << '\n';

    // tx is the direction whose playback is RAVENNA: usb-to-ravenna in duplex
    // mode, the loop itself in loop mode. rx in loop mode is a placeholder
    // that is never driven -- it keeps every signature below unchanged, its
    // counters stay at zero and its floors at -1, and that is what the rx_
    // fields of a loop-mode BRIDGE line and SUMMARY mean.
    Direction tx = options.aoip_loop
        ? Direction("ravenna-to-ravenna", ravenna_capture, ravenna_playback, options.ring_frames)
        : Direction("usb-to-ravenna", *usb_capture, ravenna_playback, options.ring_frames);
    Direction rx = options.aoip_loop
        ? Direction("ravenna-to-usb-idle", ravenna_capture, ravenna_playback, options.ring_frames)
        : Direction("ravenna-to-usb", ravenna_capture, *usb_playback, options.ring_frames);
    if (dsp_loaded) {
        // usb-to-ravenna is the "USB -> DSP -> AoIP" path, and the loop is
        // "AoIP -> DSP -> AoIP". ravenna-to-usb stays a pass-through and
        // carries no bypassed instance, so there is nothing on the return
        // path to go wrong.
        tx.dsp = std::move(dsp_stage);
        tx.dsp_enabled = true;
    }
    if (options.aoip_loop) {
        tx.loop_impulse_channel = options.loop_impulse_channel;
        tx.loop_impulse_period_frames = options.loop_impulse_period_frames;
        if (options.loop_impulse_period_frames != 0) {
            std::cerr << "LOOPIMPULSE enabled channel=" << options.loop_impulse_channel
                      << " period_frames=" << options.loop_impulse_period_frames << '\n';
        }
    }
    tx.playback_prime_frames = tx_prime;
    rx.playback_prime_frames = rx_prime;
    tx.prime_trim = options.prime_trim;
    rx.prime_trim = options.prime_trim || options.rx_prime_trim;
    tx.align_prime_age_margin_ns = options.align_prime_age_margin_us * 1000;
    rx.align_prime_age_margin_ns = options.align_prime_age_margin_us * 1000;
    // Stage names in signal order round the loop: USB capture is the Mac's
    // output arriving, RAVENNA playback the wire out, RAVENNA capture the
    // wire back, USB playback the Mac's input leaving.
    tx.capture_stage = options.aoip_loop ? "ravenna-capture" : "usb-capture";
    tx.playback_stage = "ravenna-playback";
    rx.capture_stage = "ravenna-capture";
    rx.playback_stage = "usb-playback";
    // The directions that carry audio, in the order the loop drives them,
    // and their stage names in signal order for the instruments' lines.
    std::vector<Direction*> live{&tx};
    if (!options.aoip_loop) {
        live.push_back(&rx);
    }
    const char* const stage_list = options.aoip_loop
        ? "ravenna-capture,ravenna-playback"
        : "usb-capture,ravenna-playback,ravenna-capture,usb-playback";
    if (!options.meter_file.empty()) {
        for (Direction* direction : live) {
            direction->meter_enabled = true;
        }
        std::cerr << "METERS enabled file=" << options.meter_file
                  << " window_frames=" << tx.capture_meter.window_frames()
                  << " stages=" << stage_list << '\n';
    }
    if (options.zero_run_detect) {
        usb16x16::ZeroRunDetector::Config zero_config;
        zero_config.minimum_frames = options.zero_run_minimum_frames;
        zero_config.maximum_frames = options.zero_run_maximum_frames;
        for (Direction* direction : live) {
            direction->zero_run_detect = true;
            direction->capture_zero = usb16x16::ZeroRunDetector(zero_config);
            direction->playback_zero = usb16x16::ZeroRunDetector(zero_config);
        }
        std::cout << "ZERORUN enabled min_frames=" << options.zero_run_minimum_frames
                  << " max_frames=" << options.zero_run_maximum_frames
                  << " stages=" << stage_list
                  << " line_cap=" << kZeroRunLineCap << '\n';
    }
    if (options.impulse_trace) {
        usb16x16::ImpulseTraceDetector::Config impulse_config;
        impulse_config.channel = options.impulse_trace_channel - 1;
        impulse_config.threshold = static_cast<float>(options.impulse_trace_threshold);
        impulse_config.holdoff_frames = options.impulse_trace_holdoff;
        for (Direction* direction : live) {
            direction->impulse_trace = true;
            direction->capture_impulse = usb16x16::ImpulseTraceDetector(impulse_config);
            direction->playback_impulse = usb16x16::ImpulseTraceDetector(impulse_config);
        }
        std::cout << "IMPULSE enabled channel=" << options.impulse_trace_channel
                  << " threshold=" << options.impulse_trace_threshold
                  << " holdoff_frames=" << options.impulse_trace_holdoff
                  << " stages=" << stage_list
                  << " line_cap=" << kImpulseLineCap << '\n';
    }
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
                  << " rx_depth=" << options.rx_depth_frames
                  << " seed_ppm=" << options.pitch_seed_ppm
                  << " level_shift=" << options.level_shift_frames << '\n';
        if (options.pitch_seed_ppm != 0.0) {
            // Seed before any capture starts: the controls carry nominal
            // minus seed from the first frame, the telemetry thread sees the
            // value as already applied (so it does not rewrite it and the
            // regression's applied-ratio correction integrates the seed from
            // t=0), and the estimator starts at the seed so its first rate
            // observation, which measures the required ratio rather than
            // the residual, lands on it without a slew.
            const int seeded = static_cast<int>(std::clamp(
                std::lrint(static_cast<double>(kNominalPitch) - options.pitch_seed_ppm),
                long{kNominalPitch - 250}, long{kNominalPitch + 250}));
            const int written = pitch_control->write(seeded);
            if (written < 0) {
                throw std::runtime_error(std::string("pitch seed: ") + snd_strerror(written));
            }
            telemetry.wanted_pitch.store(seeded, std::memory_order_relaxed);
            telemetry.applied_pitch.store(seeded, std::memory_order_relaxed);
            telemetry.wanted_playback_pitch.store(seeded, std::memory_order_relaxed);
            telemetry.applied_playback_pitch.store(seeded, std::memory_order_relaxed);
            estimator.reset(options.pitch_seed_ppm);
            std::cout << "PITCHSERVO seeded ppm=" << options.pitch_seed_ppm
                      << " pitch=" << seeded << '\n';
        }
    } else if (options.pitch_seed_ppm != 0.0) {
        throw std::runtime_error("pitch-seed needs --usb-pitch-servo");
    }
    if (options.level_shift_frames != 0.0 && (!options.usb_pitch_servo || options.split_pitch_servo)) {
        throw std::runtime_error("level-shift needs --usb-pitch-servo 1");
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
    std::vector<Pcm*> capture_pcms;
    if (!options.aoip_loop) {
        capture_pcms.push_back(&*usb_capture);
    }
    capture_pcms.push_back(&ravenna_capture);
    auto poll_descriptors = make_poll_descriptors(capture_pcms);

    // The meter publisher is created here, before either capture starts and
    // before memory is locked, on a 256 KB stack. The first build created it
    // as a std::thread after the captures were running: under
    // mlockall(MCL_FUTURE) that populates and locks an 8 MB stack at once, a
    // few milliseconds inside a 4 ms capture buffer, and every start took a
    // RECOVER pair in both captures before the first prime (2026-09-11
    // 22:51 UTC, three starts). It stamps the file with elapsed_us() only
    // once a window has been published, which the audio loop does after
    // process_started is set; the seqlock's release/acquire orders the two.
    pthread_t meter_thread{};
    bool meter_thread_started = false;
    if (tx.meter_enabled) {
        MeterTaps taps{{tx.capture_stage, &tx.capture_meter}, {tx.playback_stage, &tx.playback_meter}};
        if (!options.aoip_loop) {
            taps.push_back({rx.capture_stage, &rx.capture_meter});
            taps.push_back({rx.playback_stage, &rx.playback_meter});
        }
        auto* context = new MeterThreadContext{options.meter_file, std::move(taps)};
        pthread_attr_t attributes;
        pthread_attr_init(&attributes);
        pthread_attr_setstacksize(&attributes, 256 * 1024);
        const int created = pthread_create(&meter_thread, &attributes, meter_thread_entry, context);
        pthread_attr_destroy(&attributes);
        if (created != 0) {
            delete context;
            throw std::runtime_error("meter publisher thread: " + std::string(std::strerror(created)));
        }
        meter_thread_started = true;
    }

    // The live coefficient control thread, created here for the same
    // reason and in the same way as the meter publisher above.
    pthread_t dsp_live_thread{};
    bool dsp_live_thread_started = false;
    std::unique_ptr<DspLiveContext> dsp_live;
    if (!options.dsp_live_file.empty()) {
        dsp_live = std::make_unique<DspLiveContext>();
        dsp_live->path = options.dsp_live_file;
        dsp_live->status_path = options.dsp_live_status.empty()
            ? options.dsp_live_file + ".status" : options.dsp_live_status;
        dsp_live->stage = &tx.dsp;
        dsp_live->telemetry = &telemetry;
        clock_gettime(CLOCK_REALTIME, &dsp_live->started);
        pthread_attr_t attributes;
        pthread_attr_init(&attributes);
        pthread_attr_setstacksize(&attributes, 256 * 1024);
        const int created = pthread_create(&dsp_live_thread, &attributes, dsp_live_thread_entry, dsp_live.get());
        pthread_attr_destroy(&attributes);
        if (created != 0) {
            throw std::runtime_error("dsp live control thread: " + std::string(std::strerror(created)));
        }
        dsp_live_thread_started = true;
        std::cerr << "DSPLIVE enabled file=" << dsp_live->path << " status=" << dsp_live->status_path
                  << " shape=" << tx.dsp.shape_key() << '\n';
    }

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
        if (align.ok && options.aoip_loop) {
            // The loop's capture is the aligned one: its recoveries re-prepare
            // on the measured phase, and its playback trigger and prime read
            // the grid through the direction's own fresh wakes, which are the
            // same RAVENNA capture wakes rx lends tx in duplex mode.
            tx.align_tick_ns = align.tick_period_us * 1000;
            tx.align_offset_ns = options.align_offset_us * 1000;
            if (options.align_tx_trigger) {
                tx.tick_source = &tx;
                tx.align_trigger_tick_ns = align.tick_period_us * 1000;
                tx.align_trigger_offset_ns = options.align_tx_offset_us * 1000;
                tx.align_trigger_seed_ns = align.reference_ns;
                tx.align_prime = options.align_tx_prime;
            }
        } else if (align.ok) {
            // RX recoveries re-prepare on the same phase; the measured tick
            // is the grid. TX is untouched.
            rx.align_tick_ns = align.tick_period_us * 1000;
            rx.align_offset_ns = options.align_offset_us * 1000;
            if (options.align_tx_trigger) {
                // TX triggers on the same grid; RX's fresh wakes carry the
                // reference forward, the start's own reference wake seeds it.
                tx.tick_source = &rx;
                tx.align_trigger_tick_ns = align.tick_period_us * 1000;
                tx.align_trigger_offset_ns = options.align_tx_offset_us * 1000;
                tx.align_trigger_seed_ns = align.reference_ns;
                tx.align_prime = options.align_tx_prime;
            }
            // The RX grid phase is always observed once the USB capture runs;
            // the window gates the prime only when set.
            rx.phase_reference = &tx;
            if (options.rx_prime_phase_window) {
                rx.phase_window = true;
                rx.phase_window_low_ns = options.rx_prime_phase_low_us * 1000;
                rx.phase_window_high_ns = options.rx_prime_phase_high_us * 1000;
                rx.phase_wait_deadline_ns = monotonic_now_ns() + options.rx_prime_phase_timeout_s * 1000000000LL;
            }
            if (options.align_rx_trigger) {
                // RX triggers and primes on the host's frame grid, read as
                // the USB capture's fresh wakes; no start reference exists
                // for that grid, so the prime waits for the first one.
                rx.tick_source = &tx;
                rx.align_trigger_tick_ns = kUsbFrameTickNs;
                rx.align_trigger_offset_ns = options.align_rx_offset_us * 1000;
                rx.align_trigger_seed_ns = 0;
                rx.align_prime = options.align_rx_prime;
            }
        }
        if (!options.aoip_loop) {
            usb_capture->start_capture();
        }
    } else {
        if (!options.aoip_loop) {
            usb_capture->start_capture();
        }
        ravenna_capture.start_capture();
        configure_realtime(options.priority);
    }

    std::thread telemetry_thread(telemetry_loop, std::ref(telemetry), pitch_control.get(), options.aoip_loop);
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
            const std::int64_t iteration_ns = monotonic_now_ns();
            const IoResult tx_capture = capture_into_ring(tx, iteration_ns);
            const IoResult rx_capture = options.aoip_loop ? IoResult::idle : capture_into_ring(rx, iteration_ns);
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
            // In loop mode both PCMs share the RAVENNA clock: 1.0 by construction.
            const double ratio = (options.usb_pitch_servo || options.aoip_loop) ? 1.0 : estimator.clock_ratio();
            const IoResult tx_playback = render_to_playback(tx, options.target_frames, ratio);
            const IoResult rx_playback = options.aoip_loop
                ? IoResult::idle
                : render_to_playback(rx, options.target_frames, 1.0 / ratio);
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

            const std::uint64_t telemetry_frame =
                options.aoip_loop ? tx.output_frames : std::min(tx.output_frames, rx.output_frames);
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
                const bool have_playback_delays = options.aoip_loop
                    ? (tx.playback_started &&
                       tx.playback.delay(tx_playback_delay) == 0 && tx_playback_delay >= 0)
                    : (tx.playback_started && rx.playback_started &&
                       tx.playback.delay(tx_playback_delay) == 0 &&
                       rx.playback.delay(rx_playback_delay) == 0 &&
                       tx_playback_delay >= 0 && rx_playback_delay >= 0);
                if (have_playback_delays) {
                    tx.playback_delay = tx_playback_delay;
                    rx.playback_delay = rx_playback_delay;
                }
                ++rate_update_samples;
                if (!options.aoip_loop && have_playback_delays && rate_update_samples >= kServoSamplesPerUpdate) {
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
                            // A shift of S frames from TX to RX lowers TX by S
                            // and raises RX by S, so the differential moves by
                            // -2S; the level loop walks there at its clamp.
                            level_setpoint_frames = differential_pipeline_frames - 2.0 * options.level_shift_frames;
                            have_level_setpoint = true;
                            std::cerr << "PITCHSERVO engaged setpoint_frames=" << level_setpoint_frames
                                      << " captured_frames=" << differential_pipeline_frames
                                      << " level_shift=" << options.level_shift_frames
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
                if (rx.phase_reference != nullptr && rx.last_fresh_wake_ns > 0 &&
                    rx.phase_reference->last_fresh_wake_ns > 0) {
                    telemetry.grid_phase_us.store(
                        usb16x16::grid_phase_ns(rx.last_fresh_wake_ns, rx.phase_reference->last_fresh_wake_ns, kUsbFrameTickNs) / 1000,
                        std::memory_order_relaxed);
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
        if (meter_thread_started) {
            pthread_join(meter_thread, nullptr);
        }
        if (dsp_live_thread_started) {
            pthread_join(dsp_live_thread, nullptr);
        }
        throw;
    }

    telemetry_thread.join();
    if (meter_thread_started) {
        pthread_join(meter_thread, nullptr);
    }
    if (dsp_live_thread_started) {
        pthread_join(dsp_live_thread, nullptr);
    }
    publish_telemetry(tx, rx, estimator, telemetry);
    const auto summary_floor = [](const std::size_t value) {
        return value == std::numeric_limits<std::size_t>::max()
            ? std::int64_t{-1}
            : static_cast<std::int64_t>(value);
    };
    std::cout << "SUMMARY {\"ppm\":" << std::fixed << std::setprecision(3) << estimator.ppm()
              << ",\"mode\":\"" << (options.aoip_loop ? "aoip-loop" : "usb-duplex") << "\""
              << ",\"loop_impulses\":" << tx.loop_impulses
              << ",\"dsp_preset\":\"" << (tx.dsp_enabled ? tx.dsp.preset() : std::string{}) << "\""
              << ",\"dsp_biquads\":" << (tx.dsp_enabled ? tx.dsp.biquad_count() : 0)
              << ",\"dsp_delay_frames\":" << (tx.dsp_enabled ? tx.dsp.delay_samples() : 0)
              << ",\"dsp_us_max\":" << static_cast<double>(tx.dsp_ns_max) / 1000.0
              << ",\"dsp_us_mean\":"
              << (tx.dsp_calls == 0 ? 0.0
                  : static_cast<double>(tx.dsp_ns_total) / static_cast<double>(tx.dsp_calls) / 1000.0)
              << ",\"dsp_calls\":" << tx.dsp_calls
              << ",\"dsp_live_gen\":" << (tx.dsp_enabled ? tx.dsp.generation() : 0)
              << ",\"dsp_live_sha\":\"" << (dsp_live ? dsp_live->last_sha : std::string{}) << "\""
              << ",\"dsp_live_applied\":" << (dsp_live ? dsp_live->applied : 0)
              << ",\"dsp_live_refused\":" << (dsp_live ? dsp_live->refused : 0)
              << ",\"dsp_frames\":" << tx.dsp_frames
              // Frames per call, so a maximum can be read against the block it
              // was paid on rather than against an assumed period.
              << ",\"dsp_frames_per_call\":"
              << (tx.dsp_calls == 0 ? 0.0
                  : static_cast<double>(tx.dsp_frames) / static_cast<double>(tx.dsp_calls))
              << ",\"meter_us_max\":" << static_cast<double>(std::max(tx.meter_ns_max, rx.meter_ns_max)) / 1000.0
              << ",\"meter_us_mean\":" << meter_mean_us(telemetry)
              << ",\"meter_calls\":" << (tx.meter_calls + rx.meter_calls)
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
              << ",\"pitch_seed_ppm\":" << options.pitch_seed_ppm
              << ",\"level_shift_frames\":" << options.level_shift_frames
              << ",\"pitch_write_errors\":" << telemetry.pitch_write_errors.load()
              << ",\"playback_pitch\":" << telemetry.applied_playback_pitch.load()
              << ",\"tx_bias_ppm\":" << tx_level.bias()
              << ",\"rx_bias_ppm\":" << rx_level.bias()
              << ",\"tx_depth_setpoint\":" << telemetry.tx_depth_setpoint.load()
              << ",\"rx_depth_setpoint\":" << telemetry.rx_depth_setpoint.load()
              << ",\"align_start\":" << (options.align_start ? 1 : 0)
              << ",\"align_ok\":" << (align.ok ? 1 : 0)
              << ",\"align_attempts\":" << align.attempts
              << ",\"align_recoveries\":" << (options.aoip_loop ? tx : rx).realigned_recoveries
              << ",\"align_tick_period_us\":" << align.tick_period_us
              << ",\"align_wake_to_prepare_us\":" << align.wake_to_prepare_us
              << ",\"align_prepare_us\":" << align.prepare_us
              << ",\"align_tx_trigger\":" << (options.align_tx_trigger ? 1 : 0)
              << ",\"align_tx_triggers\":" << tx.aligned_triggers
              << ",\"align_tx_unaligned_triggers\":" << tx.unaligned_triggers
              << ",\"align_tx_wake_to_start_us\":" << tx.last_trigger_wake_to_start_us
              << ",\"align_tx_prime\":" << (options.align_tx_prime ? 1 : 0)
              << ",\"align_tx_prime_dropped\":" << tx.last_prime_dropped
              << ",\"align_tx_prime_phase_us\":" << tx.last_prime_phase_us
              << ",\"align_tx_first_tick_wait_us\":" << tx.last_first_tick_wait_us
              << ",\"align_tx_front_age_frames\":" << tx.last_front_age_frames
              << ",\"align_prime_age_margin_us\":" << options.align_prime_age_margin_us
              << ",\"align_rx_trigger\":" << (options.align_rx_trigger ? 1 : 0)
              << ",\"align_rx_triggers\":" << rx.aligned_triggers
              << ",\"align_rx_unaligned_triggers\":" << rx.unaligned_triggers
              << ",\"align_rx_wake_to_start_us\":" << rx.last_trigger_wake_to_start_us
              << ",\"align_rx_prime\":" << (options.align_rx_prime ? 1 : 0)
              << ",\"align_rx_prime_dropped\":" << rx.last_prime_dropped
              << ",\"align_rx_prime_phase_us\":" << rx.last_prime_phase_us
              << ",\"align_rx_first_tick_wait_us\":" << rx.last_first_tick_wait_us
              << ",\"align_rx_front_age_frames\":" << rx.last_front_age_frames
              << ",\"rx_prime_trim\":" << (options.rx_prime_trim ? 1 : 0)
              << ",\"rx_prime_grid_phase_us\":" << rx.last_prime_grid_phase_us
              << ",\"rx_prime_phase_window\":" << (options.rx_prime_phase_window ? 1 : 0)
              << ",\"rx_prime_phase_discarded\":" << rx.phase_wait_discarded
              << ",\"zero_run_detect\":" << (options.zero_run_detect ? 1 : 0)
              << ",\"zero_run_min\":" << options.zero_run_minimum_frames
              << ",\"zero_run_max\":" << options.zero_run_maximum_frames
              << ",\"zero_usb_capture\":\"" << format_zero_counters(telemetry.usb_capture_zero) << '"'
              << ",\"zero_ravenna_playback\":\"" << format_zero_counters(telemetry.ravenna_playback_zero) << '"'
              << ",\"zero_ravenna_capture\":\"" << format_zero_counters(telemetry.ravenna_capture_zero) << '"'
              << ",\"zero_usb_playback\":\"" << format_zero_counters(telemetry.usb_playback_zero) << '"'
              << ",\"impulse_trace\":" << (options.impulse_trace ? 1 : 0)
              << ",\"impulse_channel\":" << options.impulse_trace_channel
              << ",\"impulse_threshold\":" << options.impulse_trace_threshold
              << ",\"impulse_holdoff\":" << options.impulse_trace_holdoff
              << ",\"impulse_usb_capture\":" << tx.capture_impulse.events()
              << ",\"impulse_ravenna_playback\":" << tx.playback_impulse.events()
              << ",\"impulse_ravenna_capture\":" << rx.capture_impulse.events()
              << ",\"impulse_usb_playback\":" << rx.playback_impulse.events()
              << ",\"impulse_lines\":" << tx.impulse_lines + rx.impulse_lines
              << ",\"impulse_lines_suppressed\":" << tx.impulse_lines_suppressed + rx.impulse_lines_suppressed
              << ",\"impulse_dropped_events\":"
              << tx.capture_impulse.dropped_events() + tx.playback_impulse.dropped_events() +
                 rx.capture_impulse.dropped_events() + rx.playback_impulse.dropped_events()
              << ",\"zero_run_lines\":" << tx.zero_run_lines + rx.zero_run_lines
              << ",\"zero_run_lines_suppressed\":" << tx.zero_run_lines_suppressed + rx.zero_run_lines_suppressed
              << ",\"zero_run_dropped_events\":"
              << tx.capture_zero.dropped_events() + tx.playback_zero.dropped_events() +
                 rx.capture_zero.dropped_events() + rx.playback_zero.dropped_events() << "}\n";
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
