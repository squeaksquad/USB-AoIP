#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <stdexcept>
#include <vector>

namespace usb16x16 {

constexpr std::size_t kChannels = 16;
constexpr double kNominalRate = 48000.0;

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

[[nodiscard]] std::int32_t unpack_s24le(const std::uint8_t* source) noexcept;
void pack_s24le(std::int32_t sample, std::uint8_t* destination) noexcept;
[[nodiscard]] float s24_to_float(const std::uint8_t* source) noexcept;
void float_to_s24(float sample, std::uint8_t* destination) noexcept;
[[nodiscard]] float s32_to_float(std::int32_t sample) noexcept;
[[nodiscard]] std::int32_t float_to_s32(float sample) noexcept;
// True when float_to_s24 / float_to_s32 will clamp this sample.
[[nodiscard]] bool exceeds_full_scale(float sample) noexcept;

} // namespace usb16x16
