// The owner's level meters: the bridge core's LevelMeter on three points of
// the path, and the publisher that writes them to a file in the bridge's
// format (METERS v=1, one TAP line per stage), so one reader serves both.
//
//   usb-capture     what the host sent, before the DSP stage
//   dante-playback  what goes to Dante, after the stage (the same samples as
//                   usb-capture when there is no preset)
//   dante-capture   what Dante returned; it goes to the host unchanged, so
//                   there is no fourth tap
//
// The outgoing taps see the blocks that go out: nothing while the outgoing
// direction is idle or priming. The clip count on dante-playback is of the
// float samples before the converter saturates them, which is the stage
// driving its output past full scale.
//
// Real-time contract, as LevelMeter's: observe() on the loop thread, fixed
// storage, no allocation, lock or syscall. MeterPublisher is for a thread
// that is never the loop.
//
// No ALSA here, so meter_tap_test.cpp builds and runs on the Mac.
#pragma once

#include "atomic_file.hpp"
#include "usb16x16/bridge_core.hpp"

#include <time.h>

#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <iomanip>
#include <sstream>
#include <string>
#include <utility>

namespace usb16x16::owner {

class OwnerMeters {
public:
    static constexpr std::size_t kMaxFrames = 1024;

    LevelMeter usb_capture;
    LevelMeter dante_playback;
    LevelMeter dante_capture;

    // A block of the owner's integers into one meter, or two when both see the same samples.
    void observe(const std::int32_t* interleaved, std::size_t frames, LevelMeter& first, LevelMeter* second = nullptr) noexcept {
        if (frames == 0 || frames > kMaxFrames) return;
        const std::size_t samples = frames * kChannels;
        for (std::size_t i = 0; i < samples; ++i) float_[i] = s32_to_float(interleaved[i]);
        first.observe(float_.data(), frames);
        if (second != nullptr) second->observe(float_.data(), frames);
    }

private:
    std::array<float, kMaxFrames * kChannels> float_{};
};

class MeterPublisher {
public:
    MeterPublisher(const OwnerMeters& meters, std::string path) : meters_(meters), path_(std::move(path)) {
        clock_gettime(CLOCK_MONOTONIC, &born_);
    }

    // Write the file if any tap has closed a window since the last write. True when it wrote.
    bool poll() {
        const LevelMeter* const taps[kTaps] = {&meters_.usb_capture, &meters_.dante_playback, &meters_.dante_capture};
        bool moved = false;
        for (std::size_t tap = 0; tap < kTaps; ++tap) {
            if (taps[tap]->read(snapshots_[tap]) && snapshots_[tap].sequence != last_sequence_[tap]) {
                last_sequence_[tap] = snapshots_[tap].sequence;
                moved = true;
            }
        }
        if (!moved) return false;
        ++writes_;
        timespec now{};
        clock_gettime(CLOCK_MONOTONIC, &now);
        const long long elapsed_us = (now.tv_sec - born_.tv_sec) * 1000000LL + (now.tv_nsec - born_.tv_nsec) / 1000;
        static constexpr const char* kStages[kTaps] = {"usb-capture", "dante-playback", "dante-capture"};
        std::ostringstream out;
        out << std::fixed << std::setprecision(1) << "METERS v=1 t_us=" << elapsed_us
            << " window_frames=" << taps[0]->window_frames() << " writes=" << writes_ << '\n';
        for (std::size_t tap = 0; tap < kTaps; ++tap) {
            const LevelMeter::Snapshot& snapshot = snapshots_[tap];
            out << "TAP stage=" << kStages[tap] << " seq=" << snapshot.sequence << " frames=" << snapshot.frames
                << " position=" << snapshot.position << " peak_dbfs=";
            for (std::size_t channel = 0; channel < kChannels; ++channel) {
                out << (channel == 0 ? "" : ",") << amplitude_to_dbfs(snapshot.peak[channel]);
            }
            out << " rms_dbfs=";
            for (std::size_t channel = 0; channel < kChannels; ++channel) {
                const double mean_square =
                    snapshot.frames == 0 ? 0.0 : snapshot.sum_squares[channel] / static_cast<double>(snapshot.frames);
                out << (channel == 0 ? "" : ",") << amplitude_to_dbfs(std::sqrt(mean_square));
            }
            out << " clip=";
            for (std::size_t channel = 0; channel < kChannels; ++channel) {
                out << (channel == 0 ? "" : ",") << snapshot.clipped[channel];
            }
            out << '\n';
        }
        if (!write_file_atomically(path_, out.str())) ++failures_;
        return true;
    }

    [[nodiscard]] std::uint64_t writes() const noexcept { return writes_; }
    [[nodiscard]] std::uint64_t failures() const noexcept { return failures_; }

private:
    static constexpr std::size_t kTaps = 3;
    const OwnerMeters& meters_;
    std::string path_;
    timespec born_{};
    std::array<LevelMeter::Snapshot, kTaps> snapshots_{};
    std::array<std::uint64_t, kTaps> last_sequence_{};
    std::uint64_t writes_{0};
    std::uint64_t failures_{0};
};

}  // namespace usb16x16::owner
