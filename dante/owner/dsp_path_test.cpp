// Mac-side test of the owner's DSP adapter: the integer boundary around
// DspStage, not the filters (those are the bridge core's tests and the
// work/dsp-compiler harnesses).
//   c++ -std=c++20 -O2 -Wall -Wextra -Wpedantic -Werror -I ../../dsp-core/include
//       -o /tmp/dsp_path_test dsp_path_test.cpp ../../dsp-core/src/bridge_core.cpp && /tmp/dsp_path_test [ARTIFACT.dsp...]
// (one line)
// Each artifact named is loaded and run for a second of noise as well: it
// must load, keep the low byte zero and never wrap.
#include "dsp_path.hpp"

#include <cstdio>
#include <fstream>
#include <memory>
#include <random>
#include <sstream>
#include <stdexcept>
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
std::string straight(double gain, unsigned rate = 48000) {
    std::string text = "usb16x16-dsp 1\npreset straight\nrate " + std::to_string(rate) +
                       "\nchannels 16\ninternal 16\nmaxdelay " + std::to_string(rate / 100) + "\nexpand 16\n";
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

// SAMPLE_RATE_DESIGN.md, step 3: the owner loads its preset at --rate. 48 kHz
// is the default; an artifact compiled for any other rate is refused before
// anything is opened, and the adapter stays off.
void test_rate_must_match() {
    auto dsp = std::make_unique<OutDsp>();
    dsp->load(straight(1.0));
    check(dsp->enabled() && dsp->stage().rate() == 48000, "the default rate is 48 kHz");
    for (const unsigned other : {44100U, 88200U, 96000U, 176400U, 192000U}) {
        auto refused = std::make_unique<OutDsp>();
        bool threw = false;
        try {
            refused->load(straight(1.0, other), 48000);
        } catch (const std::runtime_error&) {
            threw = true;
        }
        check(threw && !refused->enabled(), "an artifact for another rate is refused at 48 kHz and the stage stays off");
    }
    bool threw = false;
    try {
        dsp->load(straight(1.0), 96000);
    } catch (const std::runtime_error&) {
        threw = true;
    }
    check(threw, "a 48 kHz artifact is refused at 96 kHz");
    auto at96 = std::make_unique<OutDsp>();
    at96->load(straight(1.0, 96000), 96000);
    auto block = noise(48, 9);
    const auto before = block;
    at96->process(block.data(), 48);
    check(at96->stage().rate() == 96000 && block == before, "a 96 kHz artifact at 96 kHz runs, and unity stays bit-exact");
}

// The monitor block after the stage. At its default it is not there at all:
// a transparent preset stays bit-exact, through process() and through the
// three steps the point-of-record owner calls without monitor_gains.
void test_monitor_default_is_bit_exact() {
    auto dsp = std::make_unique<OutDsp>();
    dsp->load(straight(1.0));
    check(dsp->monitor().at_rest_unity(), "the adapter's monitor block starts at rest at unity");
    for (const std::size_t frames : {std::size_t{1}, std::size_t{48}, OutDsp::kMaxFrames}) {
        auto sent = noise(frames, 40 + static_cast<unsigned>(frames));
        const auto kept = sent;
        dsp->process(sent.data(), frames);
        check(sent == kept, "a transparent preset with the default monitor block is bit-exact");
        dsp->take();
        dsp->to_float(sent.data(), frames);
        dsp->filter(frames);
        dsp->from_float(sent.data(), frames);
        check(sent == kept, "the three steps without monitor_gains are bit-exact as before");
    }
}

void test_monitor_gain_scales() {
    auto dsp = std::make_unique<OutDsp>();
    dsp->load(straight(1.0));
    usb16x16::MonitorGains::Targets targets;
    targets.gain.fill(1.0);
    targets.ramp_frames.fill(1);
    targets.gain[0] = 0.5;
    targets.gain[2] = 0.0;
    std::string reason;
    check(dsp->monitor().publish(targets, reason), "a monitor publish through the adapter is accepted");
    dsp->take();
    check(dsp->monitor().generation() == 1, "take() takes the monitor's published set too");
    std::vector<std::int32_t> block(2 * kChannels, top24(4000));
    dsp->process(block.data(), 2);
    check(block[0] == top24(2000) && block[kChannels] == top24(2000), "output 1 at gain 0.5 is halved");
    check(block[2] == 0 && block[kChannels + 2] == 0, "output 3 at gain 0 is silent");
    check(block[1] == top24(4000) && block[kChannels + 15] == top24(4000), "outputs at unity are unchanged");
    bool low_byte_zero = true;
    auto sent = noise(480, 11);
    dsp->process(sent.data(), 480);
    for (const auto sample : sent) low_byte_zero = low_byte_zero && (sample & 0xFF) == 0;
    check(low_byte_zero, "the low byte is zero after a monitor gain");
}

// prime_monitor: with a monitor section a prime takes the published targets
// and rises from silence to them; without one it does nothing, no fade-in.
std::string with_monitor_section(const std::string& artifact) {
    return artifact.substr(0, artifact.size() - 4) +
           "monitor 1\nsets 2\nset mains speakers\nset phones headphones\nouts 3\nout 0 speaker 0\nout 1 speaker 0\n"
           "out 14 speaker 1\nexpandsets 16\n0\n0\n-\n-\n-\n-\n-\n-\n-\n-\n-\n-\n-\n-\n1\n-\nfolds 0\nend\n";
}

void test_prime_monitor() {
    usb16x16::MonitorGains::Targets targets;
    targets.gain.fill(1.0);
    targets.ramp_frames.fill(1);
    targets.gain[0] = 0.5;
    targets.gain[1] = 0.0;
    std::string reason;

    auto plain = std::make_unique<OutDsp>();
    plain->load(straight(1.0));
    plain->prime_monitor(480);
    auto sent = noise(480, 21);
    const auto kept = sent;
    plain->process(sent.data(), 480);
    check(sent == kept, "without a monitor section prime_monitor does nothing: no fade-in, bit-exact");
    check(plain->monitor().publish(targets, reason), "a publish to a plain adapter is accepted");
    plain->prime_monitor(480);
    check(plain->monitor().generation() == 0, "without a section prime_monitor does not even take a publish");

    auto dsp = std::make_unique<OutDsp>();
    dsp->load(with_monitor_section(straight(1.0)));
    check(dsp->stage().has_monitor(), "the fixture has a monitor section");
    check(dsp->monitor().publish(targets, reason), "targets published before the prime");
    dsp->prime_monitor(480);
    check(dsp->monitor().generation() == 1, "the prime takes the published targets");
    std::vector<std::int32_t> block(480 * kChannels, top24(4800));
    dsp->process(block.data(), 480);
    const auto at = [&](std::size_t frame, std::size_t channel) { return block[frame * kChannels + channel] >> 8; };
    check(at(0, 0) == 5 && at(0, 2) == 10 && at(0, 15) == 10, "the first frame after a prime is one step above silence");
    check(at(479, 0) == 2400 && at(479, 2) == 4800, "the last frame of the ramp is at the target");
    bool silent = true;
    bool rising = true;
    for (std::size_t frame = 0; frame < 480; ++frame) {
        silent = silent && at(frame, 1) == 0;
        if (frame > 0) rising = rising && at(frame, 2) >= at(frame - 1, 2);
        rising = rising && at(frame, 2) <= 4800 && at(frame, 0) <= 2400;
    }
    check(silent, "an output whose target is zero stays silent from the first frame");
    check(rising, "nothing plays above its target on the way up");

    auto fresh = std::make_unique<OutDsp>();
    fresh->load(with_monitor_section(straight(1.0)));
    fresh->prime_monitor(48);
    std::vector<std::int32_t> unity(48 * kChannels, top24(4800));
    fresh->process(unity.data(), 48);
    check((unity[0] >> 8) == 100 && (unity[47 * kChannels] >> 8) == 4800 && fresh->monitor().at_rest_unity(),
          "with nothing published a prime rises to unity and comes to rest there");

    // With a fold already requested, the prime snaps it: the rise is folded
    // from its first frame, never a 10 ms crossfade from full. Set 0 folds
    // outputs 0 and 1 to their mono sum (input 0 alone carries signal).
    auto folded = std::make_unique<OutDsp>();
    std::string text = with_monitor_section(straight(1.0));
    text.replace(text.find("folds 0\n"), 8, "folds 1\nfold 0 mono 4\n0 0 0.5\n0 1 0.5\n1 0 0.5\n1 1 0.5\n");
    folded->load(text);
    check(folded->stage().set_fold(0, 1), "the mono fold is requested before the prime");
    folded->prime_monitor(48);
    check(folded->stage().fold(0) == 1 && !folded->stage().fold_crossfading(0), "the prime snaps the fold");
    std::vector<std::int32_t> mono(480 * kChannels, 0);
    for (std::size_t frame = 0; frame < 480; ++frame) mono[frame * kChannels] = top24(4800);
    folded->process(mono.data(), 480);
    bool same = true;
    for (std::size_t frame = 0; frame < 480; ++frame) same = same && mono[frame * kChannels] == mono[frame * kChannels + 1];
    check(same && (mono[0] >> 8) != 0 && (mono[479 * kChannels] >> 8) == 2400,
          "every frame of the rise is folded: outputs 0 and 1 are equal from the first frame");
}

int main(int argc, char** argv) {
    test_unloaded_is_inert();
    test_unity_is_bit_exact();
    test_gain_rounds_and_saturates();
    test_reset_clears_state();
    test_oversized_block_is_refused();
    test_rate_must_match();
    test_monitor_default_is_bit_exact();
    test_monitor_gain_scales();
    test_prime_monitor();
    for (int i = 1; i < argc; ++i) run_artifact(argv[i]);
    std::printf(failures == 0 ? "dsp_path_test: all passed\n" : "dsp_path_test: %d FAILED\n", failures);
    return failures == 0 ? 0 : 1;
}
