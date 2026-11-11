// The owner's clock discipline for one direction: a PI law from a buffer depth
// to a pitch offset in ppm for one of the gadget's pitch controls.
//
// The plant is an integrator. One ppm of rate difference between the host's
// USB clock and the Dante clock moves a depth by 0.048 frames a second, and the
// constant part of that difference (tens of ppm between two crystals) has to be
// cancelled exactly, which a proportional term cannot do: at 0.5 ppm per frame
// a 20 ppm offset would sit 40 frames off the setpoint for ever. The integral
// term carries the offset; the proportional term damps. With kp in ppm per
// frame and ki in ppm per frame-second the closed loop is
//   s^2 + 0.048 kp s + 0.048 ki = 0,
// critically damped at ki = 0.012 kp^2. The defaults (0.5, 0.003) give a time
// constant of about 83 s.
//
// The two directions are separate loops because each can run without the
// other (a host that only plays, or only records). They see the same two
// clocks with opposite sign, so a direction that starts while the other has
// settled is seeded with the other's integral, negated by the caller.
//
// No ALSA, no allocation: unit-tested on the Mac (servo_test.cpp).
#pragma once

#include <algorithm>
#include <cmath>

namespace usb16x16::owner {

class PitchPi {
public:
    struct Config {
        double kp_ppm_per_frame{0.5};
        double ki_ppm_per_frame_second{0.003};
        double maximum_ppm{250.0};
    };

    PitchPi() = default;
    explicit PitchPi(Config config) : config_(config) {}

    // Forget the error history; keep or replace the integral (the learned
    // clock offset survives a relink, which is the point of keeping it).
    void restart(double integral_ppm) noexcept {
        integral_ = std::clamp(integral_ppm, -config_.maximum_ppm, config_.maximum_ppm);
        output_ = integral_;
        updates_ = 0;
    }

    // error_frames: depth minus setpoint, averaged over the interval.
    // Returns the offset in ppm, positive when the depth is above the setpoint.
    double update(double error_frames, double interval_seconds) noexcept {
        const double proportional = config_.kp_ppm_per_frame * error_frames;
        const double unclamped = proportional + integral_ + config_.ki_ppm_per_frame_second * error_frames * interval_seconds;
        // Anti-windup: the integral only moves while the output is inside the range.
        if (std::abs(unclamped) < config_.maximum_ppm) {
            integral_ += config_.ki_ppm_per_frame_second * error_frames * interval_seconds;
        }
        output_ = std::clamp(proportional + integral_, -config_.maximum_ppm, config_.maximum_ppm);
        ++updates_;
        return output_;
    }

    [[nodiscard]] double output() const noexcept { return output_; }
    [[nodiscard]] double integral() const noexcept { return integral_; }
    [[nodiscard]] unsigned long updates() const noexcept { return updates_; }
    // Long enough in the loop for the integral to mean something to the other direction.
    [[nodiscard]] bool settled() const noexcept { return updates_ >= 300; }

private:
    Config config_{};
    double integral_{0.0};
    double output_{0.0};
    unsigned long updates_{0};
};

// One second of depth readings reduced to the figure a PitchPi is given.
//
// The gadget's playback pointer is reported late for a second or two about
// every sixteen seconds: the queue then reads 37 to 38 frames deeper than it
// is, with nothing in the audio (3,200 harness impulses across fifty episodes,
// none displaced; RESULTS.md 2026-10-09). Fed to the servo as it stands, each
// episode is a 35-frame error for a second. Two defences, both needed because
// an episode can cover part of a second or all of it:
//   - within the second, the mean is taken over the middle half of the sorted
//     readings, so up to a quarter of them can be wrong without moving it;
//   - across seconds, a figure that steps more than `step_frames` from the
//     last accepted one is held back, for at most `hold_seconds` in a row. A
//     depth that really moved is believed after that.
// Fixed storage, no allocation; add() is one store.
class DepthFilter {
public:
    static constexpr unsigned kCapacity = 2048;
    static constexpr unsigned kMinimumReadings = 200;

    explicit DepthFilter(double step_frames = 16.0, unsigned hold_seconds = 5) noexcept
        : step_frames_(step_frames), hold_seconds_(hold_seconds) {}

    void add(int depth_frames) noexcept {
        if (count_ < kCapacity) readings_[count_++] = depth_frames;
    }
    // Forget everything, including the last accepted figure: a new prime.
    void restart() noexcept {
        count_ = 0;
        have_accepted_ = false;
        held_ = 0;
    }
    // Close the second. True with `figure` set when the servo should be
    // updated; false when there were too few readings or the second is held
    // back as an artefact.
    bool finish(double& figure) noexcept {
        const unsigned count = count_;
        count_ = 0;
        if (count < kMinimumReadings) return false;
        std::sort(readings_, readings_ + count);
        const unsigned low = count / 4;
        const unsigned high = count - count / 4;
        double sum = 0.0;
        for (unsigned index = low; index < high; ++index) sum += readings_[index];
        const double middle = sum / static_cast<double>(high - low);
        last_figure_ = middle;
        if (have_accepted_ && std::abs(middle - accepted_) > step_frames_ && held_ < hold_seconds_) {
            ++held_;
            ++rejected_;
            return false;
        }
        held_ = 0;
        accepted_ = middle;
        have_accepted_ = true;
        figure = middle;
        return true;
    }
    // The last second's figure whether or not it was accepted, and how many were not.
    [[nodiscard]] double last_figure() const noexcept { return last_figure_; }
    [[nodiscard]] unsigned long rejected() const noexcept { return rejected_; }

private:
    int readings_[kCapacity]{};
    unsigned count_{0};
    double step_frames_;
    unsigned hold_seconds_;
    double accepted_{0.0};
    double last_figure_{0.0};
    bool have_accepted_{false};
    unsigned held_{0};
    unsigned long rejected_{0};
};

// The integer the gadget's pitch control takes for an offset in ppm.
// sign is -1 for Capture Pitch (a deep outgoing buffer wants the gadget to ask
// the host for less) and +1 for Playback Pitch (a deep return queue wants the
// gadget to report a faster clock so the host takes more).
[[nodiscard]] inline int pitch_value(double offset_ppm, int sign) noexcept {
    const long value = 1000000L + sign * std::lround(offset_ppm);
    return static_cast<int>(std::clamp(value, 1000000L - 250L, 1000000L + 250L));
}

}  // namespace usb16x16::owner
