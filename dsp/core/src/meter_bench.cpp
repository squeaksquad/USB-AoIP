// Benchmark the level meter tap in memory: what LevelMeter::observe() costs
// on one block, which is what the audio thread pays per direction per cycle
// (twice, capture and playback). Links the core only, so it runs on the Mac
// for the shape of the answer and on the Pi for the figure that matters.
//
// The buffer is hot in cache and the loop is not preempted, so this is the
// floor; the bridge's own meter_us_max on the BRIDGE line is the ceiling.

#include "usb16x16/bridge_core.hpp"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstddef>
#include <cstdlib>
#include <iostream>
#include <numeric>
#include <string>
#include <vector>

int main(const int argc, char** const argv) {
    std::size_t block = 48;
    std::size_t runs = 200000;
    for (int index = 1; index < argc; ++index) {
        const std::string argument = argv[index];
        if (argument == "--block" && index + 1 < argc) {
            block = std::stoul(argv[++index]);
        } else if (argument == "--runs" && index + 1 < argc) {
            runs = std::stoul(argv[++index]);
        } else {
            std::cerr << "usage: usb16x16-meter-bench [--block FRAMES] [--runs N]\n";
            return 2;
        }
    }
    if (block == 0 || runs == 0) {
        std::cerr << "--block and --runs must be positive\n";
        return 2;
    }
    std::vector<float> buffer(block * usb16x16::kChannels);
    for (std::size_t frame = 0; frame < block; ++frame) {
        for (std::size_t channel = 0; channel < usb16x16::kChannels; ++channel) {
            buffer[frame * usb16x16::kChannels + channel] = static_cast<float>(
                0.5 * std::sin(2.0 * M_PI * (55.0 * static_cast<double>(channel + 1)) *
                               static_cast<double>(frame) / 48000.0));
        }
    }
    usb16x16::LevelMeter meter;
    std::vector<double> spent;
    spent.reserve(runs);
    for (std::size_t run = 0; run < runs; ++run) {
        const auto started = std::chrono::steady_clock::now();
        meter.observe(buffer.data(), block);
        const auto finished = std::chrono::steady_clock::now();
        spent.push_back(std::chrono::duration<double, std::micro>(finished - started).count());
    }
    usb16x16::LevelMeter::Snapshot snapshot;
    const bool published = meter.read(snapshot);
    std::sort(spent.begin(), spent.end());
    const double total = std::accumulate(spent.begin(), spent.end(), 0.0);
    const double audio_us = static_cast<double>(block) / 48.0 * 1000.0;
    std::cout << "{\"block\":" << block
              << ",\"runs\":" << runs
              << ",\"audio_us\":" << audio_us
              << ",\"min_us\":" << spent.front()
              << ",\"median_us\":" << spent[spent.size() / 2]
              << ",\"p99_us\":" << spent[static_cast<std::size_t>(static_cast<double>(spent.size()) * 0.99)]
              << ",\"max_us\":" << spent.back()
              << ",\"mean_us\":" << total / static_cast<double>(runs)
              << ",\"duty_median\":" << spent[spent.size() / 2] / audio_us
              << ",\"duty_max\":" << spent.back() / audio_us
              << ",\"windows\":" << (published ? snapshot.sequence : 0)
              << ",\"peak_dbfs_ch0\":" << (published ? usb16x16::amplitude_to_dbfs(snapshot.peak[0]) : 0.0)
              << "}\n";
    return 0;
}
