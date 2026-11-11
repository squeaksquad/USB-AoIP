// Mac-side test of seq_check.hpp: the sequence steps back exactly, and a loop that
// drops or repeats frames, or shifts a 16-frame block by 8 (the 96 kHz event of
// 2026-10-29), is named as `bitexact` names it.
//   c++ -std=c++20 -O2 -Wall -Wextra -Wpedantic -Werror -o /tmp/seq_check_test seq_check_test.cpp && /tmp/seq_check_test
#include "seq_check.hpp"

#include <cstdio>
#include <vector>

using namespace usb16x16::owner;

namespace {

int failures = 0;
void expect(bool ok, const char* what) {
    if (!ok) { std::printf("FAIL %s\n", what); ++failures; }
}

constexpr unsigned kChannels = 16;

// The sequence on channels 0..7 at positions `order`, 24 bits at the top of 32.
std::vector<std::int32_t> frames(const std::vector<std::uint32_t>& codes0, const std::vector<std::size_t>& order) {
    std::vector<std::int32_t> out(order.size() * kChannels, 0);
    for (std::size_t f = 0; f < order.size(); ++f) {
        for (unsigned c = 0; c < 8; ++c) {
            std::uint32_t code = codes0[c];
            for (std::size_t n = 0; n <= order[f]; ++n) code = SeqSequence::next(code, c);
            out[f * kChannels + c] = static_cast<std::int32_t>(code << 8);
        }
    }
    return out;
}

}  // namespace

int main() {
    for (unsigned c : {0u, 7u, 15u}) {
        std::uint32_t code = 4321;
        for (int i = 0; i < 1000; ++i) {
            const std::uint32_t following = SeqSequence::next(code, c);
            expect(SeqSequence::previous(following, c) == code, "previous inverts next");
            code = following;
        }
    }

    const std::vector<std::uint32_t> seeds{1, 2, 3, 4, 5, 6, 7, 8};
    // Positions: 0..999, then 8 dropped (1008..1023 in 1000..1015: the block shifted by 8), then from 1016 on as
    // normal (1016..1023 again: 8 repeated), then 1 dropped at 2000, 1 repeated at 3000.
    std::vector<std::size_t> order;
    for (std::size_t p = 0; p < 1000; ++p) order.push_back(p);
    for (std::size_t p = 1008; p < 1024; ++p) order.push_back(p);
    for (std::size_t p = 1016; p < 2000; ++p) order.push_back(p);
    for (std::size_t p = 2001; p < 3000; ++p) order.push_back(p);
    order.push_back(2999);
    for (std::size_t p = 3000; p < 4000; ++p) order.push_back(p);
    const auto block = frames(seeds, order);

    SeqTrace trace;
    SeqCheck<kChannels> check;
    check.point = 1;
    check.channels = 8;
    // In wakes of 37 frames, as the loop would hand them over.
    const long total = static_cast<long>(order.size());
    for (long at = 0; at < total; at += 37) {
        const long n = at + 37 <= total ? 37 : total - at;
        check.observe(block.data() + static_cast<std::size_t>(at) * kChannels, n, trace);
    }
    expect(trace.written.load() == 4 * 8, "four events on each of eight channels");
    const struct { std::uint64_t frame; SeqKind kind; int count; } want[4] = {
        {1000, SeqKind::dropped, 8}, {1016, SeqKind::repeated, 8}, {2000, SeqKind::dropped, 1}, {2999, SeqKind::repeated, 1}};
    for (unsigned c = 0; c < 8; ++c) {
        expect(check.lost[c] == 4 && check.locks[c] == 5, "lost and locks per channel");
        for (int e = 0; e < 4; ++e) {
            const SeqEvent& event = trace.events[e * 8 + c];
            expect(event.channel == static_cast<int>(c) + 1 && event.point == 1, "event channel and point");
            expect(event.frame == want[e].frame, "event frame");
            expect(event.kind == want[e].kind && event.count == want[e].count, "event kind and count");
        }
    }
    for (unsigned c = 8; c < kChannels; ++c) expect(check.lost[c] == 0 && check.locks[c] == 0, "channels past the check");

    // Silence never locks.
    std::vector<std::int32_t> silence(1000 * kChannels, 0);
    SeqTrace quiet;
    SeqCheck<kChannels> idle;
    idle.channels = 8;
    idle.observe(silence.data(), 1000, quiet);
    expect(quiet.written.load() == 0 && idle.locks[0] == 0, "silence");

    std::printf("%s\n", failures == 0 ? "seq_check_test: all passed" : "seq_check_test: FAILED");
    return failures == 0 ? 0 : 1;
}
