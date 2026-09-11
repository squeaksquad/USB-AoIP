// Bounded offline reference export: actual DSP core and bridge converters.
// Args: pinned artifact, sorted nonoverlapping [start, end) ranges file.
// Stdout: little-endian signed int32 L24 codes, 16 per frame, ranges in order.
#include "usb16x16/bridge_core.hpp"
#include <array>
#include <bit>
#include <fstream>
#include <iostream>
#include <sstream>
#include <utility>
#include <vector>

int main(int argc, char** argv) {
    try {
        static_assert(std::endian::native == std::endian::little);
        if (argc != 3) throw std::runtime_error("expected ARTIFACT RANGES");
        std::ifstream artifact(argv[1]), range_file(argv[2]);
        if (!artifact || !range_file) throw std::runtime_error("unreadable input");
        std::ostringstream text;
        text << artifact.rdbuf();
        auto dsp = usb16x16::DspStage::load(text.str());
        std::vector<std::pair<std::size_t, std::size_t>> ranges;
        std::string line;
        std::size_t total = 0;
        while (std::getline(range_file, line)) {
            std::istringstream row(line);
            long long first, last;
            std::string extra;
            if (!(row >> first >> last) || row >> extra || first < 0 || last <= first ||
                last > 600 * 48000 || (!ranges.empty() && first < static_cast<long long>(ranges.back().second)))
                throw std::runtime_error("invalid reference range");
            ranges.emplace_back(first, last);
            total += static_cast<std::size_t>(last - first);
            if (ranges.size() > 32 || total > 32 * 9700)
                throw std::runtime_error("reference range budget exceeded");
        }
        if (ranges.empty()) throw std::runtime_error("no reference ranges");
        std::array<float, 48 * 16> block{};
        std::array<std::int32_t, 16> codes{};
        std::uint32_t state = 0x9e3779b9;
        std::size_t selected = 0;
        for (std::size_t base = 0; base < ranges.back().second; base += 48) {
            for (float& sample : block) {
                state ^= state << 13; state ^= state >> 17; state ^= state << 5;
                sample = std::clamp(static_cast<float>(std::bit_cast<std::int32_t>(state)) /
                                    static_cast<float>(INT32_MAX), -1.0F, 1.0F) * 0.1F;
                std::uint8_t bytes[3];
                usb16x16::float_to_s24(sample, bytes);
                sample = usb16x16::s24_to_float(bytes);
            }
            dsp.process(block.data(), 48);
            for (std::size_t f = 0; f < 48; ++f) {
                const auto frame = base + f;
                while (selected < ranges.size() && frame >= ranges[selected].second) ++selected;
                if (selected == ranges.size()) break;
                if (frame < ranges[selected].first) continue;
                for (std::size_t c = 0; c < 16; ++c)
                    codes[c] = usb16x16::float_to_s32(block[f * 16 + c]) >> 8;
                std::cout.write(reinterpret_cast<const char*>(codes.data()), sizeof(codes));
            }
        }
        if (!std::cout) throw std::runtime_error("reference output failed");
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
