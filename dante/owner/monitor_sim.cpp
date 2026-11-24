// monitor_sim: the Dante owner's monitor block without ALSA, for end-to-end
// checks on the Mac against the real web service and the page. Not installed.
//
// It loads an artifact into the owner's OutDsp, runs the real MonitorControl
// (monitor_ctl.hpp) on a 10 ms thread exactly as main.cpp does (one poll
// before the loop, then the thread), and runs a paced loop of 1 ms blocks of a
// built-in signal through the owner's steps: to_float, [usb-capture tap],
// filter, [monitor-in tap], monitor_gains, [dante-playback tap], from_float.
// The loop primes once at its start as the owner does (reset, then
// prime_monitor at 10 ms), so the first block rises from silence. With
// --meter-file the real MeterPublisher writes the owner's meter file every
// 25 ms.
//
// The signal: input i (0-based) is a sine at -20 dBFS peak whose period is
// 4 * (12 + 4i) samples, so a sample always lands on the peak and every
// window's peak reads exactly -20.0 dBFS on usb-capture. On dante-playback
// minus monitor-in, per output, is the monitor gain alone.
//
//   monitor_sim --artifact FILE --rate R --state PATH --saved PATH --limits PATH --status PATH
//               [--meter-file PATH] [--seconds N]
//
// Build (one line), from the repository root:
//   c++ -std=c++20 -O2 -Wall -Wextra -Wpedantic -Werror -I dante/owner -I dsp-core/include
//       -o monitor_sim dante/owner/monitor_sim.cpp dsp-core/src/bridge_core.cpp -lpthread
#include "dsp_path.hpp"
#include "meter_tap.hpp"
#include "monitor_ctl.hpp"

#include <time.h>

#include <atomic>
#include <chrono>
#include <cmath>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <fstream>
#include <memory>
#include <numbers>
#include <sstream>
#include <string>
#include <string_view>
#include <thread>
#include <tuple>
#include <vector>

namespace {

namespace m = usb16x16::owner::monitor;
constexpr std::size_t kChannels = usb16x16::kChannels;

std::atomic<bool> stop{false};
void on_signal(int) { stop.store(true, std::memory_order_relaxed); }

std::int64_t now_ns() noexcept {
    timespec ts{};
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return static_cast<std::int64_t>(ts.tv_sec) * 1000000000LL + ts.tv_nsec;
}

[[noreturn]] void usage(const char* message = nullptr) {
    if (message != nullptr) std::fprintf(stderr, "%s\n", message);
    std::fputs("monitor_sim --artifact FILE --rate R --state PATH --saved PATH --limits PATH --status PATH\n"
               "            [--meter-file PATH] [--seconds N]\n",
               stderr);
    std::exit(2);
}

void print_monitor(const char* what, const m::MonitorControl& control) {
    const auto seq = control.seq();
    std::printf("MONITOR %s state=%s seq=%s gen=%llu applied=%llu refused=%llu publishes=%llu status_failures=%llu "
                "limits=%s reason=\"%s\"\n",
                what, m::mode_name(control.idle() ? m::Mode::idle : control.mode()),
                seq ? std::to_string(*seq).c_str() : "none", static_cast<unsigned long long>(control.status_gen()),
                static_cast<unsigned long long>(control.applied()), static_cast<unsigned long long>(control.refused()),
                static_cast<unsigned long long>(control.publishes()),
                static_cast<unsigned long long>(control.status_failures()), control.limits_valid() ? "file" : "defaults",
                control.reason().c_str());
    std::fflush(stdout);
}

}  // namespace

int main(int argc, char** argv) {
    std::string artifact, state, saved, limits, status, meter_file;
    unsigned rate = 48000;
    double seconds = 0.0;
    for (int i = 1; i < argc; ++i) {
        const std::string_view a(argv[i]);
        if (a == "--help" || i + 1 >= argc) usage();
        const char* v = argv[++i];
        if (a == "--artifact") artifact = v;
        else if (a == "--rate") rate = static_cast<unsigned>(std::strtoul(v, nullptr, 10));
        else if (a == "--state") state = v;
        else if (a == "--saved") saved = v;
        else if (a == "--limits") limits = v;
        else if (a == "--status") status = v;
        else if (a == "--meter-file") meter_file = v;
        else if (a == "--seconds") seconds = std::strtod(v, nullptr);
        else usage(("unknown option " + std::string(a)).c_str());
    }
    if (artifact.empty() || state.empty() || saved.empty() || limits.empty() || status.empty() || rate < 8000 || rate % 100 != 0) {
        usage("--artifact, --state, --saved, --limits and --status are required; --rate a whole number of hundreds");
    }
    std::signal(SIGINT, on_signal);
    std::signal(SIGTERM, on_signal);
    std::setvbuf(stdout, nullptr, _IOLBF, 0);

    static usb16x16::owner::OutDsp dsp;
    {
        std::ifstream file(artifact, std::ios::binary);
        std::stringstream text;
        text << file.rdbuf();
        if (!file) {
            std::printf("FATAL artifact %s cannot be read\n", artifact.c_str());
            return 2;
        }
        try {
            dsp.load(text.str(), rate);
        } catch (const std::exception& error) {
            std::printf("FATAL artifact %s: %s\n", artifact.c_str(), error.what());
            return 2;
        }
    }
    std::printf("SIM loaded preset=\"%s\" rate=%u monitor=%d sets=%zu\n", dsp.stage().preset().c_str(), rate,
                dsp.stage().has_monitor() ? 1 : 0, dsp.stage().has_monitor() ? dsp.stage().monitor().sets.size() : 0);

    static usb16x16::owner::OwnerMeters meters(rate);
    std::unique_ptr<usb16x16::owner::MeterPublisher> publisher;
    if (!meter_file.empty()) publisher = std::make_unique<usb16x16::owner::MeterPublisher>(meters, meter_file);
    const bool monitor_tap = publisher != nullptr && dsp.stage().has_monitor();

    // As main.cpp: the first poll before the loop, then the thread.
    static m::MonitorControl control(dsp.stage(), dsp.monitor(), {state, saved, limits, status}, rate);
    control.poll(now_ns());
    print_monitor("first", control);
    std::thread monitor_thread([] {
        auto last = std::make_tuple(control.mode(), control.seq(), control.applied(), control.refused(), control.status_gen());
        while (!stop.load(std::memory_order_relaxed)) {
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
            control.poll(now_ns());
            const auto now = std::make_tuple(control.mode(), control.seq(), control.applied(), control.refused(), control.status_gen());
            if (now != last) {
                last = now;
                print_monitor("changed", control);
            }
        }
    });
    std::thread meter_thread([&publisher] {
        while (!stop.load(std::memory_order_relaxed)) {
            std::this_thread::sleep_for(std::chrono::milliseconds(25));
            if (publisher) publisher->poll();
        }
    });

    // The loop: 1 ms blocks, paced on the steady clock. A prime first, as the owner's.
    const std::size_t frames = rate / 1000;
    std::vector<std::int32_t> block(frames * kChannels);
    std::array<std::size_t, kChannels> period{};
    for (std::size_t i = 0; i < kChannels; ++i) period[i] = 4 * (12 + 4 * i);
    const double amplitude = std::pow(10.0, -20.0 / 20.0);
    const double full = 8388607.0;
    dsp.reset();
    dsp.prime_monitor(usb16x16::monitor_ramp_frames_fast(rate));
    std::uint64_t position = 0;
    std::uint64_t blocks = 0;
    const auto started = std::chrono::steady_clock::now();
    auto next = started;
    while (!stop.load(std::memory_order_relaxed)) {
        if (seconds > 0.0 && std::chrono::duration<double>(std::chrono::steady_clock::now() - started).count() >= seconds) break;
        for (std::size_t f = 0; f < frames; ++f) {
            for (std::size_t c = 0; c < kChannels; ++c) {
                const double phase = 2.0 * std::numbers::pi * static_cast<double>((position + f) % period[c]) / static_cast<double>(period[c]);
                const auto value = static_cast<std::int32_t>(std::lround(amplitude * std::sin(phase) * full));
                block[f * kChannels + c] = static_cast<std::int32_t>(static_cast<std::uint32_t>(value) << 8);
            }
        }
        position += frames;
        if (dsp.ready(frames)) {
            dsp.to_float(block.data(), frames);
            if (publisher) meters.usb_capture.observe(dsp.floats(), frames);
            dsp.filter(frames);
            if (monitor_tap) meters.monitor_in.observe(dsp.floats(), frames);
            dsp.monitor_gains(frames);
            if (publisher) meters.dante_playback.observe(dsp.floats(), frames);
            dsp.from_float(block.data(), frames);
        }
        ++blocks;
        next += std::chrono::milliseconds(1);
        std::this_thread::sleep_until(next);
    }
    stop.store(true, std::memory_order_relaxed);
    monitor_thread.join();
    meter_thread.join();
    print_monitor("stopped", control);
    std::printf("SIM stopped blocks=%llu meter_writes=%llu\n", static_cast<unsigned long long>(blocks),
                static_cast<unsigned long long>(publisher ? publisher->writes() : 0));
    return 0;
}
