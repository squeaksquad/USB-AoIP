// The Mac's `bitexact` sequence checked inside the owner (diagnostic, 2026-10-29),
// at the two points the owner sees: what the gadget delivers (the outgoing
// direction, before Inferno) and what Inferno delivers (the return, before the
// gadget). Channel c carries sequence c on both, as the 8-channel loop maps
// TX 1-8 to RX 1-8. Each lost lock is named as `bitexact` names it
// (work/latency-harness/Sources/USB16x16LatencyCore/BitExact.swift): frames
// dropped, frames repeated, or other. The sequence and its constants are that
// file's; a run at unity host gain is assumed (96 kHz on 2026-10-29), so a
// code at the negative limit (-2^23, sent as -2^23+1) is passed over.
//
// Runs on the loop thread: no allocation, no system call except the clock read
// when an event is recorded; the telemetry thread prints the events.
#pragma once

#include <array>
#include <atomic>
#include <cstdint>
#include <ctime>

namespace usb16x16::owner {

struct SeqSequence {
    static constexpr std::uint32_t multiplier = 1664525;
    static constexpr std::uint32_t mask = 0x00FFFFFF;
    static constexpr std::uint32_t increment(unsigned channel) { return (1013904223u + 2u * channel) & mask; }
    static constexpr std::uint32_t next(std::uint32_t code, unsigned channel) {
        return (code * multiplier + increment(channel)) & mask;
    }
    static constexpr std::uint32_t inverse() {
        std::uint32_t x = multiplier;
        for (int i = 0; i < 5; ++i) x *= 2u - multiplier * x;
        return x & mask;
    }
    static constexpr std::uint32_t previous(std::uint32_t code, unsigned channel) {
        return ((code - increment(channel)) * inverse()) & mask;
    }
    // Searched each way on a lost lock; past it the event is `other`.
    static constexpr int search = 1024;
};

enum class SeqKind : int { dropped = 0, repeated = 1, other = 2 };

struct SeqEvent {
    std::int64_t wall_ns{0};          // CLOCK_REALTIME
    std::uint64_t frame{0};           // frames this checkpoint has seen before this one
    int point{0};                     // 0 gadget capture (out), 1 Inferno capture (back)
    int channel{0};                   // 1-based
    SeqKind kind{SeqKind::other};
    int count{0};
};

struct SeqTrace {
    std::array<SeqEvent, 64> events{};
    std::atomic<std::uint64_t> written{0};
    void record(const SeqEvent& event) noexcept {
        const std::uint64_t n = written.load(std::memory_order_relaxed);
        events[n % events.size()] = event;
        written.store(n + 1, std::memory_order_release);
    }
};

inline SeqKind seq_classify(std::uint32_t received, std::uint32_t last, unsigned channel, int& count) noexcept {
    std::uint32_t forward = SeqSequence::next(last, channel), back = last;
    for (int n = 1; n <= SeqSequence::search; ++n) {
        if (received == back) { count = n; return SeqKind::repeated; }
        forward = SeqSequence::next(forward, channel);
        if (received == forward) { count = n; return SeqKind::dropped; }
        back = SeqSequence::previous(back, channel);
    }
    count = 0;
    return SeqKind::other;
}

// One checkpoint over channels 1..channels of interleaved S32 frames (24 bits at the top).
template <unsigned Channels>
struct SeqCheck {
    int point{0};
    unsigned channels{0};             // 0: off
    std::array<std::uint32_t, Channels> last{};
    std::array<bool, Channels> have{};
    std::array<bool, Channels> locked{};
    std::uint64_t frames{0};
    std::array<std::uint64_t, Channels> locks{};   // times each channel locked
    std::array<std::uint64_t, Channels> lost{};

    void observe(const std::int32_t* block, long count, SeqTrace& trace) noexcept {
        for (long f = 0; f < count; ++f, ++frames) {
            const std::int32_t* samples = block + static_cast<std::size_t>(f) * Channels;
            for (unsigned c = 0; c < channels; ++c) {
                const std::uint32_t code = (static_cast<std::uint32_t>(samples[c]) >> 8) & SeqSequence::mask;
                // -2^23+1 is where the Mac sends -2^23: it does not say which value it was.
                const bool clamped = code == 0x00800001;
                if (!have[c] || clamped) {
                    have[c] = !clamped;
                    last[c] = code;
                    continue;
                }
                const std::uint32_t expected = SeqSequence::next(last[c], c);
                if (code == expected) {
                    if (!locked[c]) { locked[c] = true; ++locks[c]; }
                } else if (locked[c]) {
                    locked[c] = false;
                    ++lost[c];
                    SeqEvent event;
                    timespec ts{};
                    clock_gettime(CLOCK_REALTIME, &ts);
                    event.wall_ns = static_cast<std::int64_t>(ts.tv_sec) * 1000000000LL + ts.tv_nsec;
                    event.frame = frames;
                    event.point = point;
                    event.channel = static_cast<int>(c) + 1;
                    event.kind = seq_classify(code, last[c], c, event.count);
                    trace.record(event);
                }
                last[c] = code;
            }
        }
    }
};

}  // namespace usb16x16::owner
