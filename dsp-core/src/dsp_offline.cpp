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
//
// The monitor block (MonitorGains) runs after the stage, as it does in the
// owner. Without --monitor-script it stays at its default, every gain 1 and
// nothing ramping, and does not touch the samples: the output is what it was
// before the block existed. With a script, the run is split so that a block
// boundary falls exactly on each event's frame, so the result does not
// depend on --block.

#include "usb16x16/bridge_core.hpp"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <limits>
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
        "                         boundary at or after FRAME (same shape required)\n"
        "  --monitor-script FILE  drive the monitor block from FILE, one event a line:\n"
        "                           FRAME ramp=N gains=G1,...,G16   publish these targets\n"
        "                           FRAME silence ramp=N            start_from_silence(N)\n"
        "                         FRAME is the 0-based input frame the event takes\n"
        "                         effect at, never decreasing; '#' starts a comment.\n"
        "                         The monitor runs after the stage, also with --bypass\n"
        "  --bench-monitor GAIN   with --bench: also run the monitor block with every\n"
        "                         output at GAIN (at rest), inside the timed call\n";
    return 2;
}

struct MonitorEvent {
    std::uint64_t frame{};
    std::size_t line{};
    bool silence{};
    usb16x16::MonitorGains::Targets targets{};
    std::uint32_t ramp{};
};

// The whole of `text` as an unsigned integer, or false.
bool parse_unsigned(const std::string& text, std::uint64_t& value) {
    if (text.empty() || text.find_first_not_of("0123456789") != std::string::npos) return false;
    try {
        value = std::stoull(text);
    } catch (const std::exception&) {
        return false;
    }
    return true;
}

bool parse_double(const std::string& text, double& value) {
    if (text.empty()) return false;
    std::size_t used = 0;
    try {
        value = std::stod(text, &used);
    } catch (const std::exception&) {
        return false;
    }
    return used == text.size();
}

// Reads the script, or prints what is wrong with it (file and line) and
// returns false. Gains are checked here by the same rule publish() applies,
// so a script the runner accepts never has an event refused mid-run.
bool read_monitor_script(const std::string& path, std::vector<MonitorEvent>& events) {
    std::ifstream file(path);
    if (!file) {
        std::cerr << "cannot read " << path << '\n';
        return false;
    }
    std::string line;
    std::size_t number = 0;
    const auto refuse = [&](const std::string& why) {
        std::cerr << path << ':' << number << ": " << why << '\n';
        return false;
    };
    while (std::getline(file, line)) {
        ++number;
        const std::size_t hash = line.find('#');
        if (hash != std::string::npos) line.erase(hash);
        std::istringstream words(line);
        std::vector<std::string> fields;
        for (std::string word; words >> word;) fields.push_back(word);
        if (fields.empty()) continue;
        MonitorEvent event;
        event.line = number;
        if (!parse_unsigned(fields[0], event.frame)) return refuse("the first field must be a frame number");
        if (!events.empty() && event.frame < events.back().frame) {
            return refuse("frame " + fields[0] + " is before the previous event's");
        }
        std::size_t next = 1;
        if (next < fields.size() && fields[next] == "silence") {
            event.silence = true;
            ++next;
        }
        if (next >= fields.size() || fields[next].rfind("ramp=", 0) != 0) return refuse("expected ramp=N");
        std::uint64_t ramp = 0;
        if (!parse_unsigned(fields[next].substr(5), ramp) || ramp > std::numeric_limits<std::uint32_t>::max()) {
            return refuse("ramp must be a whole number of frames that fits 32 bits");
        }
        event.ramp = static_cast<std::uint32_t>(ramp);
        event.targets.ramp_frames.fill(event.ramp);
        ++next;
        if (!event.silence) {
            if (next >= fields.size() || fields[next].rfind("gains=", 0) != 0) return refuse("expected gains=G1,...,G16");
            const std::string list = fields[next].substr(6) + ",";
            std::size_t channel = 0;
            std::size_t start = 0;
            for (std::size_t comma = list.find(','); comma != std::string::npos; comma = list.find(',', start)) {
                double gain = 0.0;
                if (channel >= kChannels) return refuse("more than 16 gains");
                if (!parse_double(list.substr(start, comma - start), gain)) {
                    return refuse("gain " + std::to_string(channel + 1) + " is not a number");
                }
                if (!(std::isfinite(gain) && gain >= 0.0 && gain <= 1.0)) {
                    return refuse("gain " + std::to_string(channel + 1) + " is not a finite value in [0, 1]");
                }
                event.targets.gain[channel++] = gain;
                start = comma + 1;
            }
            if (channel != kChannels) return refuse("expected 16 gains, found " + std::to_string(channel));
            ++next;
        }
        if (next != fields.size()) return refuse("unexpected '" + fields[next] + "'");
        events.push_back(event);
    }
    return true;
}

// What one process() call costs, at the block size the caller asks for.
//
// No file, no device, no transport: just the arithmetic, on a buffer already
// in cache. That makes it an underestimate of what the audio thread pays and
// the right number for the question it answers, which is whether the stage can
// fit in a cycle at all. The maximum is the figure that decides that; a mean
// hides exactly the cycle that would have missed.
int benchmark(usb16x16::DspStage& stage, usb16x16::MonitorGains* const monitor,
              const std::size_t block, const std::size_t runs, const unsigned rate) {
    std::vector<float> buffer(block * kChannels);
    // Real signal rather than silence: an IIR fed zeros settles into denormals,
    // and the cost measured would be the denormal handling.
    for (std::size_t frame = 0; frame < block; ++frame) {
        for (std::size_t channel = 0; channel < kChannels; ++channel) {
            buffer[frame * kChannels + channel] = static_cast<float>(
                0.25 * std::sin(2.0 * M_PI * (55.0 * static_cast<double>(channel + 1)) *
                                static_cast<double>(frame) / static_cast<double>(rate)));
        }
    }
    std::vector<double> spent;
    spent.reserve(runs);
    for (std::size_t run = 0; run < runs; ++run) {
        const auto started = std::chrono::steady_clock::now();
        stage.process(buffer.data(), block);
        if (monitor != nullptr) monitor->process(buffer.data(), block);
        const auto finished = std::chrono::steady_clock::now();
        spent.push_back(std::chrono::duration<double, std::micro>(finished - started).count());
    }
    std::sort(spent.begin(), spent.end());
    const double total = std::accumulate(spent.begin(), spent.end(), 0.0);
    const double audio_us = static_cast<double>(block) / static_cast<double>(rate) * 1.0e6;
    std::cout << "{\"rate\":" << rate << ",\"block\":" << block
              << ",\"monitor\":" << (monitor != nullptr ? "true" : "false")
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
    std::string monitor_path;
    bool bench_monitor = false;
    double bench_gain = 1.0;

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
        else if (argument == "--monitor-script") monitor_path = take();
        else if (argument == "--bench-monitor") { bench_monitor = true; bench_gain = std::stod(take()); }
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
    std::vector<MonitorEvent> events;
    if (!monitor_path.empty() && !read_monitor_script(monitor_path, events)) return 6;

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

    usb16x16::MonitorGains monitor;
    if (bench > 0) {
        if (!bench_monitor) return benchmark(stage, nullptr, block, bench, rate);
        usb16x16::MonitorGains::Targets targets;
        targets.gain.fill(bench_gain);
        targets.ramp_frames.fill(1);
        std::string reason;
        if (!monitor.publish(targets, reason)) {
            std::cerr << "--bench-monitor: " << reason << '\n';
            return 2;
        }
        monitor.process(nullptr, 0);
        return benchmark(stage, &monitor, block, bench, rate);
    }

    std::ifstream input(input_path, std::ios::binary);
    if (!input) { std::cerr << "cannot read " << input_path << '\n'; return 3; }
    std::ofstream output(output_path, std::ios::binary);
    if (!output) { std::cerr << "cannot write " << output_path << '\n'; return 3; }

    const std::size_t width = bytes_per_sample(format);
    std::vector<unsigned char> raw(block * kChannels * width);
    std::vector<float> samples(block * kChannels);
    std::uint64_t frames_done = 0;
    std::size_t next_event = 0;

    while (input) {
        // Every event due at this frame, in file order. Each publish is taken
        // at once (a zero-frame process), as it would be at the top of the
        // next block, so several events on one frame apply in turn.
        while (next_event < events.size() && events[next_event].frame == frames_done) {
            const MonitorEvent& event = events[next_event++];
            if (event.silence) {
                monitor.start_from_silence(event.ramp);
            } else {
                std::string reason;
                if (!monitor.publish(event.targets, reason)) {
                    std::cerr << monitor_path << ':' << event.line << ": refused: " << reason << '\n';
                    return 6;
                }
                monitor.process(nullptr, 0);
            }
        }
        // A block boundary on the next event's frame.
        std::size_t want = block;
        if (next_event < events.size()) {
            want = static_cast<std::size_t>(std::min<std::uint64_t>(want, events[next_event].frame - frames_done));
        }
        input.read(reinterpret_cast<char*>(raw.data()),
                   static_cast<std::streamsize>(want * kChannels * width));
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
        monitor.process(samples.data(), frames);
        for (std::size_t index = 0; index < frames * kChannels; ++index) {
            encode(raw.data() + index * width, samples[index], format);
        }
        output.write(reinterpret_cast<const char*>(raw.data()),
                     static_cast<std::streamsize>(frames * kChannels * width));
        frames_done += frames;
    }
    output.flush();
    std::cerr << "frames=" << frames_done << '\n';
    if (next_event < events.size()) {
        std::cerr << monitor_path << ':' << events[next_event].line << ": event at frame "
                  << events[next_event].frame << " is past the end of the input\n";
        return 6;
    }
    if (!events.empty()) std::cerr << "MONITOR events=" << events.size() << '\n';
    return 0;
}
