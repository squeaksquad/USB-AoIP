// Mac-side test of the owner's live coefficient follower against real files.
//   c++ -std=c++20 -O2 -Wall -Wextra -Wpedantic -Werror -I ../../phase4-bridge/include
//       -o /tmp/dsp_live_test dsp_live_test.cpp ../../phase4-bridge/src/bridge_core.cpp && /tmp/dsp_live_test
// (one line)
#include "dsp_live.hpp"
#include "dsp_path.hpp"

#include <cstdio>
#include <cstdlib>
#include <memory>
#include <string>
#include <vector>

using usb16x16::owner::DspLive;
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

// Straight channels at `gain`; `inputs` of them are routed, so two values give two shapes.
std::string straight(double gain, std::size_t inputs = kChannels, unsigned rate = 48000) {
    std::string text = "usb16x16-dsp 1\npreset straight\nrate " + std::to_string(rate) +
                       "\nchannels 16\ninternal 16\nmaxdelay " + std::to_string(rate / 100) + "\n";
    text += "expand " + std::to_string(inputs) + "\n";
    for (std::size_t c = 0; c < inputs; ++c) text += std::to_string(c) + " " + std::to_string(c) + " " + std::to_string(gain) + "\n";
    text += "branch 0\nassign 16\n";
    for (std::size_t c = 0; c < kChannels; ++c) text += std::to_string(c) + " " + std::to_string(c) + " 1\n";
    text += "output 16\n";
    for (std::size_t c = 0; c < kChannels; ++c) text += std::to_string(c) + " 0 1 0\n";
    return text + "end\n";
}

void put(const std::string& path, const std::string& text) {
    // By rename, as an applier would, so the inode changes even when the size and the second do not.
    const std::string temporary = path + ".new";
    std::FILE* file = std::fopen(temporary.c_str(), "wb");
    std::fwrite(text.data(), 1, text.size(), file);
    std::fclose(file);
    std::rename(temporary.c_str(), path.c_str());
}

std::string slurp(const std::string& path) {
    std::FILE* file = std::fopen(path.c_str(), "rb");
    if (file == nullptr) return {};
    char buffer[512];
    const std::size_t got = std::fread(buffer, 1, sizeof buffer, file);
    std::fclose(file);
    return std::string(buffer, got);
}

std::int32_t top24(std::int32_t value24) { return static_cast<std::int32_t>(static_cast<std::uint32_t>(value24) << 8); }

// What channel 1 reads for a sample of 1000 through the stage as it stands.
std::int32_t probe(OutDsp& dsp) {
    std::vector<std::int32_t> block(kChannels, top24(1000));
    dsp.process(block.data(), 1);
    return block[0] >> 8;
}

timespec wall(long offset_seconds) {
    timespec now{};
    clock_gettime(CLOCK_REALTIME, &now);
    now.tv_sec += offset_seconds;
    return now;
}

bool has(const std::string& text, const char* part) { return text.find(part) != std::string::npos; }

void test_follow(const std::string& directory) {
    const std::string path = directory + "/live.dsp";
    const std::string status = path + ".status";
    auto dsp = std::make_unique<OutDsp>();
    dsp->load(straight(1.0));
    DspLive live(dsp->stage(), path, status, wall(-5));
    live.announce();
    check(has(slurp(status), "state=idle"), "the status file starts idle");
    check(live.poll().outcome == DspLive::Outcome::none, "no file is not an event");

    put(path, straight(0.5));
    DspLive::Event event = live.poll();
    check(event.outcome == DspLive::Outcome::applied, "a same-shape file is applied on the poll that finds it");
    check(event.sha.size() == 64, "the event carries the file's sha256");
    check(probe(*dsp) == 500, "the loop's next block runs on the new numbers");
    check(has(slurp(status), "state=applied") && has(slurp(status), event.sha.c_str()), "the status names the applied file");
    check(live.poll().outcome == DspLive::Outcome::none, "an unchanged file is not read again");

    // Two updates with no audio in between: the second waits until the loop has taken the first.
    put(path, straight(0.25));
    check(live.poll().outcome == DspLive::Outcome::applied, "a second update applies once the first was taken");
    put(path, straight(0.125));
    check(live.poll().outcome == DspLive::Outcome::none && live.waiting(), "a third waits while the second is untaken");
    check(live.poll().outcome == DspLive::Outcome::none && live.waiting(), "and keeps waiting without audio");
    dsp->take();
    check(live.poll().outcome == DspLive::Outcome::applied && !live.waiting(), "take() on an idle wake lets it through");
    check(probe(*dsp) == 125, "the last file written is the one in force");
    // As in the bridge: the count the loop had taken when the file was applied, so one behind until the next block.
    check(has(slurp(status), "gen=2"), "the status counts the publishes the loop has taken");

    put(path, straight(0.5, 8));
    event = live.poll();
    check(event.outcome == DspLive::Outcome::refused && event.reason == "shape differs", "another shape is refused");
    check(probe(*dsp) == 125, "a refused file changes nothing");
    check(has(slurp(status), "state=refused"), "the status says refused");

    put(path, "not an artifact\n");
    event = live.poll();
    check(event.outcome == DspLive::Outcome::refused && !event.reason.empty(), "a malformed file is refused with the loader's reason");
    check(probe(*dsp) == 125, "a malformed file changes nothing");
    check(live.applied() == 3 && live.refused() == 2 && live.ignored() == 0, "the counts add up");
    check(live.status_failures() == 0, "every status write landed");
}

// SAMPLE_RATE_DESIGN.md, step 3: a live file is loaded at the running stage's
// rate, so one compiled for another rate is refused by the loader with both rates
// named, and a stage running at 96 kHz takes 96 kHz files.
void test_other_rate_refused(const std::string& directory) {
    const std::string path = directory + "/rate.dsp";
    auto dsp = std::make_unique<OutDsp>();
    dsp->load(straight(1.0));
    DspLive live(dsp->stage(), path, path + ".status", wall(-5));
    put(path, straight(0.5, kChannels, 96000));
    DspLive::Event event = live.poll();
    check(event.outcome == DspLive::Outcome::refused && has(event.reason, "compiled for rate 96000") &&
              has(event.reason, "running at 48000"),
          "a live file for another rate is refused, naming both rates");
    check(probe(*dsp) == 1000, "a file at another rate changes nothing");

    auto at96 = std::make_unique<OutDsp>();
    at96->load(straight(1.0, kChannels, 96000), 96000);
    DspLive live96(at96->stage(), directory + "/rate96.dsp", directory + "/rate96.dsp.status", wall(-5));
    put(directory + "/rate96.dsp", straight(0.5, kChannels, 96000));
    check(live96.poll().outcome == DspLive::Outcome::applied, "a stage at 96 kHz takes a 96 kHz live file");
    check(probe(*at96) == 500, "and runs on its numbers");
    put(directory + "/rate96.dsp", straight(0.25));
    check(live96.poll().outcome == DspLive::Outcome::refused, "and refuses a 48 kHz one");
}

void test_predates_start(const std::string& directory) {
    const std::string path = directory + "/stale.dsp";
    auto dsp = std::make_unique<OutDsp>();
    dsp->load(straight(1.0));
    put(path, straight(0.5));
    DspLive live(dsp->stage(), path, path + ".status", wall(+5));   // "started" after the file was written
    const DspLive::Event event = live.poll();
    check(event.outcome == DspLive::Outcome::ignored, "a file older than the process is ignored");
    check(probe(*dsp) == 1000, "an ignored file changes nothing");
    check(has(slurp(path + ".status"), "predates start"), "the status says why");
}

void test_status_unwritable() {
    auto dsp = std::make_unique<OutDsp>();
    dsp->load(straight(1.0));
    DspLive live(dsp->stage(), "/nonexistent-directory/live.dsp", "/nonexistent-directory/live.status", wall(-5));
    live.announce();
    check(live.status_failures() == 1, "a status file that cannot be written is counted, not fatal");
    check(live.poll().outcome == DspLive::Outcome::none, "and polling goes on");
}

}  // namespace

int main() {
    char pattern[] = "/tmp/dsp-live-test-XXXXXX";
    const char* directory = mkdtemp(pattern);
    if (directory == nullptr) {
        std::printf("FAIL: no temporary directory\n");
        return 1;
    }
    test_follow(directory);
    test_other_rate_refused(directory);
    test_predates_start(directory);
    test_status_unwritable();
    std::printf(failures == 0 ? "dsp_live_test: all passed\n" : "dsp_live_test: %d FAILED\n", failures);
    return failures == 0 ? 0 : 1;
}
