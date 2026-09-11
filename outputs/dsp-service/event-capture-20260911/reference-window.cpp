// Export the predicted event's full 39-frame, 16-channel wire neighborhood.
// Same pinned core, seed and S24-rounded input model as replay-loaded.cpp.
#include "usb16x16/bridge_core.hpp"
#include <array>
#include <bit>
#include <fstream>
#include <iostream>
#include <sstream>

int main(int argc, char** argv) {
    if (argc != 2) return 2;
    std::ifstream file(argv[1]);
    if (!file) return 3;
    std::ostringstream text;
    text << file.rdbuf();
    auto dsp = usb16x16::DspStage::load(text.str());
    std::array<float, 48 * 16> block{};
    std::uint32_t state = 0x9e3779b9;
    constexpr std::size_t start = 3304775;
    for (std::size_t base = 0; base <= start + 22; base += 48) {
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
            if (base + f < start - 16 || base + f > start + 22) continue;
            std::cout << base + f;
            for (std::size_t c = 0; c < 16; ++c)
                std::cout << ' ' << (usb16x16::float_to_s32(block[f * 16 + c]) >> 8);
            std::cout << '\n';
        }
    }
}
