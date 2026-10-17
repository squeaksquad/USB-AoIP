// The owner's sample rate rules (SAMPLE_RATE_DESIGN.md, step 3).
//
// The owner runs at one rate, --rate, for its whole life: a rate change is a
// full endpoint restart, never a live change. Two things follow from that and
// live here, apart from ALSA, so rate_check_test.cpp builds and runs on the Mac:
//
//   * which rates --rate may name: the Dante rates. Which of them are offered
//     is not the owner's decision (the arbiter's list, [48000] until each
//     other rate has its battery); the owner only refuses what Dante does not
//     have at all.
//   * whether the gadget may be joined: the host's choice shows as the ALSA
//     controls "Capture Rate" and "Playback Rate" on the gadget's card, 0
//     while the host has the interface down. A rate that differs from --rate
//     keeps the USB half closed; USB audio is never played at a rate the two
//     ends disagree on. 0, or controls the kernel does not have, is "not
//     known", and the open goes ahead as it always has: the PCM's own
//     hw_params refuses a rate it cannot run.
#pragma once

#include <array>
#include <string>

namespace usb16x16::owner {

inline constexpr std::array<unsigned, 6> kDanteRates{44100, 48000, 88200, 96000, 176400, 192000};
inline constexpr unsigned kDefaultRate = 48000;

[[nodiscard]] constexpr bool is_dante_rate(unsigned rate) noexcept {
    for (const unsigned r : kDanteRates) {
        if (r == rate) return true;
    }
    return false;
}

enum class GadgetRate { match, unknown, mismatch };

// `capture` and `playback` as read from the controls; negative when a control
// could not be read.
[[nodiscard]] constexpr GadgetRate judge_gadget_rate(long capture, long playback, unsigned wanted) noexcept {
    const auto differs = [wanted](long value) { return value > 0 && value != static_cast<long>(wanted); };
    if (differs(capture) || differs(playback)) return GadgetRate::mismatch;
    if (capture == static_cast<long>(wanted) && playback == static_cast<long>(wanted)) return GadgetRate::match;
    return GadgetRate::unknown;
}

// The arbiter's request when the host is at another rate (--rate-request-file,
// SAMPLE_RATE_DESIGN.md step 4): the line usb16x16-apply --rate-request reads.
// Empty when there is nothing to ask for: the host matches or is not known, or
// its two directions disagree with each other (no one rate was chosen).
[[nodiscard]] inline std::string usb_rate_request_line(long capture, long playback, unsigned wanted, long long at) {
    if (judge_gadget_rate(capture, playback, wanted) != GadgetRate::mismatch) return {};
    if (capture > 0 && playback > 0 && capture != playback) return {};
    const long rate = capture > 0 ? capture : playback;
    if (!is_dante_rate(static_cast<unsigned>(rate))) return {};
    return "rate=" + std::to_string(rate) + " source=usb at=" + std::to_string(at) + "\n";
}

[[nodiscard]] constexpr const char* gadget_rate_name(GadgetRate verdict) noexcept {
    return verdict == GadgetRate::match ? "match" : verdict == GadgetRate::mismatch ? "mismatch" : "unknown";
}

}  // namespace usb16x16::owner
