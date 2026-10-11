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

    // Throws what DspStage::load throws. Before the loop only.
    void load(std::string_view artifact) { stage_ = DspStage::load(artifact); }

    [[nodiscard]] bool enabled() const noexcept { return stage_.loaded(); }
    [[nodiscard]] DspStage& stage() noexcept { return stage_; }
    [[nodiscard]] const DspStage& stage() const noexcept { return stage_; }

    // Filter state and delay lines to silence: at each prime, so a start never
    // carries the tail of whatever was playing before the gap.
    void reset() noexcept { stage_.reset(); }

    // Take a published coefficient set without filtering anything: for the
    // wakes on which no block goes out, so a live update is not left waiting
    // for audio (dsp_live.hpp). As cheap as the two atomic loads it is.
    void take() noexcept { stage_.process(float_.data(), 0); }

    // `frames` of 16 interleaved channels, in place. Does nothing unloaded.
    void process(std::int32_t* interleaved, std::size_t frames) noexcept {
        if (!ready(frames)) return;
        to_float(interleaved, frames);
        filter(frames);
        from_float(interleaved, frames);
    }

    // process() in its three steps, for a caller that meters the floats
    // between them (meter_tap.hpp) and times the steps apart. Only when
    // ready(frames) is true.
    [[nodiscard]] bool ready(std::size_t frames) const noexcept {
        return stage_.loaded() && frames != 0 && frames <= kMaxFrames;
    }
    void to_float(const std::int32_t* interleaved, std::size_t frames) noexcept {
        const std::size_t samples = frames * kChannels;
        for (std::size_t i = 0; i < samples; ++i) float_[i] = s32_to_float(interleaved[i]);
    }
    void filter(std::size_t frames) noexcept { stage_.process(float_.data(), frames); }
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
    // The block between the steps: the input after to_float, the output after filter.
    [[nodiscard]] const float* floats() const noexcept { return float_.data(); }

private:
    DspStage stage_;
    std::array<float, kMaxFrames * kChannels> float_{};
};

}  // namespace usb16x16::owner
