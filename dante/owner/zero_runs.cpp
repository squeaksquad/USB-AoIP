// An hour of the harness's kind of load (independent uniform white noise at 0.1 on sixteen channels)
// through a preset, by the owner's own path (dsp_path.hpp), counting the longest run of exact zeros
// per output. It answers one question: when a soak reports a zero run on a channel, is that the
// preset (a low-level, low-passed output crossing zero slowly) or the transport? No transport here.
//   c++ -std=c++20 -O2 -I . -I ../../phase4-bridge/include -o /tmp/zero_runs zero_runs.cpp ../../phase4-bridge/src/bridge_core.cpp
//   /tmp/zero_runs ARTIFACT.dsp [SECONDS=3600]
#include "dsp_path.hpp"
#include <cstdio>
#include <fstream>
#include <memory>
#include <sstream>
#include <vector>
int main(int argc, char** argv) {
    std::ifstream file(argv[1], std::ios::binary); std::stringstream text; text << file.rdbuf();
    auto dsp = std::make_unique<usb16x16::owner::OutDsp>(); dsp->load(text.str());
    const long seconds = argc > 2 ? atol(argv[2]) : 3600;
    std::uint32_t state = 0x12345678u;
    auto next = [&]() { state ^= state << 13; state ^= state >> 17; state ^= state << 5; return state; };
    std::vector<std::int32_t> block(48 * 16);
    long run[16] = {0}, longest[16] = {0}, runs4[16] = {0}; double peak[16] = {0};
    for (long b = 0; b < seconds * 1000; ++b) {
        for (auto& s : block) {
            const double v = (static_cast<double>(next()) / 4294967296.0 * 2.0 - 1.0) * 0.1;
            s = static_cast<std::int32_t>(static_cast<std::uint32_t>(static_cast<std::int32_t>(v * 8388608.0)) << 8);
        }
        dsp->process(block.data(), 48);
        for (int f = 0; f < 48; ++f) for (int c = 0; c < 16; ++c) {
            const std::int32_t s = block[f * 16 + c] >> 8;
            if (s == 0) { if (++run[c] > longest[c]) longest[c] = run[c]; if (run[c] == 4) ++runs4[c]; } else run[c] = 0;
            const double a = (s < 0 ? -s : s) / 8388608.0; if (a > peak[c]) peak[c] = a;
        }
    }
    for (int c = 0; c < 16; ++c) std::printf("ch%-2d longest zero run %-4ld runs>=4: %-4ld peak %.4f\n", c + 1, longest[c], runs4[c], peak[c]);
}
