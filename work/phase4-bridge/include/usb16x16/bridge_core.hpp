#pragma once

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

namespace usb16x16 {

constexpr std::size_t kChannels = 16;
constexpr double kNominalRate = 48000.0;

// The DSP stage: 16 capture channels through the compiled pipeline and back to
// 16 playback channels, in place, on the audio thread.
//
// It runs difference equations and nothing else. Every coefficient is computed
// by `work/dsp-compiler` from the same expressions the UI draws its curve with
// and the same Linkwitz-Riley cascade the engine was measured against, so the
// correctness of a filter here is the correctness of `process()` alone.
//
// Real-time contract. `load()` allocates and may throw; call it off the audio
// path. `process()` and `reset()` allocate nothing, lock nothing, throw
// nothing, and touch only storage sized at load. Arithmetic is double
// throughout, with float only at the buffer boundary: the bridge's samples are
// float, but a 40 Hz bell at Q 6 has poles close enough to the unit circle that
// single-precision coefficients would be measurably wrong, and doubles are also
// what the reference engine uses.
class DspStage {
public:
    // Generous: the worst case a preset can reach is one main branch per
    // distinct speaker source plus one bass branch per input, and outputs cap
    // the first at 16. Checked at load rather than assumed.
    static constexpr std::size_t kMaxInternalChannels = 48;
    // 10 ms at 48 kHz, the alignment-delay ceiling the preset model validates.
    static constexpr std::size_t kMaxDelaySamples = 480;

    struct Section {
        double b0{}, b1{}, b2{}, a1{}, a2{};
    };

    DspStage() = default;

    // Parse the artifact `usb16x16-dsp-compile --bridge` writes. Throws
    // std::runtime_error with the offending line on anything malformed;
    // a bridge that cannot load a preset must refuse it, not run half of one.
    static DspStage load(std::string_view text);

    [[nodiscard]] bool loaded() const noexcept { return internal_channels_ > 0; }
    [[nodiscard]] std::size_t internal_channels() const noexcept { return internal_channels_; }
    [[nodiscard]] const std::string& preset() const noexcept { return preset_; }
    // The transport cost of the alignment delays: the largest of them, because
    // the output is not complete until the most delayed channel is produced.
    [[nodiscard]] std::size_t delay_samples() const noexcept { return delay_samples_; }
    [[nodiscard]] std::size_t biquad_count() const noexcept { return sections_.size(); }

    void reset() noexcept;

    // 16 interleaved channels in, the same buffer out. Frames must not exceed
    // what the caller's scratch holds; nothing here depends on the block size.
    void process(float* interleaved, std::size_t frames) noexcept;

private:
    struct MixEntry {
        std::uint16_t dest{};
        std::uint16_t source{};
        double gain{};
    };
    struct Chain {
        std::uint16_t channel{};
        std::uint32_t first{};
        std::uint32_t count{};
    };
    struct OutputSpec {
        std::uint32_t first{};
        std::uint32_t count{};
        std::uint32_t delay{};
        double gain{1.0};
    };
    struct State {
        double x1{}, x2{}, y1{}, y2{};
    };

    void run_chain(std::uint32_t first, std::uint32_t count, double& sample) noexcept;
    void flush_denormals() noexcept;

    std::string preset_;
    std::size_t internal_channels_{};
    std::size_t delay_samples_{};
    std::vector<MixEntry> expand_;
    std::vector<MixEntry> assign_;
    std::vector<Chain> branches_;
    std::vector<Section> sections_;
    std::vector<State> states_;
    std::array<OutputSpec, kChannels> outputs_{};
    // One contiguous block, kMaxDelaySamples per output, so a delay line never
    // allocates and the whole stage is one cache-friendly region.
    std::vector<double> delay_lines_;
    std::array<std::uint32_t, kChannels> delay_write_{};
};

class AudioRing {
public:
    explicit AudioRing(std::size_t capacity_frames);

    [[nodiscard]] std::size_t capacity() const noexcept { return capacity_frames_; }
    [[nodiscard]] std::size_t size() const noexcept { return size_frames_; }
    [[nodiscard]] std::size_t free() const noexcept { return capacity_frames_ - size_frames_; }

    void clear() noexcept;
    bool push(const float* interleaved, std::size_t frames) noexcept;
    void pop(std::size_t frames) noexcept;
    [[nodiscard]] float sample(std::size_t frame, std::size_t channel) const noexcept;

private:
    std::vector<float> samples_;
    std::size_t capacity_frames_{};
    std::size_t read_frame_{};
    std::size_t size_frames_{};
};

class FarrowResampler {
public:
    // The interpolator reads source frames center-1 through center+2 with
    // center at least 1, so the ring must never be drawn below this.
    static constexpr std::size_t kLookaheadFrames = 8;

    void reset() noexcept { position_ = 1.0; }

    // source_step is input frames consumed per output frame. The four-point
    // cubic Farrow kernel is appropriate here because the rate remains within
    // a few hundred ppm of unity; it is not an arbitrary-ratio converter.
    std::size_t render(AudioRing& source,
                       float* output,
                       std::size_t output_capacity_frames,
                       double source_step) noexcept;

    [[nodiscard]] double fractional_position() const noexcept { return position_; }

    // Cumulative source frames actually popped. Divided by the frames produced
    // it gives the rate the converter really achieved, which is the only direct
    // way to confirm a direction is applying the ratio it was handed.
    [[nodiscard]] std::uint64_t consumed_frames() const noexcept { return consumed_frames_; }

private:
    double position_{1.0};
    std::uint64_t consumed_frames_{0};
};

class SharedDriftEstimator {
public:
    struct Config {
        double proportional_ppm_per_frame{1.0};
        double integral_ppm_per_frame_update{0.05};
        double maximum_ppm{250.0};
        double maximum_slew_ppm{2.0};
        double smoothing{0.8};
        double rate_smoothing{0.8};
    };

    SharedDriftEstimator();
    explicit SharedDriftEstimator(Config config);

    void reset(double initial_ppm = 0.0) noexcept;
    void update_phase_error(double differential_phase_error_frames) noexcept;
    void update_rate_observation(double observed_ppm) noexcept;

    // q = USB clock rate / RAVENNA clock rate. USB->RAVENNA consumes q USB
    // frames per RAVENNA output frame. RAVENNA->USB consumes 1/q RAVENNA
    // frames per USB output frame. There is deliberately no second estimator.
    [[nodiscard]] double clock_ratio() const noexcept { return 1.0 + ppm_ * 1.0e-6; }
    [[nodiscard]] double ppm() const noexcept { return ppm_; }
    [[nodiscard]] double phase_error() const noexcept { return phase_error_; }
    [[nodiscard]] double observed_ppm() const noexcept { return observed_ppm_; }

private:
    Config config_;
    double integral_ppm_{};
    double ppm_{};
    double phase_error_{};
    bool have_error_{};
    double observed_ppm_{};
    bool have_rate_observation_{};
};

// Per-direction level law for the split USB pitch servo. Proportional only:
// the plant (a depth fed by a rate difference) is already an integrator, so
// a proportional pitch offset gives a first-order return to the setpoint
// with no steady-state error. The pitch control steps in 1 ppm, so the gain
// must turn a few tens of frames into a whole ppm or the loop sits in a dead
// zone: 0.01 ppm/frame did exactly that (run 142307Z moved nothing in
// 600 s). At 0.05 ppm/frame, 20 frames is 1 ppm and the time constant is
// about 420 s per direction. A wider clamp applies while the error is large,
// which is the cold-boot case: 480 frames of excess drain in minutes rather
// than most of an hour.
class LevelServo {
public:
    struct Config {
        double gain_ppm_per_frame{0.05};
        double clamp_ppm{2.0};
        double wide_error_frames{192.0};
        double wide_clamp_ppm{8.0};
    };

    LevelServo() = default;
    explicit LevelServo(Config config) : config_(config) {}

    void set_setpoint(double frames) noexcept;
    [[nodiscard]] bool have_setpoint() const noexcept { return have_setpoint_; }
    [[nodiscard]] double setpoint() const noexcept { return setpoint_; }
    // Bias in ppm, positive when the depth sits above the setpoint. The
    // caller decides the sign it applies to its pitch control.
    double update(double depth_frames) noexcept;
    [[nodiscard]] double bias() const noexcept { return bias_; }
    [[nodiscard]] const Config& config() const noexcept { return config_; }

private:
    Config config_{};
    double setpoint_{};
    bool have_setpoint_{};
    double bias_{};
};

class WindowedLinearRegression {
public:
    static constexpr std::size_t kCapacity = 120;

    void clear() noexcept;
    void add(double independent, double dependent) noexcept;
    [[nodiscard]] std::size_t size() const noexcept { return count_; }
    [[nodiscard]] bool slope(double& result) const noexcept;

private:
    struct Sample {
        double independent{};
        double dependent{};
    };
    std::array<Sample, kCapacity> samples_{};
    std::size_t count_{};
    std::size_t next_{};
};

// The aligned start observes the RAVENNA driver's tick through capture
// period wakeups and needs the tick period from a handful of wake times.
// The median of the consecutive intervals ignores a short first interval
// (the wake that drains a backlog) and a late wake on the way; fewer than
// two wake times give 0. Even counts take the mean of the two middles.
[[nodiscard]] std::int64_t median_wake_interval(const std::vector<std::int64_t>& wake_times) noexcept;
// The first instant reference + n * period, n >= 0, that is not before
// not_before: where a recovery re-prepares the RAVENNA capture so it lands
// on the same tick phase the start alignment chose. period must be
// positive; a not_before at or before the reference returns the reference.
// Phase of one periodic grid against another: where `wake` falls inside the
// `tick`-long cycle that starts at `reference`, in [0, tick). Used for the
// RAVENNA tick grid (an RX capture fresh wake) against the host's USB frame
// grid (a USB capture fresh wake); the two drift at the crystal offset the
// pitch servo corrects, so the value slides through a full cycle over
// roughly a minute and the level a session starts at depends on it.
[[nodiscard]] inline std::int64_t grid_phase_ns(const std::int64_t wake,
                                                const std::int64_t reference,
                                                const std::int64_t tick) noexcept {
    if (tick <= 0) {
        return 0;
    }
    const std::int64_t remainder = (wake - reference) % tick;
    return remainder < 0 ? remainder + tick : remainder;
}

// True when `phase` lies inside [low, high]; a window with high < low wraps
// around the cycle end, so {900000, 100000} at a 1 ms tick covers the 200 us
// straddling the boundary.
[[nodiscard]] inline bool phase_in_window(const std::int64_t phase,
                                          const std::int64_t low,
                                          const std::int64_t high) noexcept {
    return low <= high ? (phase >= low && phase <= high) : (phase >= low || phase <= high);
}

[[nodiscard]] std::int64_t next_aligned_time(std::int64_t reference,
                                             std::int64_t period,
                                             std::int64_t not_before) noexcept;

// Zero-run detector, the instrument for the exactly-41-sample holes of
// 2026-09-04. Per channel it counts consecutive frames whose sample is
// exactly zero and, when the run ends, reports it if its length lies in
// [minimum, maximum]; channels whose runs share a start and a length are
// coalesced into one event with a channel mask, so an all-channel hole is
// one event with mask 0xffff. A channel that is silent (a run that never
// ends, or one longer than the maximum, which is a real gap in the
// material and counted as such) produces no event, so undriven channels
// cost nothing. Placed at the four points where audio enters or leaves the
// bridge, it names the stage where zeros first appear. Real-time safe:
// fixed storage, no allocation after construction, one compare per sample.
class ZeroRunDetector {
public:
    struct Config {
        std::size_t minimum_frames{8};
        std::size_t maximum_frames{480};
    };
    struct Event {
        std::uint64_t start_frame{};
        std::size_t length{};
        std::uint32_t channel_mask{};
    };
    static constexpr std::size_t kEventCapacity = 8;

    ZeroRunDetector() = default;
    explicit ZeroRunDetector(Config config) : config_(config) {}

    // Forget every open run without reporting it: a direction restart.
    void reset() noexcept;
    // first_frame_position is the stream position of frame 0 of this block,
    // monotonic across calls; a run may span any number of calls.
    void observe(const float* interleaved, std::size_t frames, std::uint64_t first_frame_position) noexcept;
    bool pop_event(Event& event) noexcept;

    [[nodiscard]] const Config& config() const noexcept { return config_; }
    // Events reported, including any the queue could not hold.
    [[nodiscard]] std::uint64_t events() const noexcept { return events_; }
    // Frames inside reported events (one count per event, not per channel).
    [[nodiscard]] std::uint64_t zero_frames() const noexcept { return zero_frames_; }
    [[nodiscard]] std::size_t longest() const noexcept { return longest_; }
    // Per-channel runs that exceeded the maximum: silence, not holes.
    [[nodiscard]] std::uint64_t long_runs() const noexcept { return long_runs_; }
    [[nodiscard]] std::uint64_t dropped_events() const noexcept { return dropped_events_; }

private:
    void end_run(std::size_t channel) noexcept;
    void enqueue(const Event& event) noexcept;

    Config config_{};
    std::array<std::uint64_t, kChannels> run_start_{};
    std::array<std::size_t, kChannels> run_length_{};
    std::array<Event, kChannels> pending_{};
    std::size_t pending_count_{};
    std::array<Event, kEventCapacity> events_queue_{};
    std::size_t queue_head_{};
    std::size_t queue_count_{};
    std::uint64_t events_{};
    std::uint64_t zero_frames_{};
    std::size_t longest_{};
    std::uint64_t long_runs_{};
    std::uint64_t dropped_events_{};
};

// Impulse trace (2026-09-06): on one channel, report the stream position
// of the first sample whose magnitude exceeds a threshold, then hold off
// for a fixed number of frames so one impulse (and anything it rings into)
// is one event. Placed at the four points where audio enters or leaves the
// bridge, it stamps the harness impulse at each stage, which splits the
// device-timeline round trip into the bridge's two dwells, the AES67 loop
// between them, and by subtraction the two USB legs. Real-time safe: fixed
// storage, no allocation after construction, one compare per frame.
class ImpulseTraceDetector {
public:
    struct Config {
        std::size_t channel{0};
        float threshold{0.1F};
        std::uint64_t holdoff_frames{2400};
    };
    struct Event {
        std::uint64_t position{};
        float value{};
    };
    static constexpr std::size_t kEventCapacity = 8;

    ImpulseTraceDetector() = default;
    explicit ImpulseTraceDetector(Config config) : config_(config) {}

    // Forget the hold-off: a direction restart.
    void reset() noexcept;
    // first_frame_position is the stream position of frame 0 of this block,
    // monotonic across calls.
    void observe(const float* interleaved, std::size_t frames, std::uint64_t first_frame_position) noexcept;
    bool pop_event(Event& event) noexcept;

    [[nodiscard]] const Config& config() const noexcept { return config_; }
    [[nodiscard]] std::uint64_t events() const noexcept { return events_; }
    [[nodiscard]] std::uint64_t dropped_events() const noexcept { return dropped_events_; }
    // Events waiting to be popped: lets the caller pay for an exact depth
    // query only on the blocks that carry a hit.
    [[nodiscard]] std::size_t pending() const noexcept { return queue_count_; }

private:
    Config config_{};
    // Position from which detection is armed again; 0 means armed.
    std::uint64_t armed_at_{0};
    std::array<Event, kEventCapacity> events_queue_{};
    std::size_t queue_head_{};
    std::size_t queue_count_{};
    std::uint64_t events_{};
    std::uint64_t dropped_events_{};
};

// Level meter tap (2026-09-11): per-channel peak, sum of squares and
// full-scale count over a window of frames, taken from a block already in
// hand at each of the four points where audio enters or leaves the bridge.
// It reads the buffer and writes nothing into it. The window closes on the
// first block boundary at or past window_frames, so a window is between
// window_frames and window_frames plus one block long and carries its own
// frame count; RMS is sum_squares / frames. The clip counts are cumulative
// since construction so a client that polls slower than a window still sees
// every full-scale sample; the peaks are per window, which is why a reader
// that wants to hold them must read at least once per window.
//
// Real-time contract. observe() runs on the audio thread: fixed storage, no
// allocation, no lock, no syscall, one pass over the block. The finished
// window is published through a seqlock: the writer bumps a sequence to odd,
// copies the window in, bumps it to even; a reader copies the snapshot out
// and keeps it only when the sequence was even and unchanged across the copy.
// The writer never waits for a reader; a reader that keeps losing the race
// (it cannot, at one write per 50 ms) gives up after a bounded number of
// tries and reports no snapshot.
class LevelMeter {
public:
    struct Snapshot {
        // Windows published so far; 0 until the first one closes.
        std::uint64_t sequence{};
        // Stream frames observed at the end of this window.
        std::uint64_t position{};
        // Frames in this window.
        std::uint32_t frames{};
        // Largest |sample| in the window, per channel.
        std::array<float, kChannels> peak{};
        // Sum of sample squares over the window, per channel.
        std::array<double, kChannels> sum_squares{};
        // Samples the integer converters would clamp, per channel, since construction.
        std::array<std::uint64_t, kChannels> clipped{};
    };
    static constexpr std::size_t kDefaultWindowFrames = 2400;  // 50 ms at 48 kHz

    LevelMeter() = default;
    explicit LevelMeter(std::size_t window_frames) noexcept;

    void observe(const float* interleaved, std::size_t frames) noexcept;
    // Copies the last published window. False until one has been published
    // or when a consistent copy could not be taken.
    [[nodiscard]] bool read(Snapshot& out) const noexcept;
    [[nodiscard]] std::size_t window_frames() const noexcept { return window_frames_; }
    // Windows published; the same figure a reader sees in Snapshot::sequence.
    [[nodiscard]] std::uint64_t sequence() const noexcept { return published_sequence_.load(std::memory_order_relaxed) / 2; }

private:
    void publish() noexcept;

    std::size_t window_frames_{kDefaultWindowFrames};
    // The open window, writer-private.
    Snapshot open_{};
    // The published window and its seqlock word: odd while the writer is
    // copying, and twice the number of windows published otherwise.
    Snapshot published_{};
    std::atomic<std::uint64_t> published_sequence_{0};
};

// 20 log10 of an amplitude in dBFS, floored so silence prints a number.
[[nodiscard]] inline double amplitude_to_dbfs(const double amplitude, const double floor_db = -144.0) noexcept {
    if (!(amplitude > 0.0)) {
        return floor_db;
    }
    return std::max(floor_db, 20.0 * std::log10(amplitude));
}

[[nodiscard]] std::int32_t unpack_s24le(const std::uint8_t* source) noexcept;
void pack_s24le(std::int32_t sample, std::uint8_t* destination) noexcept;
[[nodiscard]] float s24_to_float(const std::uint8_t* source) noexcept;
void float_to_s24(float sample, std::uint8_t* destination) noexcept;
[[nodiscard]] float s32_to_float(std::int32_t sample) noexcept;
[[nodiscard]] std::int32_t float_to_s32(float sample) noexcept;
// True when float_to_s24 / float_to_s32 will clamp this sample.
[[nodiscard]] bool exceeds_full_scale(float sample) noexcept;

} // namespace usb16x16
