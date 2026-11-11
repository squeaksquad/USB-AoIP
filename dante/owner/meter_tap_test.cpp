// Mac-side test of the owner's meter taps and their publisher.
//   c++ -std=c++20 -O2 -Wall -Wextra -Wpedantic -Werror -I ../../phase4-bridge/include
//       -o /tmp/meter_tap_test meter_tap_test.cpp ../../phase4-bridge/src/bridge_core.cpp && /tmp/meter_tap_test
// (one line)
#include "dsp_path.hpp"
#include "meter_tap.hpp"

#include <cstdio>
#include <cstdlib>
#include <memory>
#include <string>
#include <vector>

using usb16x16::owner::MeterPublisher;
using usb16x16::owner::OutDsp;
using usb16x16::owner::OwnerMeters;

namespace {

int failures = 0;

void check(bool condition, const char* message) {
    if (!condition) {
        std::printf("FAIL: %s\n", message);
        ++failures;
    }
}

constexpr std::size_t kChannels = usb16x16::kChannels;

std::int32_t top24(std::int32_t value24) { return static_cast<std::int32_t>(static_cast<std::uint32_t>(value24) << 8); }

std::string slurp(const std::string& path) {
    std::FILE* file = std::fopen(path.c_str(), "rb");
    if (file == nullptr) return {};
    std::string text(8192, '\0');
    text.resize(std::fread(text.data(), 1, text.size(), file));
    std::fclose(file);
    return text;
}

bool has(const std::string& text, const char* part) { return text.find(part) != std::string::npos; }

std::string straight(double gain) {
    std::string text = "usb16x16-dsp 1\npreset straight\nrate 48000\nchannels 16\ninternal 16\nmaxdelay 480\nexpand 16\n";
    for (std::size_t c = 0; c < kChannels; ++c) text += std::to_string(c) + " " + std::to_string(c) + " " + std::to_string(gain) + "\n";
    text += "branch 0\nassign 16\n";
    for (std::size_t c = 0; c < kChannels; ++c) text += std::to_string(c) + " " + std::to_string(c) + " 1\n";
    text += "output 16\n";
    for (std::size_t c = 0; c < kChannels; ++c) text += std::to_string(c) + " 0 1 0\n";
    return text + "end\n";
}

// A block with channel 1 at half scale and channel 2 at a quarter, the rest silent.
std::vector<std::int32_t> block_of(std::size_t frames) {
    std::vector<std::int32_t> block(frames * kChannels, 0);
    for (std::size_t frame = 0; frame < frames; ++frame) {
        block[frame * kChannels] = top24(frame % 2 ? 4194304 : -4194304);
        block[frame * kChannels + 1] = top24(2097152);
    }
    return block;
}

void test_levels_and_file(const std::string& directory) {
    const std::string path = directory + "/meters.txt";
    auto meters = std::make_unique<OwnerMeters>();
    MeterPublisher publisher(*meters, path);
    check(!publisher.poll(), "nothing is written before a window closes");
    check(slurp(path).empty(), "and no file appears");

    // Direct: one conversion, both outgoing taps. 50 blocks of 48 frames is exactly one 2400-frame window.
    const auto block = block_of(48);
    for (int n = 0; n < 49; ++n) meters->observe(block.data(), 48, meters->usb_capture, &meters->dante_playback);
    check(!publisher.poll(), "a window that has not closed is not written");
    meters->observe(block.data(), 48, meters->usb_capture, &meters->dante_playback);
    check(publisher.poll(), "the closed window is written");
    const std::string text = slurp(path);
    check(has(text, "METERS v=1 ") && has(text, "window_frames=2400") && has(text, "writes=1"), "the header is the bridge's");
    check(has(text, "TAP stage=usb-capture seq=1 frames=2400 position=2400 peak_dbfs=-6.0,-12.0,-144.0"),
          "usb-capture reads half and quarter scale as -6.0 and -12.0 dBFS peak");
    check(has(text, "rms_dbfs=-6.0,-12.0,-144.0"), "and the same RMS for a square wave and a constant");
    check(has(text, "TAP stage=dante-playback seq=1 frames=2400"), "dante-playback closed the same window");
    check(has(text, "TAP stage=dante-capture seq=0 frames=0"), "a tap with nothing yet is listed with nothing");
    check(!publisher.poll(), "an unchanged set of windows is not written again");

    for (int n = 0; n < 50; ++n) meters->observe(block.data(), 48, meters->dante_capture);
    check(publisher.poll() && has(slurp(path), "TAP stage=dante-capture seq=1 frames=2400"), "the return tap publishes on its own");
    check(publisher.writes() == 2 && publisher.failures() == 0, "two writes, none failed");

    auto untouched = block_of(OwnerMeters::kMaxFrames + 1);
    meters->observe(untouched.data(), OwnerMeters::kMaxFrames + 1, meters->dante_capture);
    check(!publisher.poll(), "a block longer than the scratch is not observed");
}

void test_through_the_stage(const std::string& directory) {
    // The caller's sequence in main.cpp: to_float, meter, filter, meter, from_float.
    const std::string path = directory + "/stage.txt";
    auto meters = std::make_unique<OwnerMeters>();
    auto dsp = std::make_unique<OutDsp>();
    dsp->load(straight(4.0));
    MeterPublisher publisher(*meters, path);
    auto block = block_of(48);
    for (int n = 0; n < 50; ++n) {
        block = block_of(48);
        check(dsp->ready(48), "the stage is ready for an ordinary block");
        dsp->to_float(block.data(), 48);
        meters->usb_capture.observe(dsp->floats(), 48);
        dsp->filter(48);
        meters->dante_playback.observe(dsp->floats(), 48);
        dsp->from_float(block.data(), 48);
    }
    check(block[0] == top24(-8388608) && block[1] == top24(8388607), "the stepwise path saturates as process() does");
    check(publisher.poll(), "both taps closed a window");
    const std::string text = slurp(path);
    check(has(text, "TAP stage=usb-capture seq=1 frames=2400 position=2400 peak_dbfs=-6.0,-12.0"), "the input tap is before the gain");
    check(has(text, "TAP stage=dante-playback seq=1 frames=2400 position=2400 peak_dbfs=6.0,0.0"), "the output tap is after it");
    // Channel 1 at +/-2.0 clips every sample; channel 2 at exactly +1.0 counts as well.
    check(has(text, "clip=2400,2400,0,"), "the output tap counts what the converter will have to clamp");
    check(has(text, "stage=usb-capture") && has(text.substr(0, text.find("TAP stage=dante-playback")), "clip=0,0,0,"),
          "and the input tap counts none");
}

// SAMPLE_RATE_DESIGN.md, step 3: windows are 50 ms at the owner's rate.
void test_window_follows_the_rate(const std::string& directory) {
    check(OwnerMeters().usb_capture.window_frames() == 2400, "the default is 50 ms at 48 kHz, the bridge's 2400");
    check(OwnerMeters(48000).dante_capture.window_frames() == 2400, "48 kHz given is the same");
    check(OwnerMeters(44100).dante_playback.window_frames() == 2205, "50 ms at 44.1 kHz is 2205 frames");
    auto meters = std::make_unique<OwnerMeters>(96000);
    MeterPublisher publisher(*meters, directory + "/meters96.txt");
    const auto block = block_of(48);
    for (int n = 0; n < 50; ++n) meters->observe(block.data(), 48, meters->usb_capture);
    check(!publisher.poll(), "at 96 kHz, 2400 frames is half a window");
    for (int n = 0; n < 50; ++n) meters->observe(block.data(), 48, meters->usb_capture);
    check(publisher.poll(), "and 4800 frames closes it");
    check(has(slurp(directory + "/meters96.txt"), "window_frames=4800"), "the file says the window it was measured over");
}

void test_unwritable() {
    auto meters = std::make_unique<OwnerMeters>();
    MeterPublisher publisher(*meters, "/nonexistent-directory/meters.txt");
    const auto block = block_of(48);
    for (int n = 0; n < 50; ++n) meters->observe(block.data(), 48, meters->usb_capture);
    check(publisher.poll() && publisher.failures() == 1, "a file that cannot be written is counted, not fatal");
}

}  // namespace

int main() {
    char pattern[] = "/tmp/meter-tap-test-XXXXXX";
    const char* directory = mkdtemp(pattern);
    if (directory == nullptr) {
        std::printf("FAIL: no temporary directory\n");
        return 1;
    }
    test_levels_and_file(directory);
    test_through_the_stage(directory);
    test_window_follows_the_rate(directory);
    test_unwritable();
    std::printf(failures == 0 ? "meter_tap_test: all passed\n" : "meter_tap_test: %d FAILED\n", failures);
    return failures == 0 ? 0 : 1;
}
