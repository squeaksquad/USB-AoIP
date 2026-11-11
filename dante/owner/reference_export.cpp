// Offline reference for the soak criterion (../soak_reference.py): what the
// Mac harness's `continuous` stimulus becomes on the Dante wire after a
// preset, by the owner's own path. Modelled on
// work/dsp-service/reference-export.cpp, which does this for the bridge.
//
//   reference_export ARTIFACT RANGES [RATE [OUTPUT_GAIN]]
//
// RATE: the rate ARTIFACT was compiled for and the capture ran at (a Dante
// rate, default 48000); the load refuses an artifact compiled for another.
// OUTPUT_GAIN: the Mac's gain on the way out, as the harness's `hostgain`
// measured it (default 0.999998 as a float, the 2026-10-10 figure; unity on
// 2026-10-27).
// RANGES: sorted, non-overlapping "first last" frame pairs (last exclusive)
// of the stimulus, one per line. Stdout: little-endian int32 24-bit codes,
// 16 per frame, the ranges in order.
//
// The stimulus is the harness's: xorshift32 from 0x9e3779b9, one draw per
// sample in interleaved order from frame 0, scaled to +/-0.1. Between it and
// the Pi sits macOS, which multiplies by OUTPUT_GAIN on this device and rounds
// to 24 bits (the same model `bitexact` uses, RESULTS.md 2026-10-10); then
// the owner: 24 bits in an S32, OutDsp, 24 bits out. Filters start from
// silence at frame 0, as they do not on the Pi; the harness's two-second
// warm-up before anything is judged is what covers the difference.
//
// Build anywhere (no ALSA):
//   c++ -std=c++20 -O2 -I . -I ../../phase4-bridge/include -o /tmp/reference_export reference_export.cpp ../../phase4-bridge/src/bridge_core.cpp
#include "dsp_path.hpp"
#include "rate_check.hpp"

#include <algorithm>
#include <bit>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <fstream>
#include <iostream>
#include <memory>
#include <sstream>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

int main(int argc, char** argv) {
    try {
        static_assert(std::endian::native == std::endian::little);
        if (argc < 3 || argc > 5) throw std::runtime_error("expected ARTIFACT RANGES [RATE [OUTPUT_GAIN]]");
        const unsigned rate = argc >= 4 ? static_cast<unsigned>(std::stoul(argv[3])) : 48000U;
        const double host_gain = argc == 5 ? std::stod(argv[4]) : static_cast<double>(0.999998F);
        if (!(std::abs(host_gain - 1.0) < 1e-4)) throw std::runtime_error("OUTPUT_GAIN must be within 1e-4 of unity");
        if (!usb16x16::owner::is_dante_rate(rate)) throw std::runtime_error("RATE must be a Dante rate");
        std::ifstream artifact(argv[1], std::ios::binary), range_file(argv[2]);
        if (!artifact || !range_file) throw std::runtime_error("unreadable input");
        std::ostringstream text;
        text << artifact.rdbuf();
        auto dsp = std::make_unique<usb16x16::owner::OutDsp>();
        dsp->load(text.str(), rate);

        const long long kMaxFrames = 3600LL * static_cast<long long>(rate);   // an hour
        std::vector<std::pair<long long, long long>> ranges;
        std::string line;
        long long total = 0;
        while (std::getline(range_file, line)) {
            std::istringstream row(line);
            long long first = 0, last = 0;
            std::string extra;
            if (!(row >> first >> last) || row >> extra || first < 0 || last <= first || last > kMaxFrames ||
                (!ranges.empty() && first < ranges.back().second)) {
                throw std::runtime_error("invalid reference range");
            }
            ranges.emplace_back(first, last);
            total += last - first;
            if (ranges.size() > 64 || total > 64 * 9700) throw std::runtime_error("reference range budget exceeded");
        }
        if (ranges.empty()) throw std::runtime_error("no reference ranges");

        constexpr std::size_t kBlock = 48, kChannels = 16;
        std::vector<std::int32_t> block(kBlock * kChannels);
        std::int32_t codes[kChannels];
        std::uint32_t state = 0x9e3779b9;
        std::size_t selected = 0;
        for (long long base = 0; base < ranges.back().second; base += static_cast<long long>(kBlock)) {
            for (std::int32_t& sample : block) {
                state ^= state << 13; state ^= state >> 17; state ^= state << 5;
                const float sent = std::clamp(static_cast<float>(std::bit_cast<std::int32_t>(state)) /
                                              static_cast<float>(INT32_MAX), -1.0F, 1.0F) * 0.1F;
                const long code = std::clamp(std::lrint(static_cast<double>(sent) * host_gain * 8388608.0), -8388608L, 8388607L);
                sample = static_cast<std::int32_t>(static_cast<std::uint32_t>(static_cast<std::int32_t>(code)) << 8);
            }
            dsp->process(block.data(), kBlock);
            for (std::size_t f = 0; f < kBlock; ++f) {
                const long long frame = base + static_cast<long long>(f);
                while (selected < ranges.size() && frame >= ranges[selected].second) ++selected;
                if (selected == ranges.size()) break;
                if (frame < ranges[selected].first) continue;
                for (std::size_t c = 0; c < kChannels; ++c) codes[c] = block[f * kChannels + c] >> 8;
                std::cout.write(reinterpret_cast<const char*>(codes), sizeof codes);
            }
        }
        if (!std::cout) throw std::runtime_error("reference output failed");
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
