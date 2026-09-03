#include "usb16x16/bridge_core.hpp"

#include <cstring>

namespace usb16x16 {

AudioRing::AudioRing(const std::size_t capacity_frames)
    : samples_(capacity_frames * kChannels, 0.0F), capacity_frames_(capacity_frames) {
    if (capacity_frames < 8) {
        throw std::invalid_argument("audio ring capacity must be at least 8 frames");
    }
}

void AudioRing::clear() noexcept {
    read_frame_ = 0;
    size_frames_ = 0;
}

bool AudioRing::push(const float* interleaved, const std::size_t frames) noexcept {
    if (frames > free()) {
        return false;
    }
    for (std::size_t frame = 0; frame < frames; ++frame) {
        const std::size_t destination_frame = (read_frame_ + size_frames_ + frame) % capacity_frames_;
        std::memcpy(samples_.data() + destination_frame * kChannels,
                    interleaved + frame * kChannels,
                    kChannels * sizeof(float));
    }
    size_frames_ += frames;
    return true;
}

void AudioRing::pop(const std::size_t frames) noexcept {
    const std::size_t actual = std::min(frames, size_frames_);
    read_frame_ = (read_frame_ + actual) % capacity_frames_;
    size_frames_ -= actual;
}

float AudioRing::sample(const std::size_t frame, const std::size_t channel) const noexcept {
    if (frame >= size_frames_ || channel >= kChannels) {
        return 0.0F;
    }
    const std::size_t physical_frame = (read_frame_ + frame) % capacity_frames_;
    return samples_[physical_frame * kChannels + channel];
}

std::size_t FarrowResampler::render(AudioRing& source,
                                    float* output,
                                    const std::size_t output_capacity_frames,
                                    const double source_step) noexcept {
    if (!(source_step >= 0.999 && source_step <= 1.001)) {
        return 0;
    }

    std::size_t produced = 0;
    while (produced < output_capacity_frames) {
        const auto center = static_cast<std::size_t>(position_);
        if (center < 1 || center + 2 >= source.size()) {
            break;
        }
        const float fraction = static_cast<float>(position_ - static_cast<double>(center));
        for (std::size_t channel = 0; channel < kChannels; ++channel) {
            const float y0 = source.sample(center - 1, channel);
            const float y1 = source.sample(center, channel);
            const float y2 = source.sample(center + 1, channel);
            const float y3 = source.sample(center + 2, channel);

            // Cubic Farrow form (Catmull-Rom). It has two frames of lookahead
            // and no coefficient-table lookup on the real-time path.
            const float a0 = -0.5F * y0 + 1.5F * y1 - 1.5F * y2 + 0.5F * y3;
            const float a1 = y0 - 2.5F * y1 + 2.0F * y2 - 0.5F * y3;
            const float a2 = -0.5F * y0 + 0.5F * y2;
            output[produced * kChannels + channel] = ((a0 * fraction + a1) * fraction + a2) * fraction + y1;
        }
        ++produced;
        position_ += source_step;
    }

    if (position_ >= 2.0) {
        const std::size_t consumed = static_cast<std::size_t>(position_) - 1;
        source.pop(consumed);
        position_ -= static_cast<double>(consumed);
        consumed_frames_ += consumed;
    }
    return produced;
}

void LevelServo::set_setpoint(const double frames) noexcept {
    setpoint_ = frames;
    have_setpoint_ = true;
    bias_ = 0.0;
}

double LevelServo::update(const double depth_frames) noexcept {
    if (!have_setpoint_ || !std::isfinite(depth_frames)) {
        bias_ = 0.0;
        return bias_;
    }
    const double error = depth_frames - setpoint_;
    const double clamp = std::abs(error) > config_.wide_error_frames
        ? config_.wide_clamp_ppm
        : config_.clamp_ppm;
    bias_ = std::clamp(config_.gain_ppm_per_frame * error, -clamp, clamp);
    return bias_;
}

std::int64_t median_wake_interval(const std::vector<std::int64_t>& wake_times) noexcept {
    if (wake_times.size() < 2) {
        return 0;
    }
    std::vector<std::int64_t> intervals;
    intervals.reserve(wake_times.size() - 1);
    for (std::size_t index = 1; index < wake_times.size(); ++index) {
        intervals.push_back(wake_times[index] - wake_times[index - 1]);
    }
    std::sort(intervals.begin(), intervals.end());
    const std::size_t middle = intervals.size() / 2;
    if (intervals.size() % 2 == 1) {
        return intervals[middle];
    }
    return (intervals[middle - 1] + intervals[middle]) / 2;
}

std::int64_t next_aligned_time(const std::int64_t reference,
                               const std::int64_t period,
                               const std::int64_t not_before) noexcept {
    if (period <= 0 || not_before <= reference) {
        return reference;
    }
    const std::int64_t elapsed = not_before - reference;
    const std::int64_t periods = (elapsed + period - 1) / period;
    return reference + periods * period;
}

SharedDriftEstimator::SharedDriftEstimator() : SharedDriftEstimator(Config{}) {}

SharedDriftEstimator::SharedDriftEstimator(const Config config) : config_(config) {}

void SharedDriftEstimator::reset(const double initial_ppm) noexcept {
    ppm_ = std::clamp(initial_ppm, -config_.maximum_ppm, config_.maximum_ppm);
    integral_ppm_ = ppm_;
    phase_error_ = 0.0;
    have_error_ = false;
    observed_ppm_ = ppm_;
    have_rate_observation_ = false;
}

void SharedDriftEstimator::update_rate_observation(const double observed_ppm) noexcept {
    if (!std::isfinite(observed_ppm)) {
        return;
    }
    const double bounded_observation =
        std::clamp(observed_ppm, -config_.maximum_ppm, config_.maximum_ppm);
    if (!have_rate_observation_) {
        observed_ppm_ = bounded_observation;
        have_rate_observation_ = true;
    } else {
        const double retain = std::clamp(config_.rate_smoothing, 0.0, 0.999999);
        observed_ppm_ = retain * observed_ppm_ + (1.0 - retain) * bounded_observation;
    }
    ppm_ += std::clamp(observed_ppm_ - ppm_,
                       -config_.maximum_slew_ppm,
                       config_.maximum_slew_ppm);
    ppm_ = std::clamp(ppm_, -config_.maximum_ppm, config_.maximum_ppm);
    integral_ppm_ = ppm_;
    phase_error_ = 0.0;
    have_error_ = false;
}

void SharedDriftEstimator::update_phase_error(const double differential_phase_error_frames) noexcept {
    if (!std::isfinite(differential_phase_error_frames)) {
        return;
    }
    if (!have_error_) {
        phase_error_ = differential_phase_error_frames;
        have_error_ = true;
    } else {
        const double retain = std::clamp(config_.smoothing, 0.0, 0.999999);
        phase_error_ = retain * phase_error_ +
                       (1.0 - retain) * differential_phase_error_frames;
    }

    integral_ppm_ += config_.integral_ppm_per_frame_update * phase_error_;
    integral_ppm_ = std::clamp(integral_ppm_, -config_.maximum_ppm, config_.maximum_ppm);
    const double requested = std::clamp(
        integral_ppm_ + config_.proportional_ppm_per_frame * phase_error_,
        -config_.maximum_ppm,
        config_.maximum_ppm);
    ppm_ += std::clamp(requested - ppm_, -config_.maximum_slew_ppm, config_.maximum_slew_ppm);
    ppm_ = std::clamp(ppm_, -config_.maximum_ppm, config_.maximum_ppm);
}

void WindowedLinearRegression::clear() noexcept {
    count_ = 0;
    next_ = 0;
}

void WindowedLinearRegression::add(const double independent, const double dependent) noexcept {
    if (!std::isfinite(independent) || !std::isfinite(dependent)) {
        return;
    }
    samples_[next_] = {independent, dependent};
    next_ = (next_ + 1) % samples_.size();
    count_ = std::min(count_ + 1, samples_.size());
}

bool WindowedLinearRegression::slope(double& result) const noexcept {
    if (count_ < 2) {
        return false;
    }
    double independent_mean = 0.0;
    double dependent_mean = 0.0;
    for (std::size_t index = 0; index < count_; ++index) {
        independent_mean += samples_[index].independent;
        dependent_mean += samples_[index].dependent;
    }
    independent_mean /= static_cast<double>(count_);
    dependent_mean /= static_cast<double>(count_);

    double numerator = 0.0;
    double denominator = 0.0;
    for (std::size_t index = 0; index < count_; ++index) {
        const double centered = samples_[index].independent - independent_mean;
        numerator += centered * (samples_[index].dependent - dependent_mean);
        denominator += centered * centered;
    }
    if (denominator <= std::numeric_limits<double>::epsilon()) {
        return false;
    }
    result = numerator / denominator;
    return std::isfinite(result);
}

std::int32_t unpack_s24le(const std::uint8_t* source) noexcept {
    std::uint32_t value = static_cast<std::uint32_t>(source[0]) |
                          (static_cast<std::uint32_t>(source[1]) << 8U) |
                          (static_cast<std::uint32_t>(source[2]) << 16U);
    if ((value & 0x00800000U) != 0U) {
        value |= 0xFF000000U;
    }
    return static_cast<std::int32_t>(value);
}

void pack_s24le(const std::int32_t sample, std::uint8_t* destination) noexcept {
    const std::int32_t clipped = std::clamp(sample, -8388608, 8388607);
    const auto value = static_cast<std::uint32_t>(clipped);
    destination[0] = static_cast<std::uint8_t>(value & 0xFFU);
    destination[1] = static_cast<std::uint8_t>((value >> 8U) & 0xFFU);
    destination[2] = static_cast<std::uint8_t>((value >> 16U) & 0xFFU);
}

float s24_to_float(const std::uint8_t* source) noexcept {
    return static_cast<float>(unpack_s24le(source)) / 8388608.0F;
}

// Both converters clamp in the integer domain, after rounding. The previous
// form clamped the float to nextafter(1.0, 0) and rounded afterwards, and
// that rounds back up to exactly +full scale: 8388607.5 -> 8388608 for S24
// and 2147483647.9999998 -> 2147483648 for S32. pack_s24le clamps its integer
// so the USB side survived, but the S32 cast wrapped to -2147483648, so every
// positive intersample overshoot the Farrow interpolator produced on hot
// material left the bridge as a negative full-scale sample on the AES67 wire.
// Measured 2026-09-02: audible crackle on 0 dBFS masters, gone at -3 dB.
void float_to_s24(const float sample, std::uint8_t* destination) noexcept {
    const double scaled = std::clamp(static_cast<double>(sample), -2.0, 2.0) * 8388608.0;
    const auto rounded = static_cast<std::int32_t>(std::lrint(scaled));
    pack_s24le(std::clamp(rounded, -8388608, 8388607), destination);
}

float s32_to_float(const std::int32_t sample) noexcept {
    return static_cast<float>(static_cast<double>(sample) / 2147483648.0);
}

std::int32_t float_to_s32(const float sample) noexcept {
    const double scaled = std::clamp(static_cast<double>(sample), -2.0, 2.0) * 2147483648.0;
    const auto rounded = std::llround(scaled);
    return static_cast<std::int32_t>(std::clamp<long long>(rounded, -2147483648LL, 2147483647LL));
}

bool exceeds_full_scale(const float sample) noexcept {
    // True when the integer converters will have to clamp: anything at or
    // above +1.0, or below -1.0. +1.0 itself is not representable in either
    // integer format, so it counts.
    return !(sample < 1.0F) || sample < -1.0F;
}

} // namespace usb16x16
