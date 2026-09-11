// Offline diagnosis only: links the actual DSP core, opens no audio device.
// Build/run commands and model limits are in README.md (Loaded zero-run replay).
#include "usb16x16/bridge_core.hpp"

#include <array>
#include <bit>
#include <cmath>
#include <cstdint>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

namespace {
constexpr std::size_t channels = 16;
constexpr std::size_t warmup = 96000;

// Swift DeterministicChannelLoad: UInt32 wrap, signed bit-pattern conversion,
// Float32 division/multiplication, one shared state across interleaved channels.
float noise(std::uint32_t& state) {
    state ^= state << 13;
    state ^= state >> 17;
    state ^= state << 5;
    const float normalized = static_cast<float>(std::bit_cast<std::int32_t>(state)) /
                             static_cast<float>(INT32_MAX);
    return std::clamp(normalized, -1.0F, 1.0F) * 0.1F;
}

float s24_round(float value) {
    std::uint8_t bytes[3];
    usb16x16::float_to_s24(value, bytes);
    return usb16x16::s24_to_float(bytes);
}

// MTConvertMappedInt32ToBigEndianInt24Interleave copies the high three bytes
// of S32. Dropping the low byte rounds negative values down, not toward zero.
float wire24(float value) {
    return static_cast<float>(usb16x16::float_to_s32(value) >> 8) / 8388608.0F;
}

struct Stats {
    std::size_t samples{}, zeros{}, run{}, longest{}, longest_start{}, runs_ge4{}, invalid{};
    double peak{}, squares{};
    void observe(float value, std::size_t frame) {
        ++samples;
        if (!std::isfinite(value)) { ++invalid; run = 0; return; }
        peak = std::max(peak, std::abs(static_cast<double>(value)));
        squares += static_cast<double>(value) * value;
        if (value == 0) {
            ++zeros; ++run;
            if (run == 4) ++runs_ge4;
            if (run > longest) { longest = run; longest_start = frame + 1 - run; }
        } else { run = 0; }
    }
    void json() const {
        std::cout << "{\"samples\":" << samples << ",\"zeros\":" << zeros
                  << ",\"longestZeroRun\":" << longest
                  << ",\"longestStartFrame\":";
        if (longest) std::cout << longest_start; else std::cout << "null";
        std::cout << ",\"runsAtLeast4\":" << runs_ge4 << ",\"nonFinite\":" << invalid
                  << ",\"peak\":" << peak << ",\"rms\":"
                  << (samples ? std::sqrt(squares / samples) : 0) << '}';
    }
};

struct Sample { std::size_t frame; float dsp; float wire; };
struct Event {
    std::size_t start, length;
    std::vector<Sample> neighborhood;
};
} // namespace

int main(int argc, char** argv) {
    try {
        if (argc != 4 || (std::string(argv[3]) != "float" && std::string(argv[3]) != "s24")) {
            std::cerr << "usage: replay-loaded ARTIFACT SECONDS float|s24\n";
            return 2;
        }
        std::size_t used = 0;
        const std::string duration = argv[2];
        const int seconds = std::stoi(duration, &used);
        if (used != duration.size() || seconds < 3 || seconds > 600)
            throw std::runtime_error("seconds must be 3..600");
        const bool quantize_input = std::string(argv[3]) == "s24";
        std::ifstream artifact(argv[1]);
        if (!artifact) throw std::runtime_error("cannot read artifact");
        std::ostringstream contents;
        contents << artifact.rdbuf();
        auto stage = usb16x16::DspStage::load(contents.str());
        std::array<std::array<Stats, channels>, 3> stats{};
        std::array<float, 48 * channels> block{};
        std::array<Sample, 64> history{};
        std::vector<Event> events;
        constexpr std::size_t event_limit = 32;
        std::size_t event_count = 0;
        std::uint32_t state = 0x9e3779b9;
        const std::size_t frames = static_cast<std::size_t>(seconds) * 48000;
        for (std::size_t base = 0; base < frames; base += 48) {
            for (auto& sample : block) {
                sample = noise(state);
                if (quantize_input) sample = s24_round(sample);
            }
            stage.process(block.data(), 48);
            for (std::size_t i = 0; i < 48; ++i) {
                const std::size_t frame = base + i;
                const float ch4 = block[i * channels + 3];
                const float wire = wire24(ch4);
                history[frame % history.size()] = {frame, ch4, wire};
                if (frame < warmup) continue;
                const std::size_t ended_run = stats[1][3].run;
                if (wire != 0 && ended_run >= 4) {
                    ++event_count;
                    if (events.size() < event_limit) {
                        Event event{frame - ended_run, ended_run, {}};
                        // Eight samples before, the run, and its first nonzero
                        // successor; cap at 64 if a long interruption occurs.
                        const auto begin = frame + 1 - std::min(ended_run + 9, history.size());
                        for (auto f = begin; f <= frame; ++f)
                            event.neighborhood.push_back(history[f % history.size()]);
                        events.push_back(event);
                    }
                }
                for (std::size_t channel = 0; channel < channels; ++channel) {
                    const float value = block[i * channels + channel];
                    stats[0][channel].observe(value, frame);
                    stats[1][channel].observe(wire24(value), frame);
                    stats[2][channel].observe(s24_round(value), frame);
                }
            }
        }
        std::cout << std::setprecision(17)
                  << "{\"kind\":\"offline-filter-conversion-diagnosis\",\"seconds\":" << seconds
                  << ",\"warmupFrames\":" << warmup << ",\"blockFrames\":48"
                  << ",\"inputConversion\":\"" << (quantize_input ? "s24-nearest" : "float32")
                  << "\",\"biquads\":" << stage.biquad_count()
                  << ",\"seed\":2654435769,\"stimulusFirst32Bits\":[";
        state = 0x9e3779b9;
        for (int i = 0; i < 32; ++i) {
            if (i) std::cout << ',';
            std::cout << std::bit_cast<std::uint32_t>(noise(state));
        }
        std::cout << "],\"channels\":[";
        for (std::size_t channel = 0; channel < channels; ++channel) {
            if (channel) std::cout << ',';
            std::cout << "{\"channel\":" << channel + 1 << ",\"dspFloat\":";
            stats[0][channel].json();
            std::cout << ",\"s32ToWire24\":"; stats[1][channel].json();
            std::cout << ",\"nearest24Comparison\":"; stats[2][channel].json();
            std::cout << '}';
        }
        std::cout << "],\"channel4CompletedEvents\":" << event_count
                  << ",\"channel4TrailingZeroRun\":" << stats[1][3].run
                  << ",\"channel4EventLimit\":" << event_limit << ",\"channel4Events\":[";
        for (std::size_t e = 0; e < events.size(); ++e) {
            if (e) std::cout << ',';
            const auto& event = events[e];
            std::cout << "{\"startFrame\":" << event.start << ",\"length\":" << event.length
                      << ",\"samples\":[";
            for (std::size_t i = 0; i < event.neighborhood.size(); ++i) {
                if (i) std::cout << ',';
                const auto& sample = event.neighborhood[i];
                std::cout << "{\"frame\":" << sample.frame << ",\"dspFloat\":" << sample.dsp
                          << ",\"wire24\":" << sample.wire << '}';
            }
            std::cout << "]}";
        }
        std::cout << "]}\n";
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
