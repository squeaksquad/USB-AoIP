// The owner's DSP stage on the outgoing direction (gadget capture to Dante).
//
// The owner carries samples as 24 bits in the top of an S32 and, without a
// preset, never converts them. With one, each block the outgoing direction is
// about to hand to Inferno goes S32 -> float -> DspStage -> 24-bit -> S32 here,
// with the bridge core's converters: s32_to_float is exact for a 24-bit value,
// and float_to_s24 rounds to nearest and saturates, which is what the bridge's
// 0 dBFS behaviour was proven with. The low byte is zero on the way out as it
// was on the way in.
//
// No ALSA here, so dsp_path_test.cpp builds and runs on the Mac.
//
// Real-time contract, as DspStage's: load() off the audio path, before the
// loop; process() and reset() allocate nothing, lock nothing, throw nothing.
//
// The monitor block (MonitorGains, phase 3) runs after the stage, on the same
// floats: per-output ramped gains for volume, dim, mute and solo. At its
// default (every gain 1, nothing ramping) it does not touch the block, so an
// owner that never publishes to it is bit-identical to one without it. It
// runs only when a preset is loaded, since without one the owner never
// converts the block to float. Its targets come from monitor_ctl.hpp, and a
// prime starts it from silence (prime_monitor) when the preset has a monitor
// section.
#pragma once

#include "usb16x16/bridge_core.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <string_view>
#include <utility>

namespace usb16x16::owner {

class OutDsp {
public:
    // The owner's scratch: no block is longer.
    static constexpr std::size_t kMaxFrames = 1024;

    // Throws what DspStage::load throws, which includes an artifact compiled
    // for a rate other than `rate`, the owner's --rate. Before the loop only.
    void load(std::string_view artifact, unsigned rate = 48000) { stage_ = DspStage::load(artifact, rate); }

    [[nodiscard]] bool enabled() const noexcept { return stage_.loaded(); }
    [[nodiscard]] DspStage& stage() noexcept { return stage_; }
    [[nodiscard]] const DspStage& stage() const noexcept { return stage_; }
    [[nodiscard]] MonitorGains& monitor() noexcept { return monitor_; }
    [[nodiscard]] const MonitorGains& monitor() const noexcept { return monitor_; }

    // Filter state and delay lines to silence: at each prime, so a start never
    // carries the tail of whatever was playing before the gap.
    void reset() noexcept { stage_.reset(); }

    // At a prime, with a preset that has a monitor section (and only then):
    // take the monitor's published targets, then start every output from
    // silence ramping to them over `frames`, so a start or re-prime rises
    // from zero to the monitor's current gains and never plays a block at
    // MonitorGains' default unity first. Without the section it does
    // nothing at all: such an artifact keeps today's behaviour exactly, with
    // no fade-in. Loop thread (or before the loop); no allocation.
    void prime_monitor(std::uint32_t frames) noexcept {
        if (!stage_.has_monitor()) return;
        monitor_.process(float_.data(), 0);
        monitor_.start_from_silence(frames);
    }

    // Take a published coefficient set, and the monitor's published targets,
    // without filtering anything: for the wakes on which no block goes out, so
    // a live update is not left waiting for audio (dsp_live.hpp). As cheap as
    // the atomic loads it is.
    void take() noexcept {
        stage_.process(float_.data(), 0);
        monitor_.process(float_.data(), 0);
    }

    // `frames` of 16 interleaved channels, in place. Does nothing unloaded.
    void process(std::int32_t* interleaved, std::size_t frames) noexcept {
        if (!ready(frames)) return;
        to_float(interleaved, frames);
        filter(frames);
        monitor_gains(frames);
        from_float(interleaved, frames);
    }

    // process() in its steps, for a caller that meters the floats between
    // them (meter_tap.hpp) and times the steps apart. Only when ready(frames)
    // is true. A caller that leaves out monitor_gains has no monitor block,
    // which is what the point-of-record owner is.
    [[nodiscard]] bool ready(std::size_t frames) const noexcept {
        return stage_.loaded() && frames != 0 && frames <= kMaxFrames;
    }
    void to_float(const std::int32_t* interleaved, std::size_t frames) noexcept {
        const std::size_t samples = frames * kChannels;
        for (std::size_t i = 0; i < samples; ++i) float_[i] = s32_to_float(interleaved[i]);
    }
    void filter(std::size_t frames) noexcept { stage_.process(float_.data(), frames); }
    void monitor_gains(std::size_t frames) noexcept { monitor_.process(float_.data(), frames); }
    void from_float(std::int32_t* interleaved, std::size_t frames) noexcept {
        const std::size_t samples = frames * kChannels;
        for (std::size_t i = 0; i < samples; ++i) {
            std::uint8_t packed[3];
            float_to_s24(float_[i], packed);
            interleaved[i] = static_cast<std::int32_t>((static_cast<std::uint32_t>(packed[0]) << 8) |
                                                       (static_cast<std::uint32_t>(packed[1]) << 16) |
                                                       (static_cast<std::uint32_t>(packed[2]) << 24));
        }
    }
    // The block between the steps: the input after to_float, the output after
    // filter (the monitor-in tap, pre-fader) and then after monitor_gains.
    [[nodiscard]] const float* floats() const noexcept { return float_.data(); }

private:
    DspStage stage_;
    MonitorGains monitor_;
    std::array<float, kMaxFrames * kChannels> float_{};
};

}  // namespace usb16x16::owner
