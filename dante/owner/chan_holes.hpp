// Per-channel zero runs in what Inferno delivers (diagnostic, 2026-10-31), the
// trigger for the 96 kHz catch of RATE96_PLAN.md: the loaded hour of 2026-10-29
// lost 32 and 64 frames on channels 3, 5, 6 and 8 together, which back_holes
// (all sixteen channels zero) cannot see and a running preset keeps the SEQ
// check from seeing. On channels 1..channels, a run of zeros from kMinFrames to
// kMaxFrames frames that ends in signal is recorded with the wall clock when it
// ends; a longer run is silence, not a hole. A preset's own low-passed output
// dwells near zero for runs of up to 11 frames at 96 kHz (2026-10-29), under
// kMinFrames.
//
// Runs on the loop thread: no allocation, no system call except the clock read
// when an event is recorded; the telemetry thread prints the events.
#pragma once

#include <array>
#include <atomic>
#include <cstdint>
#include <ctime>

namespace usb16x16::owner {

struct ChanHoleEvent {
    std::int64_t wall_ns{0};          // CLOCK_REALTIME, when the run ended
    std::uint64_t frame{0};           // frames seen before the run's first zero
    int channel{0};                   // 1-based
    std::uint32_t frames{0};          // the run's length
};

struct ChanHoleTrace {
    std::array<ChanHoleEvent, 64> events{};
    std::atomic<std::uint64_t> written{0};
    void record(const ChanHoleEvent& event) noexcept {
        const std::uint64_t n = written.load(std::memory_order_relaxed);
        events[n % events.size()] = event;
        written.store(n + 1, std::memory_order_release);
    }
};

// Interleaved S32 frames of Channels channels; checks 1..channels.
template <unsigned Channels>
struct ChanHoles {
    static constexpr std::uint32_t kMinFrames = 16;
    static constexpr std::uint32_t kMaxFrames = 4800;
    unsigned channels{0};             // 0: off
    std::uint64_t frames{0};
    std::array<std::uint32_t, Channels> run{};
    std::array<bool, Channels> heard{};   // a run counts only after signal on that channel

    void observe(const std::int32_t* block, long count, ChanHoleTrace& trace) noexcept {
        for (long f = 0; f < count; ++f, ++frames) {
            const std::int32_t* samples = block + static_cast<std::size_t>(f) * Channels;
            for (unsigned c = 0; c < channels; ++c) {
                if (samples[c] == 0) {
                    if (run[c] <= kMaxFrames) ++run[c];
                    continue;
                }
                if (heard[c] && run[c] >= kMinFrames && run[c] <= kMaxFrames) {
                    ChanHoleEvent event;
                    timespec ts{};
                    clock_gettime(CLOCK_REALTIME, &ts);
                    event.wall_ns = static_cast<std::int64_t>(ts.tv_sec) * 1000000000LL + ts.tv_nsec;
                    event.frame = frames - run[c];
                    event.channel = static_cast<int>(c) + 1;
                    event.frames = run[c];
                    trace.record(event);
                }
                heard[c] = true;
                run[c] = 0;
            }
        }
    }

    // A new stream: a run open across the gap is not a hole.
    void reset() noexcept {
        run.fill(0);
        heard.fill(false);
    }
};

}  // namespace usb16x16::owner
