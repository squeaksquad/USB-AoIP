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

#include <cstdint>
#include <cstring>
#include <fstream>
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
        "  --bypass               load the artifact but do not run it\n";
    return 2;
}

}  // namespace

int main(const int argc, char** const argv) {
    std::string artifact_path;
    std::string input_path;
    std::string output_path;
    Format format = Format::s32le;
    std::size_t block = 48;
    bool bypass = false;

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
        else if (argument == "--format") {
            const std::string value = take();
            if (value == "s32le") format = Format::s32le;
            else if (value == "f64le") format = Format::f64le;
            else { std::cerr << "unknown format " << value << '\n'; return 2; }
        } else if (argument == "-h" || argument == "--help") return usage();
        else if (!argument.empty() && argument.front() == '-') return usage();
        else artifact_path = argument;
    }
    if (artifact_path.empty() || input_path.empty() || output_path.empty()) return usage();
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
        stage = usb16x16::DspStage::load(artifact_text.str());
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 4;
    }
    std::cerr << "preset=\"" << stage.preset() << "\""
              << " internal=" << stage.internal_channels()
              << " biquads=" << stage.biquad_count()
              << " delay=" << stage.delay_samples() << " samples"
              << " block=" << block
              << (bypass ? " BYPASSED" : "") << '\n';

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
