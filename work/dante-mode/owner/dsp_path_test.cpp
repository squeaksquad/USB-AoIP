// Mac-side test of the owner's DSP adapter: the integer boundary around
// DspStage, not the filters (those are the bridge core's tests and the
// work/dsp-compiler harnesses).
//   c++ -std=c++20 -O2 -Wall -Wextra -Wpedantic -Werror -I ../../phase4-bridge/include
//       -o /tmp/dsp_path_test dsp_path_test.cpp ../../phase4-bridge/src/bridge_core.cpp && /tmp/dsp_path_test [ARTIFACT.dsp...]
// (one line)
// Each artifact named is loaded and run for a second of noise as well: it
// must load, keep the low byte zero and never wrap.
#include "dsp_path.hpp"

#include <cstdio>
#include <fstream>
#include <memory>
#include <random>
#include <sstream>
#include <string>
#include <vector>

using usb16x16::owner::OutDsp;

namespace {

int failures = 0;

void check(bool condition, const char* message) {
    if (!condition) {
        std::printf("FAIL: %s\n", message);
        ++failures;
    }
}

constexpr std::size_t kChannels = usb16x16::kChannels;

// Every input to the output of the same number at `gain`, no filters, no delay.
std::string straight(double gain) {
    std::string text = "usb16x16-dsp 1\npreset straight\nrate 48000\nchannels 16\ninternal 16\nmaxdelay 480\nexpand 16\n";
    for (std::size_t c = 0; c < kChannels; ++c) text += std::to_string(c) + " " + std::to_string(c) + " " + std::to_string(gain) + "\n";
    text += "branch 0\nassign 16\n";
    for (std::size_t c = 0; c < kChannels; ++c) text += std::to_string(c) + " " + std::to_string(c) + " 1\n";
    text += "output 16\n";
    for (std::size_t c = 0; c < kChannels; ++c) text += std::to_string(c) + " 0 1 0\n";
    return text + "end\n";
}

std::int32_t top24(std::int32_t value24) { return static_cast<std::int32_t>(static_cast<std::uint32_t>(value24) << 8); }

std::vector<std::int32_t> noise(std::size_t frames, unsigned seed) {
    std::mt19937 rng(seed);
    std::uniform_int_distribution<std::int32_t> any(-8388608, 8388607);
    std::vector<std::int32_t> block(frames * kChannels);
    for (auto& sample : block) sample = top24(any(rng));
    return block;
}

void test_unloaded_is_inert() {
    auto dsp = std::make_unique<OutDsp>();
    check(!dsp->enabled(), "an adapter with no preset is not enabled");
    auto block = noise(48, 1);
    const auto before = block;
    dsp->process(block.data(), 48);
    check(block == before, "an adapter with no preset leaves the block untouched");
}

void test_unity_is_bit_exact() {
    auto dsp = std::make_unique<OutDsp>();
    dsp->load(straight(1.0));
    check(dsp->enabled(), "a valid artifact enables the adapter");
    // Every code the format has at the extremes, then noise, in blocks of the sizes the owner sees.
    std::vector<std::int32_t> edges;
    for (const std::int32_t v : {0, 1, -1, 2, -2, 8388607, 8388606, -8388608, -8388607, 4194304, -4194304, 255, -256}) {
        for (std::size_t c = 0; c < kChannels; ++c) edges.push_back(top24(v));
    }
    auto block = edges;
    dsp->process(block.data(), block.size() / kChannels);
    check(block == edges, "unity carries the extreme 24-bit codes unchanged");
    for (const std::size_t frames : {std::size_t{1}, std::size_t{47}, std::size_t{48}, std::size_t{49}, std::size_t{96}, OutDsp::kMaxFrames}) {
        auto sent = noise(frames, static_cast<unsigned>(frames));
        const auto kept = sent;
        dsp->process(sent.data(), frames);
        check(sent == kept, "unity carries 24-bit noise unchanged at every block size");
    }
}

void test_gain_rounds_and_saturates() {
    auto half = std::make_unique<OutDsp>();
    half->load(straight(0.5));
    std::vector<std::int32_t> block(kChannels, top24(8388607));
    block[1] = top24(-8388608);
    block[2] = top24(3);
    half->process(block.data(), 1);
    check(block[0] == top24(4194304), "half of +full scale rounds to nearest (4194303.5 -> 4194304)");
    check(block[1] == top24(-4194304), "half of -full scale is exact");
    check(block[2] == top24(2), "1.5 rounds to even, as lrint does");
    bool low_byte_zero = true;
    auto sent = noise(480, 9);
    half->process(sent.data(), 480);
    for (const auto sample : sent) low_byte_zero = low_byte_zero && (sample & 0xFF) == 0;
    check(low_byte_zero, "the low byte is zero after a gain");

    auto twice = std::make_unique<OutDsp>();
    twice->load(straight(2.0));
    std::vector<std::int32_t> hot(kChannels, top24(8388607));
    hot[1] = top24(-8388608);
    hot[2] = top24(4194304);
    hot[3] = top24(-4194305);
    twice->process(hot.data(), 1);
    check(hot[0] == top24(8388607), "+6 dB on +full scale saturates, never wraps");
    check(hot[1] == top24(-8388608), "+6 dB on -full scale saturates, never wraps");
    check(hot[2] == top24(8388607), "exactly +1.0 saturates to the top code");
    check(hot[3] == top24(-8388608), "just past -1.0 saturates to the bottom code");
}

void test_reset_clears_state() {
    // One-sample delay on every output: the second block starts with the first's last frame unless reset.
    std::string text = straight(1.0);
    for (std::size_t at = text.find(" 0 1 0\n"); at != std::string::npos; at = text.find(" 0 1 0\n", at + 1)) text.replace(at, 7, " 1 1 0\n");
    auto dsp = std::make_unique<OutDsp>();
    dsp->load(text);
    check(dsp->stage().delay_samples() == 1, "the delayed fixture reports its delay");
    std::vector<std::int32_t> first(kChannels, top24(1000));
    dsp->process(first.data(), 1);
    check(first[0] == 0, "a delayed output starts with silence");
    std::vector<std::int32_t> carried(kChannels, 0);
    dsp->process(carried.data(), 1);
    check(carried[0] == top24(1000), "the delay line carries from block to block");
    dsp->process(first.data(), 1);
    dsp->reset();
    std::vector<std::int32_t> after(kChannels, 0);
    dsp->process(after.data(), 1);
    check(after[0] == 0, "reset empties the delay line");
}

void test_oversized_block_is_refused() {
    auto dsp = std::make_unique<OutDsp>();
    dsp->load(straight(0.5));
    auto block = noise(OutDsp::kMaxFrames + 1, 3);
    const auto before = block;
    dsp->process(block.data(), OutDsp::kMaxFrames + 1);
    check(block == before, "a block longer than the scratch is left alone, not overrun");
}

void run_artifact(const char* path) {
    std::ifstream file(path, std::ios::binary);
    std::stringstream text;
    text << file.rdbuf();
    auto dsp = std::make_unique<OutDsp>();
    try {
        dsp->load(text.str());
    } catch (const std::exception& error) {
        std::printf("FAIL: %s: %s\n", path, error.what());
        ++failures;
        return;
    }
    bool low_byte_zero = true;
    for (unsigned block = 0; block < 1000; ++block) {
        auto sent = noise(48, block);
        dsp->process(sent.data(), 48);
        for (const auto sample : sent) low_byte_zero = low_byte_zero && (sample & 0xFF) == 0;
    }
    check(low_byte_zero, "an artifact from the compiler keeps the low byte zero");
    std::printf("artifact %s: preset=\"%s\" internal=%zu biquads=%zu delay=%zu\n", path, dsp->stage().preset().c_str(),
                dsp->stage().internal_channels(), dsp->stage().biquad_count(), dsp->stage().delay_samples());
}

}  // namespace

int main(int argc, char** argv) {
    test_unloaded_is_inert();
    test_unity_is_bit_exact();
    test_gain_rounds_and_saturates();
    test_reset_clears_state();
    test_oversized_block_is_refused();
    for (int i = 1; i < argc; ++i) run_artifact(argv[i]);
    std::printf(failures == 0 ? "dsp_path_test: all passed\n" : "dsp_path_test: %d FAILED\n", failures);
    return failures == 0 ? 0 : 1;
}
