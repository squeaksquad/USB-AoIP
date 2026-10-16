// Run the bridge's DSP stage file to file, with no device and no transport.
//
// This exists so the stage can be checked against CamillaDSP on the same
// preset, using the harnesses in `work/dsp-compiler` unchanged: they invoke a
// binary that reads a raw file and writes a raw file, and they do not care
// which binary it is. Agreement between the two is then a measurement rather
// than an argument.
//
// It links only the bridge core, so it builds and runs on the Mac as well as
// the Pi. It opens no ALSA device and touches no service.
//
// One thing to know when reading a comparison: the bridge carries float32
// samples through `playback_scratch`, so this converts to float at the buffer
// boundary exactly as the real path does, even though the filters themselves
// are double. Against an F64 reference the agreement is therefore bounded by
// float32, about 1e-7 relative -- roughly 48 dB below the least significant
// bit of the 24-bit wire, which is where it stops mattering.

#include "usb16x16/bridge_core.hpp"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <numeric>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

namespace {

constexpr std::size_t kChannels = usb16x16::kChannels;

enum class Format { s32le, f64le };

std::size_t bytes_per_sample(const Format format) {
    return format == Format::s32le ? 4 : 8;
}

float decode(const unsigned char* const bytes, const Format format) {
    if (format == Format::s32le) {
        std::int32_t value = 0;
        std::memcpy(&value, bytes, sizeof(value));
        return static_cast<float>(static_cast<double>(value) / 2147483648.0);
    }
    double value = 0.0;
    std::memcpy(&value, bytes, sizeof(value));
    return static_cast<float>(value);
}

void encode(unsigned char* const bytes, const float sample, const Format format) {
    if (format == Format::s32le) {
        // Round first, then clamp in the integer domain. The bridge's own
        // converters were changed to this order in 2026-09-02 after the float
        // path wrapped at positive full scale; the same rule applies here.
        double scaled = static_cast<double>(sample) * 2147483648.0;
        scaled = scaled >= 0.0 ? scaled + 0.5 : scaled - 0.5;
        std::int32_t value;
        if (scaled >= 2147483647.0) {
            value = 2147483647;
        } else if (scaled <= -2147483648.0) {
            value = -2147483647 - 1;
        } else {
            value = static_cast<std::int32_t>(scaled);
        }
        std::memcpy(bytes, &value, sizeof(value));
        return;
    }
    const double value = static_cast<double>(sample);
    std::memcpy(bytes, &value, sizeof(value));
}

int usage() {
    std::cerr <<
        "usage: usb16x16-dsp-offline ARTIFACT --in FILE --out FILE [options]\n"
        "\n"
        "  --format s32le|f64le   sample format of both files (default s32le)\n"
        "  --block N              frames per process() call (default 48)\n"
        "  --bypass               load the artifact but do not run it\n"
        "  --rate HZ              the rate the artifact must be compiled for (default 48000)\n"
        "  --bench N              time N process() calls in memory and exit\n"
        "  --shape                print the shape key and canonical shape, then exit\n"
        "  --swap-at FRAME FILE   publish FILE's coefficients at the first block\n"
        "                         boundary at or after FRAME (same shape required)\n";
    return 2;
}

// What one process() call costs, at the block size the caller asks for.
//
// No file, no device, no transport: just the arithmetic, on a buffer already
// in cache. That makes it an underestimate of what the audio thread pays and
// the right number for the question it answers, which is whether the stage can
// fit in a cycle at all. The maximum is the figure that decides that; a mean
// hides exactly the cycle that would have missed.
int benchmark(usb16x16::DspStage& stage, const std::size_t block, const std::size_t runs) {
    std::vector<float> buffer(block * kChannels);
    // Real signal rather than silence: an IIR fed zeros settles into denormals,
    // and the cost measured would be the denormal handling.
    for (std::size_t frame = 0; frame < block; ++frame) {
        for (std::size_t channel = 0; channel < kChannels; ++channel) {
            buffer[frame * kChannels + channel] = static_cast<float>(
                0.25 * std::sin(2.0 * M_PI * (55.0 * static_cast<double>(channel + 1)) *
                                static_cast<double>(frame) / 48000.0));
        }
    }
    std::vector<double> spent;
    spent.reserve(runs);
    for (std::size_t run = 0; run < runs; ++run) {
        const auto started = std::chrono::steady_clock::now();
        stage.process(buffer.data(), block);
        const auto finished = std::chrono::steady_clock::now();
        spent.push_back(std::chrono::duration<double, std::micro>(finished - started).count());
    }
    std::sort(spent.begin(), spent.end());
    const double total = std::accumulate(spent.begin(), spent.end(), 0.0);
    const double audio_us = static_cast<double>(block) / 48.0 * 1000.0;
    std::cout << "{\"block\":" << block
              << ",\"runs\":" << runs
              << ",\"audio_us\":" << audio_us
              << ",\"min_us\":" << spent.front()
              << ",\"median_us\":" << spent[spent.size() / 2]
              << ",\"p99_us\":" << spent[static_cast<std::size_t>(
                     static_cast<double>(spent.size()) * 0.99)]
              << ",\"max_us\":" << spent.back()
              << ",\"mean_us\":" << total / static_cast<double>(runs)
              // The share of one cycle the stage would take at this block size.
              << ",\"duty_median\":" << spent[spent.size() / 2] / audio_us
              << ",\"duty_max\":" << spent.back() / audio_us
              << "}\n";
    return 0;
}

}  // namespace

int main(const int argc, char** const argv) {
    std::string artifact_path;
    std::string input_path;
    std::string output_path;
    Format format = Format::s32le;
    std::size_t block = 48;
    std::size_t bench = 0;
    bool bypass = false;
    unsigned rate = 48000;
    bool shape_only = false;
    bool swap = false;
    std::size_t swap_frame = 0;
    std::string swap_path;

    for (int index = 1; index < argc; ++index) {
        const std::string argument = argv[index];
        const auto take = [&]() -> std::string {
            if (index + 1 >= argc) {
                std::cerr << argument << " needs a value\n";
                std::exit(2);
            }
            return argv[++index];
        };
        if (argument == "--in") input_path = take();
        else if (argument == "--out") output_path = take();
        else if (argument == "--block") block = std::stoul(take());
        else if (argument == "--bypass") bypass = true;
        else if (argument == "--rate") rate = static_cast<unsigned>(std::stoul(take()));
        else if (argument == "--bench") bench = std::stoul(take());
        else if (argument == "--shape") shape_only = true;
        else if (argument == "--swap-at") { swap = true; swap_frame = std::stoul(take()); swap_path = take(); }
        else if (argument == "--format") {
            const std::string value = take();
            if (value == "s32le") format = Format::s32le;
            else if (value == "f64le") format = Format::f64le;
            else { std::cerr << "unknown format " << value << '\n'; return 2; }
        } else if (argument == "-h" || argument == "--help") return usage();
        else if (!argument.empty() && argument.front() == '-') return usage();
        else artifact_path = argument;
    }
    if (artifact_path.empty()) return usage();
    if (bench == 0 && !shape_only && (input_path.empty() || output_path.empty())) return usage();
    if (block == 0) { std::cerr << "--block must be positive\n"; return 2; }

    std::ifstream artifact_file(artifact_path, std::ios::binary);
    if (!artifact_file) {
        std::cerr << "cannot read " << artifact_path << '\n';
        return 3;
    }
    std::ostringstream artifact_text;
    artifact_text << artifact_file.rdbuf();

    usb16x16::DspStage stage;
    try {
        stage = usb16x16::DspStage::load(artifact_text.str(), rate);
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 4;
    }
    if (shape_only) {
        std::cout << "shape_key=" << stage.shape_key() << '\n' << stage.shape();
        return 0;
    }
    usb16x16::DspStage update;
    if (swap) {
        std::ifstream update_file(swap_path, std::ios::binary);
        if (!update_file) { std::cerr << "cannot read " << swap_path << '\n'; return 3; }
        std::ostringstream update_text;
        update_text << update_file.rdbuf();
        try {
            update = usb16x16::DspStage::load(update_text.str(), rate);
        } catch (const std::exception& error) {
            std::cerr << swap_path << ": " << error.what() << '\n';
            return 4;
        }
        if (update.shape_key() != stage.shape_key()) {
            std::cerr << "swap refused: " << swap_path << " has shape " << update.shape_key()
                      << ", the loaded artifact " << stage.shape_key() << '\n';
            return 5;
        }
    }
    std::cerr << "preset=\"" << stage.preset() << "\""
              << " internal=" << stage.internal_channels()
              << " biquads=" << stage.biquad_count()
              << " delay=" << stage.delay_samples() << " samples"
              << " block=" << block
              << (bypass ? " BYPASSED" : "") << '\n';

    if (bench > 0) {
        return benchmark(stage, block, bench);
    }

    std::ifstream input(input_path, std::ios::binary);
    if (!input) { std::cerr << "cannot read " << input_path << '\n'; return 3; }
    std::ofstream output(output_path, std::ios::binary);
    if (!output) { std::cerr << "cannot write " << output_path << '\n'; return 3; }

    const std::size_t width = bytes_per_sample(format);
    std::vector<unsigned char> raw(block * kChannels * width);
    std::vector<float> samples(block * kChannels);
    std::uint64_t frames_done = 0;

    while (input) {
        input.read(reinterpret_cast<char*>(raw.data()), static_cast<std::streamsize>(raw.size()));
        const std::size_t read_bytes = static_cast<std::size_t>(input.gcount());
        const std::size_t frames = read_bytes / (kChannels * width);
        if (frames == 0) break;
        for (std::size_t index = 0; index < frames * kChannels; ++index) {
            samples[index] = decode(raw.data() + index * width, format);
        }
        if (swap && frames_done >= swap_frame) {
            // The first block boundary at or after the frame, once.
            std::string reason;
            if (stage.publish(update, reason)) {
                std::cerr << "DSPLIVE published at frame " << frames_done
                          << " preset=\"" << update.preset() << "\"" << '\n';
            } else {
                std::cerr << "DSPLIVE refused at frame " << frames_done << ": " << reason << '\n';
                return 5;
            }
            swap = false;
        }
        if (!bypass) {
            stage.process(samples.data(), frames);
        }
        for (std::size_t index = 0; index < frames * kChannels; ++index) {
            encode(raw.data() + index * width, samples[index], format);
        }
        output.write(reinterpret_cast<const char*>(raw.data()),
                     static_cast<std::streamsize>(frames * kChannels * width));
        frames_done += frames;
    }
    output.flush();
    std::cerr << "frames=" << frames_done << '\n';
    return 0;
}
