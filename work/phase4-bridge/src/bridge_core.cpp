#include "usb16x16/bridge_core.hpp"

#include <sstream>

#include <cstring>

namespace usb16x16 {

namespace {

// Load-time parsing only. Throws on anything it does not understand: a preset
// the bridge cannot read in full is a preset it must refuse, because half a
// pipeline is a routing error with the gain still applied.
class ArtifactReader {
public:
    explicit ArtifactReader(const std::string_view text) : stream_(std::string(text)) {}

    std::string word(const char* what) {
        std::string value;
        if (!(stream_ >> value)) {
            throw std::runtime_error(std::string("dsp artifact: expected ") + what);
        }
        return value;
    }

    void expect(const char* keyword) {
        const std::string value = word(keyword);
        if (value != keyword) {
            throw std::runtime_error(std::string("dsp artifact: expected '") + keyword +
                                     "', found '" + value + "'");
        }
    }

    std::string rest_of_line() {
        std::string line;
        std::getline(stream_, line);
        const auto first = line.find_first_not_of(" \t");
        return first == std::string::npos ? std::string{} : line.substr(first);
    }

    std::size_t count(const char* what, const std::size_t limit) {
        const std::string value = word(what);
        try {
            const auto parsed = std::stoull(value);
            if (parsed > limit) {
                throw std::runtime_error(std::string("dsp artifact: ") + what + " " + value +
                                         " exceeds the limit " + std::to_string(limit));
            }
            return static_cast<std::size_t>(parsed);
        } catch (const std::invalid_argument&) {
            throw std::runtime_error(std::string("dsp artifact: ") + what +
                                     " is not a number: '" + value + "'");
        } catch (const std::out_of_range&) {
            throw std::runtime_error(std::string("dsp artifact: ") + what + " out of range");
        }
    }

    double real(const char* what) {
        const std::string value = word(what);
        try {
            const double parsed = std::stod(value);
            if (!std::isfinite(parsed)) {
                throw std::runtime_error(std::string("dsp artifact: ") + what +
                                         " is not finite: '" + value + "'");
            }
            return parsed;
        } catch (const std::invalid_argument&) {
            throw std::runtime_error(std::string("dsp artifact: ") + what +
                                     " is not a number: '" + value + "'");
        } catch (const std::out_of_range&) {
            throw std::runtime_error(std::string("dsp artifact: ") + what + " out of range");
        }
    }

private:
    std::istringstream stream_;
};

}  // namespace

DspStage DspStage::load(const std::string_view text) {
    ArtifactReader reader(text);
    reader.expect("usb16x16-dsp");
    const std::size_t version = reader.count("version", 1);
    if (version != 1) {
        throw std::runtime_error("dsp artifact: unsupported version " + std::to_string(version));
    }
    DspStage stage;
    reader.expect("preset");
    stage.preset_ = reader.rest_of_line();
    reader.expect("rate");
    const std::size_t rate = reader.count("rate", 768000);
    if (static_cast<double>(rate) != kNominalRate) {
        throw std::runtime_error("dsp artifact: rate " + std::to_string(rate) +
                                 " is not the bridge's 48000");
    }
    reader.expect("channels");
    const std::size_t channels = reader.count("channels", kChannels);
    if (channels != kChannels) {
        throw std::runtime_error("dsp artifact: " + std::to_string(channels) +
                                 " channels, the bridge carries " + std::to_string(kChannels));
    }
    reader.expect("internal");
    stage.internal_channels_ = reader.count("internal", kMaxInternalChannels);
    if (stage.internal_channels_ == 0) {
        throw std::runtime_error("dsp artifact: a pipeline with no internal channels routes nothing");
    }
    reader.expect("maxdelay");
    const std::size_t declared_delay = reader.count("maxdelay", kMaxDelaySamples);

    const auto read_mix = [&reader](std::vector<MixEntry>& into, const char* what,
                                    const std::size_t destinations, const std::size_t sources) {
        reader.expect(what);
        const std::size_t rows = reader.count(what, destinations * sources + 1);
        into.reserve(rows);
        for (std::size_t row = 0; row < rows; ++row) {
            const std::size_t dest = reader.count("mix destination", destinations - 1);
            const std::size_t source = reader.count("mix source", sources - 1);
            const double gain = reader.real("mix gain");
            into.push_back({static_cast<std::uint16_t>(dest),
                            static_cast<std::uint16_t>(source), gain});
        }
    };

    const auto read_sections = [&reader](std::vector<Section>& into, const std::size_t count) {
        for (std::size_t index = 0; index < count; ++index) {
            Section section;
            section.b0 = reader.real("b0");
            section.b1 = reader.real("b1");
            section.b2 = reader.real("b2");
            section.a1 = reader.real("a1");
            section.a2 = reader.real("a2");
            into.push_back(section);
        }
    };

    read_mix(stage.expand_, "expand", stage.internal_channels_, kChannels);

    reader.expect("branch");
    const std::size_t branch_rows = reader.count("branch", kMaxInternalChannels);
    stage.branches_.reserve(branch_rows);
    for (std::size_t row = 0; row < branch_rows; ++row) {
        const std::size_t channel = reader.count("branch channel", stage.internal_channels_ - 1);
        const std::size_t count = reader.count("branch sections", 64);
        Chain chain{static_cast<std::uint16_t>(channel),
                    static_cast<std::uint32_t>(stage.sections_.size()),
                    static_cast<std::uint32_t>(count)};
        read_sections(stage.sections_, count);
        stage.branches_.push_back(chain);
    }

    read_mix(stage.assign_, "assign", kChannels, stage.internal_channels_);

    reader.expect("output");
    const std::size_t output_rows = reader.count("output", kChannels);
    for (std::size_t row = 0; row < output_rows; ++row) {
        const std::size_t output = reader.count("output index", kChannels - 1);
        const std::size_t delay = reader.count("output delay", declared_delay);
        const double gain = reader.real("output gain");
        const std::size_t count = reader.count("output sections", 64);
        OutputSpec spec;
        spec.first = static_cast<std::uint32_t>(stage.sections_.size());
        spec.count = static_cast<std::uint32_t>(count);
        spec.delay = static_cast<std::uint32_t>(delay);
        spec.gain = gain;
        read_sections(stage.sections_, count);
        stage.outputs_[output] = spec;
        stage.delay_samples_ = std::max(stage.delay_samples_, delay);
    }
    reader.expect("end");

    stage.states_.assign(stage.sections_.size(), State{});
    stage.delay_lines_.assign(kChannels * kMaxDelaySamples, 0.0);
    stage.delay_write_.fill(0);
    return stage;
}

void DspStage::reset() noexcept {
    for (auto& state : states_) {
        state = State{};
    }
    std::fill(delay_lines_.begin(), delay_lines_.end(), 0.0);
    delay_write_.fill(0);
}

void DspStage::run_chain(const std::uint32_t first, const std::uint32_t count,
                         double& sample) noexcept {
    for (std::uint32_t index = 0; index < count; ++index) {
        const Section& section = sections_[first + index];
        State& state = states_[first + index];
        // Direct form I, the form the emitted coefficients are written for.
        const double input = sample;
        const double output = section.b0 * input + section.b1 * state.x1 +
                              section.b2 * state.x2 - section.a1 * state.y1 -
                              section.a2 * state.y2;
        state.x2 = state.x1;
        state.x1 = input;
        state.y2 = state.y1;
        state.y1 = output;
        sample = output;
    }
}

void DspStage::flush_denormals() noexcept {
    // Once per block, not per sample. A decaying IIR in double precision takes
    // a very long time to reach the denormal range, but a silent input holds it
    // there once it arrives, and on hardware that traps denormals the cost is
    // paid on every sample from then on. Cheap insurance at this rate.
    constexpr double floor = 1e-100;
    for (auto& state : states_) {
        if (std::abs(state.x1) < floor) state.x1 = 0.0;
        if (std::abs(state.x2) < floor) state.x2 = 0.0;
        if (std::abs(state.y1) < floor) state.y1 = 0.0;
        if (std::abs(state.y2) < floor) state.y2 = 0.0;
    }
}

void DspStage::process(float* const interleaved, const std::size_t frames) noexcept {
    if (internal_channels_ == 0) {
        return;
    }
    std::array<double, kMaxInternalChannels> internal{};
    std::array<double, kChannels> in{};
    std::array<double, kChannels> out{};
    for (std::size_t frame = 0; frame < frames; ++frame) {
        float* const block = interleaved + frame * kChannels;
        for (std::size_t channel = 0; channel < kChannels; ++channel) {
            in[channel] = static_cast<double>(block[channel]);
        }
        std::fill(internal.begin(), internal.begin() + internal_channels_, 0.0);
        for (const MixEntry& entry : expand_) {
            internal[entry.dest] += entry.gain * in[entry.source];
        }
        for (const Chain& chain : branches_) {
            run_chain(chain.first, chain.count, internal[chain.channel]);
        }
        out.fill(0.0);
        for (const MixEntry& entry : assign_) {
            out[entry.dest] += entry.gain * internal[entry.source];
        }
        for (std::size_t channel = 0; channel < kChannels; ++channel) {
            const OutputSpec& spec = outputs_[channel];
            double sample = out[channel];
            run_chain(spec.first, spec.count, sample);
            if (spec.delay > 0) {
                double* const line = delay_lines_.data() + channel * kMaxDelaySamples;
                const std::uint32_t write = delay_write_[channel];
                const double delayed = line[write];
                line[write] = sample;
                delay_write_[channel] = (write + 1) % spec.delay;
                sample = delayed;
            }
            block[channel] = static_cast<float>(sample * spec.gain);
        }
    }
    flush_denormals();
}

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

void ZeroRunDetector::reset() noexcept {
    run_length_.fill(0);
    run_start_.fill(0);
    pending_count_ = 0;
}

void ZeroRunDetector::end_run(const std::size_t channel) noexcept {
    const std::size_t length = run_length_[channel];
    if (length > config_.maximum_frames) {
        ++long_runs_;
        return;
    }
    if (length < config_.minimum_frames) {
        return;
    }
    const auto bit = static_cast<std::uint32_t>(1U << channel);
    for (std::size_t index = 0; index < pending_count_; ++index) {
        Event& pending = pending_[index];
        if (pending.start_frame == run_start_[channel] && pending.length == length) {
            pending.channel_mask |= bit;
            return;
        }
    }
    // pending_ has one slot per channel, so this never overflows.
    pending_[pending_count_++] = Event{run_start_[channel], length, bit};
}

void ZeroRunDetector::enqueue(const Event& event) noexcept {
    ++events_;
    zero_frames_ += event.length;
    longest_ = std::max(longest_, event.length);
    if (queue_count_ == kEventCapacity) {
        ++dropped_events_;
        return;
    }
    events_queue_[(queue_head_ + queue_count_) % kEventCapacity] = event;
    ++queue_count_;
}

void ZeroRunDetector::observe(const float* interleaved,
                              const std::size_t frames,
                              const std::uint64_t first_frame_position) noexcept {
    for (std::size_t frame = 0; frame < frames; ++frame) {
        const std::uint64_t position = first_frame_position + frame;
        const float* samples = interleaved + frame * kChannels;
        pending_count_ = 0;
        for (std::size_t channel = 0; channel < kChannels; ++channel) {
            if (samples[channel] == 0.0F) {
                if (run_length_[channel] == 0) {
                    run_start_[channel] = position;
                }
                ++run_length_[channel];
            } else if (run_length_[channel] != 0) {
                end_run(channel);
                run_length_[channel] = 0;
            }
        }
        // Runs that ended on this frame with the same start and length are
        // one event; different lengths are separate events.
        for (std::size_t index = 0; index < pending_count_; ++index) {
            enqueue(pending_[index]);
        }
        pending_count_ = 0;
    }
}

bool ZeroRunDetector::pop_event(Event& event) noexcept {
    if (queue_count_ == 0) {
        return false;
    }
    event = events_queue_[queue_head_];
    queue_head_ = (queue_head_ + 1) % kEventCapacity;
    --queue_count_;
    return true;
}

void ImpulseTraceDetector::reset() noexcept {
    armed_at_ = 0;
}

void ImpulseTraceDetector::observe(const float* interleaved,
                                   const std::size_t frames,
                                   const std::uint64_t first_frame_position) noexcept {
    if (config_.channel >= kChannels) {
        return;
    }
    const float* sample = interleaved + config_.channel;
    for (std::size_t frame = 0; frame < frames; ++frame, sample += kChannels) {
        const std::uint64_t position = first_frame_position + frame;
        if (position < armed_at_) {
            continue;
        }
        const float value = *sample;
        if (value > config_.threshold || value < -config_.threshold) {
            armed_at_ = position + config_.holdoff_frames;
            ++events_;
            if (queue_count_ == kEventCapacity) {
                ++dropped_events_;
                continue;
            }
            events_queue_[(queue_head_ + queue_count_) % kEventCapacity] = Event{position, value};
            ++queue_count_;
        }
    }
}

bool ImpulseTraceDetector::pop_event(Event& event) noexcept {
    if (queue_count_ == 0) {
        return false;
    }
    event = events_queue_[queue_head_];
    queue_head_ = (queue_head_ + 1) % kEventCapacity;
    --queue_count_;
    return true;
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
