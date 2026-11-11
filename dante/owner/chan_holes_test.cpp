// Mac-side test of chan_holes.hpp: a 32-frame hole on a subset of channels is
// recorded per channel with its start frame and length; short runs, silence,
// a run before any signal and an unchecked channel are not.
//   c++ -std=c++20 -O2 -Wall -Wextra -Wpedantic -Werror -o /tmp/chan_holes_test chan_holes_test.cpp && /tmp/chan_holes_test
#include "chan_holes.hpp"

#include <cstdio>
#include <vector>

using namespace usb16x16::owner;

namespace {

int failures = 0;
void expect(bool ok, const char* what) {
    if (!ok) { std::printf("FAIL %s\n", what); ++failures; }
}

constexpr unsigned kChannels = 16;

std::vector<std::int32_t> signal(std::size_t count) {
    std::vector<std::int32_t> out(count * kChannels);
    for (std::size_t i = 0; i < out.size(); ++i) out[i] = static_cast<std::int32_t>((i % 7 + 1) << 8);
    return out;
}

void zero(std::vector<std::int32_t>& block, unsigned channel, std::size_t from, std::size_t count) {
    for (std::size_t f = from; f < from + count; ++f) block[f * kChannels + channel] = 0;
}

}  // namespace

int main() {
    {
        // The 2026-10-29 shape: 32 frames on channels 3, 5, 6 and 8, split across two blocks.
        ChanHoles<kChannels> holes;
        holes.channels = 8;
        ChanHoleTrace trace;
        auto block = signal(256);
        for (unsigned c : {2u, 4u, 5u, 7u}) zero(block, c, 113, 32);
        holes.observe(block.data(), 120, trace);
        expect(trace.written.load() == 0, "an open run is not recorded before it ends");
        holes.observe(block.data() + 120 * kChannels, 136, trace);
        expect(trace.written.load() == 4, "four channels, four events");
        bool shape = true;
        const int want[] = {3, 5, 6, 8};
        for (int i = 0; i < 4; ++i) {
            const ChanHoleEvent& e = trace.events[i];
            shape = shape && e.channel == want[i] && e.frame == 113 && e.frames == 32 && e.wall_ns > 0;
        }
        expect(shape, "channel, start frame and length as zeroed");
    }
    {
        ChanHoles<kChannels> holes;
        holes.channels = 8;
        ChanHoleTrace trace;
        auto block = signal(9000);
        zero(block, 0, 10, 11);     // a preset's own short run
        zero(block, 1, 100, 15);    // one under the threshold
        zero(block, 2, 200, 16);    // the threshold
        zero(block, 3, 300, 5000);  // silence, not a hole
        zero(block, 9, 400, 64);    // channel 10: not checked
        holes.observe(block.data(), 9000, trace);
        expect(trace.written.load() == 1, "only the 16-frame run counts");
        expect(trace.events[0].channel == 3 && trace.events[0].frames == 16, "it is channel 3's");
    }
    {
        // A channel silent from the start, then signal: not a hole; after a reset, an open run is dropped.
        ChanHoles<kChannels> holes;
        holes.channels = 8;
        ChanHoleTrace trace;
        auto block = signal(200);
        zero(block, 0, 0, 40);
        zero(block, 1, 160, 40);
        holes.observe(block.data(), 200, trace);
        holes.reset();
        auto next = signal(10);
        holes.observe(next.data(), 10, trace);
        expect(trace.written.load() == 0, "a leading run and a run cut by a reset are not holes");
    }
    {
        ChanHoles<kChannels> holes;
        ChanHoleTrace trace;
        auto block = signal(100);
        zero(block, 0, 10, 40);
        holes.observe(block.data(), 100, trace);
        expect(trace.written.load() == 0, "off when channels is 0");
    }
    std::printf(failures ? "chan_holes_test: %d failures\n" : "chan_holes_test: ok\n", failures);
    return failures ? 1 : 0;
}
