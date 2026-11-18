#include "usb16x16/bridge_core.hpp"

#include <array>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <iostream>
#include <stdexcept>
#include <string>
#include <string_view>
#include <thread>
#include <vector>

namespace {

int failures = 0;

void check(const bool condition, const std::string_view message) {
    if (!condition) {
        std::cerr << "FAIL: " << message << '\n';
        ++failures;
    }
}

// ---------------------------------------------------------------- DSP stage
//
// Coefficients quoted below were emitted by work/dsp-compiler/coefficients.mjs,
// which is also what writes the artifacts the bridge loads. Running them here
// is a cross-language check: the same numbers, a different implementation, and
// properties that hold only if both halves are right.

std::string dsp_artifact(const std::string& body, const std::size_t internal = 1) {
    return "usb16x16-dsp 1\npreset test\nrate 48000\nchannels 16\ninternal " +
           std::to_string(internal) + "\nmaxdelay 480\n" + body + "end\n";
}

// A pipeline that carries input `in` to output `out` with `gain`, no filters.
std::string dsp_passthrough(const std::size_t in, const std::size_t out,
                            const double gain, const std::size_t delay = 0,
                            const double output_gain = 1.0) {
    std::string text = "expand 1\n0 " + std::to_string(in) + " " + std::to_string(gain) + "\n";
    text += "branch 0\n";
    text += "assign 1\n" + std::to_string(out) + " 0 1\n";
    text += "output 1\n" + std::to_string(out) + " " + std::to_string(delay) + " " +
            std::to_string(output_gain) + " 0\n";
    return text;
}

std::vector<float> dsp_run(usb16x16::DspStage& stage, std::vector<float> block) {
    stage.process(block.data(), block.size() / usb16x16::kChannels);
    return block;
}

std::vector<float> dsp_impulse(const std::size_t frames, const std::size_t channel,
                               const float amplitude = 1.0F) {
    std::vector<float> block(frames * usb16x16::kChannels, 0.0F);
    block[channel] = amplitude;
    return block;
}

void test_dsp_stage_is_inert_until_loaded() {
    usb16x16::DspStage stage;
    check(!stage.loaded(), "an unloaded stage reports itself unloaded");
    // Direct mode is the absence of the stage, so an unloaded one must not
    // touch the buffer at all rather than route it to silence.
    std::vector<float> block = dsp_impulse(4, 0, 0.5F);
    const std::vector<float> before = block;
    stage.process(block.data(), 4);
    check(block == before, "an unloaded stage leaves the buffer untouched");
}

void test_dsp_routing_gain_and_polarity() {
    auto stage = usb16x16::DspStage::load(dsp_artifact(dsp_passthrough(2, 5, 0.5)));
    check(stage.loaded(), "a valid artifact loads");
    check(stage.internal_channels() == 1, "internal channel count is read back");
    const std::vector<float> out = dsp_run(stage, dsp_impulse(4, 2, 1.0F));
    check(std::abs(out[5] - 0.5F) < 1e-7F, "input 3 reaches output 6 at the mix gain");
    for (std::size_t channel = 0; channel < usb16x16::kChannels; ++channel) {
        if (channel == 5) continue;
        check(out[channel] == 0.0F, "no other output is written");
    }

    auto inverted = usb16x16::DspStage::load(dsp_artifact(dsp_passthrough(0, 0, 1.0, 0, -1.0)));
    const std::vector<float> flipped = dsp_run(inverted, dsp_impulse(4, 0, 0.25F));
    check(std::abs(flipped[0] + 0.25F) < 1e-7F, "a negative output gain inverts polarity");

    auto muted = usb16x16::DspStage::load(dsp_artifact(dsp_passthrough(0, 0, 1.0, 0, 0.0)));
    const std::vector<float> silent = dsp_run(muted, dsp_impulse(4, 0, 1.0F));
    check(silent[0] == 0.0F, "a zero output gain mutes");
}

void test_dsp_delay_moves_the_impulse() {
    auto stage = usb16x16::DspStage::load(dsp_artifact(dsp_passthrough(0, 0, 1.0, 120)));
    check(stage.delay_samples() == 120, "the stage reports the delay it carries");
    const std::vector<float> out = dsp_run(stage, dsp_impulse(400, 0, 1.0F));
    std::size_t at = 0;
    std::size_t hits = 0;
    for (std::size_t frame = 0; frame < 400; ++frame) {
        if (out[frame * usb16x16::kChannels] != 0.0F) {
            at = frame;
            ++hits;
        }
    }
    check(hits == 1, "a delayed impulse stays one impulse");
    check(at == 120, "a 120-sample delay lands the impulse at frame 120");
}

void test_dsp_delay_is_the_largest_not_the_sum() {
    // Two outputs, 96 and 240 samples. The transport carries the larger: the
    // block is not complete until the most delayed channel has been produced.
    std::string body = "expand 1\n0 0 1\nbranch 0\nassign 2\n0 0 1\n1 0 1\n";
    body += "output 2\n0 96 1 0\n1 240 1 0\n";
    auto stage = usb16x16::DspStage::load(dsp_artifact(body));
    check(stage.delay_samples() == 240, "the reported delay is the largest, not the sum");
    const std::vector<float> out = dsp_run(stage, dsp_impulse(400, 0, 1.0F));
    check(out[96 * usb16x16::kChannels] != 0.0F, "the short delay lands where it should");
    check(out[240 * usb16x16::kChannels + 1] != 0.0F, "so does the long one");
}

// Steady-state amplitude of a sine through the stage, after letting the filter
// settle. Simpler than a DFT and enough to read a crossover corner.
double dsp_sine_amplitude(usb16x16::DspStage& stage, const double freq,
                          const std::size_t output, const std::size_t input) {
    constexpr std::size_t settle = 48000;
    constexpr std::size_t measure = 4800;
    constexpr std::size_t chunk = 480;
    std::vector<float> block(chunk * usb16x16::kChannels, 0.0F);
    double peak = 0.0;
    std::size_t produced = 0;
    for (std::size_t frame = 0; frame < settle + measure; frame += chunk) {
        for (std::size_t n = 0; n < chunk; ++n) {
            const double phase = 2.0 * M_PI * freq * static_cast<double>(frame + n) / 48000.0;
            std::fill(block.begin() + static_cast<long>(n * usb16x16::kChannels),
                      block.begin() + static_cast<long>((n + 1) * usb16x16::kChannels), 0.0F);
            block[n * usb16x16::kChannels + input] = static_cast<float>(std::sin(phase));
        }
        stage.process(block.data(), chunk);
        produced += chunk;
        if (produced > settle) {
            for (std::size_t n = 0; n < chunk; ++n) {
                peak = std::max(peak, std::abs(static_cast<double>(
                    block[n * usb16x16::kChannels + output])));
            }
        }
    }
    return peak;
}

void test_dsp_crossover_branches_are_minus_six_at_the_corner() {
    // LR4 at 80 Hz from coefficients.mjs. A Linkwitz-Riley is -6.02 dB at its
    // corner, not -3: that is the property that makes two of them sum flat,
    // and it is what the engine measured on this same cascade.
    const std::string highpass =
        "0.99262254275611894 -1.9852450855122379 0.99262254275611894 -1.9851906578962613 0.98529951312821462\n"
        "0.99262254275611894 -1.9852450855122379 0.99262254275611894 -1.9851906578962613 0.98529951312821462\n";
    const std::string lowpass =
        "0.000027213807988313326 0.000054427615976626652 0.000027213807988313326 -1.9851906578962613 0.98529951312821462\n"
        "0.000027213807988313326 0.000054427615976626652 0.000027213807988313326 -1.9851906578962613 0.98529951312821462\n";
    std::string body = "expand 2\n0 0 1\n1 0 1\n";
    body += "branch 2\n0 2\n" + highpass + "1 2\n" + lowpass;
    body += "assign 2\n0 0 1\n1 1 1\n";
    body += "output 2\n0 0 1 0\n1 0 1 0\n";
    auto stage = usb16x16::DspStage::load(dsp_artifact(body, 2));
    const double high = dsp_sine_amplitude(stage, 80.0, 0, 0);
    stage.reset();
    const double low = dsp_sine_amplitude(stage, 80.0, 1, 0);
    const double high_db = 20.0 * std::log10(high);
    const double low_db = 20.0 * std::log10(low);
    check(std::abs(high_db + 6.0206) < 0.01, "the LR4 high-pass is -6.02 dB at 80 Hz");
    check(std::abs(low_db + 6.0206) < 0.01, "the LR4 low-pass is -6.02 dB at 80 Hz");

    // Summed onto one output the two branches must come back to unity, which
    // is the whole reason a Linkwitz-Riley is used and is a far stronger check
    // than either branch alone.
    std::string summed = "expand 2\n0 0 1\n1 0 1\n";
    summed += "branch 2\n0 2\n" + highpass + "1 2\n" + lowpass;
    summed += "assign 2\n0 0 1\n0 1 1\n";
    summed += "output 1\n0 0 1 0\n";
    auto pair = usb16x16::DspStage::load(dsp_artifact(summed, 2));
    for (const double freq : {40.0, 80.0, 160.0, 400.0}) {
        pair.reset();
        const double amplitude = dsp_sine_amplitude(pair, freq, 0, 0);
        check(std::abs(20.0 * std::log10(amplitude)) < 0.02,
              "the two LR4 branches sum flat");
    }
}

void test_dsp_band_matches_its_design_gain() {
    // A +6 dB bell at 1 kHz, Q 1, from coefficients.mjs: at the centre it must
    // deliver its design gain and nothing else.
    std::string body = "expand 1\n0 0 1\nbranch 0\nassign 1\n0 0 1\n";
    body += "output 1\n0 0 1 1\n"
            "1.0439530869903351 -1.8953207239365961 0.86772228475985658 "
            "-1.8953207239365961 0.91167537175019153\n";
    auto stage = usb16x16::DspStage::load(dsp_artifact(body));
    check(stage.biquad_count() == 1, "the band is one biquad");
    const double centre = 20.0 * std::log10(dsp_sine_amplitude(stage, 1000.0, 0, 0));
    check(std::abs(centre - 6.0) < 0.02, "a +6 dB bell gives +6 dB at its centre");
    stage.reset();
    const double away = 20.0 * std::log10(dsp_sine_amplitude(stage, 60.0, 0, 0));
    check(std::abs(away) < 0.05, "and leaves 60 Hz alone");
}

void test_dsp_refuses_what_it_cannot_read() {
    const std::array<std::string_view, 6> bad{
        "nothing like it\n",
        "usb16x16-dsp 2\npreset x\n",
        "usb16x16-dsp 1\npreset x\nrate 44100\n",
        "usb16x16-dsp 1\npreset x\nrate 48000\nchannels 8\n",
        "usb16x16-dsp 1\npreset x\nrate 48000\nchannels 16\ninternal 0\n",
        "usb16x16-dsp 1\npreset x\nrate 48000\nchannels 16\ninternal 1\nmaxdelay 480\nexpand 1\n0 0 nonsense\n",
    };
    for (const auto& text : bad) {
        bool threw = false;
        try {
            usb16x16::DspStage::load(text);
        } catch (const std::runtime_error&) {
            threw = true;
        }
        check(threw, "a malformed artifact is refused rather than half-loaded");
    }
    // A truncated artifact must not load either: half a pipeline still applies
    // gain, it just applies it to the wrong things.
    bool truncated_threw = false;
    try {
        usb16x16::DspStage::load(
            "usb16x16-dsp 1\npreset x\nrate 48000\nchannels 16\ninternal 1\nmaxdelay 480\n"
            "expand 1\n0 0 1\nbranch 0\nassign 1\n0 0 1\n");
    } catch (const std::runtime_error&) {
        truncated_threw = true;
    }
    check(truncated_threw, "a truncated artifact is refused");
}

// SAMPLE_RATE_DESIGN.md, step 3: an artifact is compiled for one rate and the
// stage runs only at that rate. 48 kHz is the default and is unchanged.
std::string dsp_artifact_at(const unsigned rate, const std::string& body) {
    return "usb16x16-dsp 1\npreset test\nrate " + std::to_string(rate) + "\nchannels 16\ninternal 1\nmaxdelay " +
           std::to_string(usb16x16::DspStage::max_delay_samples(rate)) + "\n" + body + "end\n";
}

void test_dsp_refuses_an_artifact_for_another_rate() {
    const auto refused = [](const std::string& text, const unsigned rate) {
        try {
            (void)usb16x16::DspStage::load(text, rate);
        } catch (const std::runtime_error& error) {
            return std::string(error.what()).find("running at " + std::to_string(rate)) != std::string::npos;
        }
        return false;
    };
    const std::string at48 = dsp_artifact(dsp_passthrough(0, 0, 1.0));
    const std::string at96 = dsp_artifact_at(96000, dsp_passthrough(0, 0, 1.0));
    check(usb16x16::DspStage::load(at48).rate() == 48000, "the default running rate is 48 kHz");
    check(usb16x16::DspStage::load(at48, 48000).rate() == 48000, "a 48 kHz artifact loads at 48 kHz");
    check(refused(at48, 96000), "a 48 kHz artifact is refused at 96 kHz, naming both rates");
    check(refused(at96, 48000), "a 96 kHz artifact is refused at 48 kHz");
    check(refused(dsp_artifact_at(44100, dsp_passthrough(0, 0, 1.0)), 48000), "a 44.1 kHz artifact is refused at 48 kHz");
    auto stage96 = usb16x16::DspStage::load(at96, 96000);
    check(stage96.rate() == 96000, "a 96 kHz artifact loads at 96 kHz");
    check(stage96.shape().find("rate 96000\nchannels 16\ninternal 1\nmaxdelay 960\n") != std::string::npos,
          "the shape carries the rate and its 10 ms delay ceiling");
    check(stage96.shape_key() != usb16x16::DspStage::load(at48).shape_key(),
          "the same pipeline at two rates is two shapes");

    // 10 ms of delay is 960 samples at 96 kHz, and is the ceiling there.
    auto delayed = usb16x16::DspStage::load(dsp_artifact_at(96000, dsp_passthrough(0, 0, 1.0, 960)), 96000);
    std::vector<float> out = dsp_run(delayed, dsp_impulse(1000, 0, 1.0F));
    check(std::abs(out[960 * usb16x16::kChannels] - 1.0F) < 1e-6F, "a 960-sample delay at 96 kHz lands at 960");
    check(refused(dsp_artifact_at(96000, dsp_passthrough(0, 0, 1.0, 961)), 96000) == false,
          "an over-ceiling delay is refused as malformed, not as a rate");
    bool over_threw = false;
    try {
        (void)usb16x16::DspStage::load(dsp_artifact_at(96000, dsp_passthrough(0, 0, 1.0, 961)), 96000);
    } catch (const std::runtime_error&) {
        over_threw = true;
    }
    check(over_threw, "a delay over 10 ms at 96 kHz is refused");

    // A live update compiled for another rate cannot be published into a running stage.
    auto running = usb16x16::DspStage::load(at48);
    std::string reason;
    check(!running.publish(stage96, reason) && reason == "shape differs",
          "a live update at another rate is refused");
}

void test_dsp_reset_clears_filter_state() {
    std::string body = "expand 1\n0 0 1\nbranch 0\nassign 1\n0 0 1\n";
    body += "output 1\n0 0 1 1\n"
            "1.0439530869903351 -1.8953207239365961 0.86772228475985658 "
            "-1.8953207239365961 0.91167537175019153\n";
    auto stage = usb16x16::DspStage::load(dsp_artifact(body));
    const std::vector<float> first = dsp_run(stage, dsp_impulse(64, 0, 1.0F));
    stage.reset();
    const std::vector<float> second = dsp_run(stage, dsp_impulse(64, 0, 1.0F));
    check(first == second, "reset returns the stage to its loaded state");
    // Without a reset the ringing from the first impulse is still arriving, so
    // the same input must not give the same output.
    const std::vector<float> third = dsp_run(stage, dsp_impulse(64, 0, 1.0F));
    check(third != second, "filter state persists across blocks when not reset");
}

// ------------------------------------------------- live coefficient updates
//
// LIVE_COEFFICIENTS_DESIGN.md, step 2: a loaded stage takes another stage's
// numbers without a restart when the shapes match, keeps its filter state
// across the switch, and refuses everything else without touching what the
// audio thread reads.

// The artifact bridge-artifact.test.mjs pins its shape vector on.
std::string dsp_pinned_vector() {
    std::string text =
        "usb16x16-dsp 1\npreset pinned shape vector\nrate 48000\nchannels 16\ninternal 2\nmaxdelay 480\n"
        "expand 2\n0 0 0.125\n1 1 -0.5\n"
        "branch 1\n1 2\n1 0 0 0 0\n0.5 0.25 0 -0.1 0.01\n"
        "assign 2\n0 0 1\n3 1 0\n"
        "output 16\n";
    for (std::size_t output = 0; output < 16; ++output) {
        text += output == 0 ? "0 48 0.5 1\n1 0 0 0 0\n"
                            : std::to_string(output) + " 0 1 0\n";
    }
    return text + "end\n";
}

void test_sha256_known_vectors() {
    check(usb16x16::sha256_hex("") ==
              "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
          "SHA-256 of the empty string");
    check(usb16x16::sha256_hex("abc") ==
              "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
          "SHA-256 of 'abc'");
    // Two blocks: the padding boundary.
    check(usb16x16::sha256_hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq") ==
              "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
          "SHA-256 across a block boundary");
}

void test_dsp_shape_key_matches_the_pinned_vector() {
    auto stage = usb16x16::DspStage::load(dsp_pinned_vector());
    std::string expected =
        "usb16x16-dsp-shape 1\nrate 48000\nchannels 16\ninternal 2\nmaxdelay 480\n"
        "expand 2\n0 0\n1 1\nbranch 1\n1 2\nassign 2\n0 0\n3 1\noutput 16\n";
    for (std::size_t output = 0; output < 16; ++output) {
        expected += std::to_string(output) + (output == 0 ? " 1\n" : " 0\n");
    }
    expected += "end\n";
    check(stage.shape() == expected, "the canonical shape text matches artifactShape");
    check(stage.shape_key() ==
              "7d17e4176422b77db999ae52bb02599d7c92da8a7cb95c369583980ecb4e57d0",
          "the shape key matches the vector pinned in bridge-artifact.test.mjs");
    // Numbers do not move the key; a count does.
    std::string renumbered = dsp_pinned_vector();
    renumbered.replace(renumbered.find("0 48 0.5 1"), 10, "0 96 0.25 1");
    check(usb16x16::DspStage::load(renumbered).shape_key() == stage.shape_key(),
          "gains, delays and coefficients are not shape");
    std::string reshaped = dsp_pinned_vector();
    reshaped.replace(reshaped.find("assign 2\n0 0 1\n3 1 0"), 20, "assign 1\n0 0 1");
    check(usb16x16::DspStage::load(reshaped).shape_key() != stage.shape_key(),
          "a mix row is shape");
}

// One bell on output 0, the +6 dB 1 kHz band used above, and a -6 dB one.
const char* const kBellUp =
    "1.0439530869903351 -1.8953207239365961 0.86772228475985658 "
    "-1.8953207239365961 0.91167537175019153";
const char* const kBellDown =
    "0.97012906118456326 -1.8953207239365961 0.94154631056562832 "
    "-1.8953207239365961 0.91167537175019153";

std::string dsp_one_band(const char* const section, const double output_gain = 1.0,
                         const std::size_t delay = 0) {
    return "expand 1\n0 0 1\nbranch 0\nassign 1\n0 0 1\noutput 1\n0 " + std::to_string(delay) +
           " " + std::to_string(output_gain) + " 1\n" + section + "\n";
}

// ---- unity sections are skipped (the fixed shape's empty band slots)
//
// The stage skips a section that is exactly y = x and rebuilds its history when
// a live set switches it on. The reference here runs every section, unity
// included, as plain direct form I with the coefficients switching at the same
// sample; the stage must match it exactly, sample for sample.

const char* const kUnity = "1 0 0 0 0";
const char* const kLowish = "0.2 0.1 0.05 -0.5 0.1";
const char* const kHighish = "0.6 -0.9 0.35 -0.3 0.2";

std::array<double, 5> parse_section(const char* const text) {
    std::array<double, 5> out{};
    char* cursor = const_cast<char*>(text);
    for (double& value : out) value = std::strtod(cursor, &cursor);
    return out;
}

// One chain of sections, on output 0 (`branch` false) or on the branch of the
// one internal channel (`branch` true), input 0 to output 0 at unity gain.
std::string dsp_chain(const std::vector<const char*>& sections, const bool branch) {
    std::string list;
    for (const char* section : sections) list += std::string(section) + "\n";
    const std::string count = std::to_string(sections.size());
    if (branch) {
        return "expand 1\n0 0 1\nbranch 1\n0 " + count + "\n" + list + "assign 1\n0 0 1\noutput 1\n0 0 1 0\n";
    }
    return "expand 1\n0 0 1\nbranch 0\nassign 1\n0 0 1\noutput 1\n0 0 1 " + count + "\n" + list;
}

void check_unity_skip_against_reference(const bool branch) {
    const std::vector<std::vector<const char*>> sets{
        {kUnity, kBellUp, kUnity, kUnity, kLowish},        // a run of unity between two bands
        {kHighish, kBellUp, kUnity, kBellDown, kLowish},   // switched on at the head and after a band
        {kHighish, kUnity, kUnity, kBellDown, kUnity},     // switched off, the tail included
        {kUnity, kBellUp, kLowish, kUnity, kHighish},      // on again behind a band switched off
        {kUnity, kUnity, kUnity, kUnity, kUnity},          // all off
        {kBellUp, kHighish, kLowish, kBellDown, kBellUp},  // all on from nothing
    };
    auto stage = usb16x16::DspStage::load(dsp_artifact(dsp_chain(sets[0], branch)));
    std::array<std::array<double, 4>, 5> state{};   // x1 x2 y1 y2, every section always run
    unsigned seed = 12345;
    const auto noise = [&seed]() {
        seed = seed * 1103515245U + 12345U;
        return static_cast<float>(static_cast<int>((seed >> 8) & 0xFFFF) - 32768) / 65536.0F;
    };
    bool exact = true;
    std::size_t first_bad = 0;
    std::size_t sample_index = 0;
    for (std::size_t set = 0; set < sets.size(); ++set) {
        if (set > 0) {
            const auto update = usb16x16::DspStage::load(dsp_artifact(dsp_chain(sets[set], branch)));
            std::string reason;
            check(stage.publish(update, reason), "the next set publishes (same shape)");
        }
        std::array<std::array<double, 5>, 5> coefficients{};
        for (std::size_t k = 0; k < 5; ++k) coefficients[k] = parse_section(sets[set][k]);
        for (int block = 0; block < 5; ++block) {
            std::vector<float> buffer(48 * usb16x16::kChannels, 0.0F);
            for (std::size_t frame = 0; frame < 48; ++frame) buffer[frame * usb16x16::kChannels] = noise();
            std::vector<float> expected(48);
            for (std::size_t frame = 0; frame < 48; ++frame) {
                double sample = static_cast<double>(buffer[frame * usb16x16::kChannels]);
                for (std::size_t k = 0; k < 5; ++k) {
                    const auto& c = coefficients[k];
                    auto& h = state[k];
                    const double output = c[0] * sample + c[1] * h[0] + c[2] * h[1] - c[3] * h[2] - c[4] * h[3];
                    h = {sample, h[0], output, h[2]};
                    sample = output;
                }
                expected[frame] = static_cast<float>(sample * 1.0);
            }
            stage.process(buffer.data(), 48);
            for (std::size_t frame = 0; frame < 48; ++frame, ++sample_index) {
                if (buffer[frame * usb16x16::kChannels] != expected[frame] && exact) {
                    exact = false;
                    first_bad = sample_index;
                }
            }
        }
    }
    if (!exact) std::cerr << "  first difference at sample " << first_bad << '\n';
    check(exact, branch ? "a branch chain with unity skipped matches every section run, through six live sets"
                        : "an output chain with unity skipped matches every section run, through six live sets");
}

void test_dsp_unity_skip_is_exact() {
    check_unity_skip_against_reference(false);
    check_unity_skip_against_reference(true);
}

void test_dsp_unity_skip_survives_reset() {
    // After a reset every history is silence, the chain input's included, so a
    // band switched on next starts from silence as a loaded stage would.
    auto stage = usb16x16::DspStage::load(dsp_artifact(dsp_chain({kUnity, kBellUp}, false)));
    (void)dsp_run(stage, dsp_impulse(64, 0, 0.5F));
    stage.reset();
    std::string reason;
    check(stage.publish(usb16x16::DspStage::load(dsp_artifact(dsp_chain({kLowish, kBellUp}, false))), reason),
          "publish after reset");
    auto fresh = usb16x16::DspStage::load(dsp_artifact(dsp_chain({kLowish, kBellUp}, false)));
    check(dsp_run(stage, dsp_impulse(64, 0, 1.0F)) == dsp_run(fresh, dsp_impulse(64, 0, 1.0F)),
          "a band switched on after a reset runs as from a fresh load");
}

void test_dsp_publish_keeps_filter_state() {
    // Reference: the same difference equation run in the test, switching
    // coefficients at the swap frame with the state carried over. The stage
    // must agree sample for sample, which it can only do by keeping state.
    auto stage = usb16x16::DspStage::load(dsp_artifact(dsp_one_band(kBellUp)));
    auto update = usb16x16::DspStage::load(dsp_artifact(dsp_one_band(kBellDown)));
    const std::size_t block = 48;
    const std::size_t blocks = 20;
    const std::size_t swap_block = 7;
    std::vector<float> input(block * blocks * usb16x16::kChannels, 0.0F);
    for (std::size_t frame = 0; frame < block * blocks; ++frame) {
        input[frame * usb16x16::kChannels] =
            static_cast<float>(0.4 * std::sin(2.0 * M_PI * 1000.0 * static_cast<double>(frame) / 48000.0));
    }
    struct Coefficients { double b0, b1, b2, a1, a2; };
    const Coefficients up{1.0439530869903351, -1.8953207239365961, 0.86772228475985658,
                          -1.8953207239365961, 0.91167537175019153};
    const Coefficients down{0.97012906118456326, -1.8953207239365961, 0.94154631056562832,
                            -1.8953207239365961, 0.91167537175019153};
    double x1 = 0, x2 = 0, y1 = 0, y2 = 0;
    std::vector<float> reference(input.size(), 0.0F);
    std::vector<float> actual = input;
    std::string reason;
    bool published = false;
    for (std::size_t index = 0; index < blocks; ++index) {
        if (index == swap_block) {
            published = stage.publish(update, reason);
            check(published, "a same-shape update is accepted: " + reason);
        }
        const Coefficients& c = index >= swap_block ? down : up;
        for (std::size_t frame = index * block; frame < (index + 1) * block; ++frame) {
            const double in = static_cast<double>(input[frame * usb16x16::kChannels]);
            const double out = c.b0 * in + c.b1 * x1 + c.b2 * x2 - c.a1 * y1 - c.a2 * y2;
            x2 = x1; x1 = in; y2 = y1; y1 = out;
            reference[frame * usb16x16::kChannels] = static_cast<float>(out);
        }
        stage.process(actual.data() + index * block * usb16x16::kChannels, block);
    }
    check(actual == reference, "output after the switch equals the reference with state carried");
    check(stage.generation() == 1, "the audio thread reports having taken one publish");

    // Without state continuity the two would differ: a fresh stage on the
    // second set is not the same signal after the swap.
    auto fresh = usb16x16::DspStage::load(dsp_artifact(dsp_one_band(kBellDown)));
    std::vector<float> naive = input;
    for (std::size_t index = 0; index < blocks; ++index) {
        fresh.process(naive.data() + index * block * usb16x16::kChannels, block);
    }
    check(naive != reference, "the check has teeth: a cold second filter is a different signal");
}

void test_dsp_publish_refuses_a_different_shape() {
    auto stage = usb16x16::DspStage::load(dsp_artifact(dsp_one_band(kBellUp)));
    auto other = usb16x16::DspStage::load(dsp_artifact(dsp_passthrough(0, 0, 1.0)));
    const std::vector<float> before = dsp_run(stage, dsp_impulse(64, 0, 1.0F));
    std::string reason;
    check(!stage.publish(other, reason), "a different shape is refused");
    check(reason == "shape differs", "with the reason named");
    stage.reset();
    const std::vector<float> after = dsp_run(stage, dsp_impulse(64, 0, 1.0F));
    check(before == after, "a refused publish changes nothing");
    usb16x16::DspStage unloaded;
    check(!unloaded.publish(other, reason) && reason == "stage not loaded",
          "an unloaded stage refuses");
    check(!stage.publish(unloaded, reason) && reason == "update not loaded",
          "an unloaded update is refused");
}

void test_dsp_publish_waits_for_the_audio_thread() {
    auto stage = usb16x16::DspStage::load(dsp_artifact(dsp_one_band(kBellUp)));
    auto update = usb16x16::DspStage::load(dsp_artifact(dsp_one_band(kBellDown)));
    std::string reason;
    check(stage.publish(update, reason), "the first publish is taken");
    check(!stage.publish(update, reason), "a second publish before any block is refused");
    check(reason == "previous update not yet taken", "because the audio thread has not seen it");
    std::vector<float> block = dsp_impulse(48, 0, 0.0F);
    stage.process(block.data(), 48);
    check(stage.publish(update, reason), "after one block the inactive set is free again");
    check(stage.generation() == 1, "generation counts what the audio thread took");
}

void test_dsp_publish_shrinking_delay_stays_in_bounds() {
    auto stage = usb16x16::DspStage::load(dsp_artifact(dsp_one_band(kBellUp, 1.0, 480)));
    auto shorter = usb16x16::DspStage::load(dsp_artifact(dsp_one_band(kBellUp, 1.0, 48)));
    auto none = usb16x16::DspStage::load(dsp_artifact(dsp_one_band(kBellUp, 1.0, 0)));
    // Fill the long line so the write index sits well past 48.
    std::vector<float> silence(96 * usb16x16::kChannels, 0.0F);
    stage.process(silence.data(), 96);
    stage.process(silence.data(), 96);
    std::string reason;
    check(stage.publish(shorter, reason), "a delay change is a live update");
    check(stage.delay_samples() == 48, "the reported delay follows the update");
    // 30 blocks through the shortened line: no out-of-bounds read or write
    // (this would trip under a sanitiser) and, once the stale samples are out,
    // an impulse arrives 48 frames late.
    for (int index = 0; index < 30; ++index) stage.process(silence.data(), 96);
    std::vector<float> out = dsp_run(stage, dsp_impulse(200, 0, 1.0F));
    std::size_t at = 0;
    float peak = 0.0F;
    for (std::size_t frame = 0; frame < 200; ++frame) {
        const float value = std::abs(out[frame * usb16x16::kChannels]);
        if (value > peak) { peak = value; at = frame; }
    }
    check(at == 48, "after the switch the impulse lands at the new delay");
    check(stage.publish(none, reason), "delay to zero is a live update too");
    stage.process(silence.data(), 96);
    out = dsp_run(stage, dsp_impulse(200, 0, 1.0F));
    check(out[0] != 0.0F, "with no delay the impulse is immediate");
}

void test_dsp_moved_stage_keeps_working() {
    auto loaded = usb16x16::DspStage::load(dsp_artifact(dsp_one_band(kBellUp)));
    const std::string key = loaded.shape_key();
    usb16x16::DspStage moved = std::move(loaded);
    check(moved.loaded() && !loaded.loaded(), "move transfers the load");
    check(moved.shape_key() == key, "and the shape");
    auto update = usb16x16::DspStage::load(dsp_artifact(dsp_one_band(kBellDown)));
    std::string reason;
    check(moved.publish(update, reason), "a moved stage still takes updates");
}

void test_dsp_is_block_size_agnostic() {
    // The bridge renders whatever the device grants, so a block boundary must
    // not be audible: one 480-frame call and ten 48-frame calls must agree.
    std::string body = "expand 1\n0 0 1\nbranch 0\nassign 1\n0 0 1\n";
    body += "output 1\n0 37 1 1\n"
            "1.0439530869903351 -1.8953207239365961 0.86772228475985658 "
            "-1.8953207239365961 0.91167537175019153\n";
    std::vector<float> input(480 * usb16x16::kChannels, 0.0F);
    for (std::size_t frame = 0; frame < 480; ++frame) {
        input[frame * usb16x16::kChannels] =
            static_cast<float>(0.4 * std::sin(2.0 * M_PI * 220.0 * static_cast<double>(frame) / 48000.0));
    }
    auto whole = usb16x16::DspStage::load(dsp_artifact(body));
    std::vector<float> one = input;
    whole.process(one.data(), 480);

    auto split = usb16x16::DspStage::load(dsp_artifact(body));
    std::vector<float> many = input;
    for (std::size_t frame = 0; frame < 480; frame += 48) {
        split.process(many.data() + frame * usb16x16::kChannels, 48);
    }
    check(one == many, "the stage gives the same result whatever the block size");
}

// -------------------------------------------------------------- level meter

void test_level_meter_measures_a_window() {
    usb16x16::LevelMeter meter(2400);
    usb16x16::LevelMeter::Snapshot snapshot;
    check(!meter.read(snapshot), "nothing is published before the first window closes");
    std::vector<float> block(2400 * usb16x16::kChannels, 0.0F);
    for (std::size_t frame = 0; frame < 2400; ++frame) {
        float* row = block.data() + frame * usb16x16::kChannels;
        row[0] = 0.5F;                                   // constant: peak = rms
        row[1] = (frame % 2 == 0) ? 1.0F : -1.0F;        // full scale, every sample clips
        row[2] = (frame == 100) ? -0.25F : 0.0F;         // one negative sample
        row[3] = -1.0F;                                  // -1.0 exactly is representable: no clip
    }
    meter.observe(block.data(), 2400);
    check(meter.read(snapshot), "the window closes on the block that reaches 2400 frames");
    check(snapshot.sequence == 1 && meter.sequence() == 1, "one window published");
    check(snapshot.frames == 2400 && snapshot.position == 2400, "the window carries its frame count and position");
    check(std::abs(snapshot.peak[0] - 0.5F) < 1e-7F, "peak of a constant 0.5 is 0.5");
    check(std::abs(snapshot.sum_squares[0] / snapshot.frames - 0.25) < 1e-6, "mean square of 0.5 is 0.25");
    check(snapshot.peak[1] == 1.0F && snapshot.clipped[1] == 1200, "+1.0 clips on every other sample, -1.0 does not");
    check(snapshot.peak[2] == 0.25F, "peak is a magnitude");
    check(snapshot.clipped[3] == 0 && snapshot.peak[3] == 1.0F, "-1.0 is not a clip, as the converters see it");
    check(snapshot.peak[4] == 0.0F && snapshot.sum_squares[4] == 0.0, "an undriven channel reads zero");
    check(std::abs(usb16x16::amplitude_to_dbfs(0.5) + 6.0206) < 0.001, "0.5 is -6.02 dBFS");
    check(usb16x16::amplitude_to_dbfs(0.0) == -144.0, "silence is the floor, not -inf");
}

void test_level_meter_closes_windows_on_block_boundaries() {
    usb16x16::LevelMeter meter(2400);
    usb16x16::LevelMeter::Snapshot snapshot;
    std::vector<float> block(512 * usb16x16::kChannels, 0.0F);
    block[7] = 0.75F;  // frame 0, channel 7
    for (int calls = 0; calls < 49; ++calls) {
        meter.observe(block.data(), 48);
    }
    check(!meter.read(snapshot), "2352 frames do not close a 2400-frame window");
    meter.observe(block.data(), 48);
    check(meter.read(snapshot) && snapshot.frames == 2400, "the 50th 48-frame block closes it exactly");
    check(snapshot.peak[7] == 0.75F, "the peak is the window's");
    // A 512-frame block straddling the boundary closes the next window long.
    for (int calls = 0; calls < 48; ++calls) {
        meter.observe(block.data(), 48);
    }
    std::vector<float> silent(512 * usb16x16::kChannels, 0.0F);
    meter.observe(silent.data(), 512);
    check(meter.read(snapshot) && snapshot.sequence == 2, "a second window");
    check(snapshot.frames == 48 * 48 + 512, "a window is at least window_frames and at most one block longer");
    check(snapshot.position == 2400 + 48 * 48 + 512, "position is cumulative");
    check(snapshot.peak[7] == 0.75F, "the second window still saw the 48-frame blocks");
    for (int calls = 0; calls < 5; ++calls) {
        meter.observe(silent.data(), 512);
    }
    check(meter.read(snapshot) && snapshot.sequence == 3 && snapshot.peak[7] == 0.0F,
          "peaks do not carry over between windows");
}

void test_level_meter_clip_count_is_cumulative() {
    usb16x16::LevelMeter meter(48);
    usb16x16::LevelMeter::Snapshot snapshot;
    std::vector<float> hot(48 * usb16x16::kChannels, 0.0F);
    for (std::size_t frame = 0; frame < 48; ++frame) {
        hot[frame * usb16x16::kChannels + 15] = 1.5F;
    }
    std::vector<float> silent(48 * usb16x16::kChannels, 0.0F);
    meter.observe(hot.data(), 48);
    meter.observe(silent.data(), 48);
    meter.observe(hot.data(), 48);
    check(meter.read(snapshot) && snapshot.sequence == 3, "three windows");
    check(snapshot.clipped[15] == 96, "clips accumulate across windows so a slow reader misses none");
    check(snapshot.peak[15] == 1.5F, "the last window's peak");
}

void test_level_meter_snapshot_is_never_torn() {
    // A writer publishes windows as fast as it can; every window carries one
    // value on all sixteen channels, so a torn copy would show two values.
    usb16x16::LevelMeter meter(48);
    std::atomic<bool> stop{false};
    std::thread writer([&] {
        std::vector<float> block(48 * usb16x16::kChannels);
        std::uint32_t window = 0;
        while (!stop.load(std::memory_order_relaxed)) {
            const float value = 0.01F + static_cast<float>(window % 90) / 100.0F;
            std::fill(block.begin(), block.end(), value);
            meter.observe(block.data(), 48);
            ++window;
        }
    });
    std::size_t reads = 0;
    std::size_t torn = 0;
    std::size_t consistent = 0;
    usb16x16::LevelMeter::Snapshot snapshot;
    for (int attempt = 0; attempt < 200000; ++attempt) {
        if (!meter.read(snapshot)) {
            continue;
        }
        ++reads;
        bool same = true;
        for (std::size_t channel = 1; channel < usb16x16::kChannels; ++channel) {
            same = same && snapshot.peak[channel] == snapshot.peak[0];
        }
        const double mean_square = snapshot.sum_squares[0] / snapshot.frames;
        same = same && std::abs(mean_square - static_cast<double>(snapshot.peak[0]) * snapshot.peak[0]) < 1e-6;
        same = same && snapshot.frames == 48 && snapshot.position == snapshot.sequence * 48;
        (same ? consistent : torn) += 1;
    }
    stop.store(true, std::memory_order_relaxed);
    writer.join();
    check(reads > 1000, "the reader took snapshots while the writer ran");
    check(torn == 0, "no snapshot was torn");
    check(consistent == reads, "every accepted snapshot was self-consistent");
}

void test_packed_24() {
    constexpr std::array<std::int32_t, 7> values{
        -8388608, -1234567, -1, 0, 1, 1234567, 8388607};
    for (const auto value : values) {
        std::array<std::uint8_t, 3> bytes{};
        usb16x16::pack_s24le(value, bytes.data());
        check(usb16x16::unpack_s24le(bytes.data()) == value, "S24_3LE round trip");
    }
}

void test_full_scale_conversion_does_not_wrap() {
    // Regression for the 2026-09-02 crackle: a float at or above +1.0 must
    // land on positive full scale, never wrap to negative full scale.
    for (const float hot : {1.0F, 1.02F, 1.5F}) {
        std::array<std::uint8_t, 3> bytes{};
        usb16x16::float_to_s24(hot, bytes.data());
        check(usb16x16::unpack_s24le(bytes.data()) == 8388607, "S24 positive full scale clamps");
        check(usb16x16::float_to_s32(hot) == 2147483647, "S32 positive full scale clamps");
    }
    // The largest float below 1.0 is 1 - 2^-24: it rounds up to 8388608 in
    // S24, which is where the old code wrapped, and is exact in S32.
    {
        const float just_under = std::nextafter(1.0F, 0.0F);
        std::array<std::uint8_t, 3> bytes{};
        usb16x16::float_to_s24(just_under, bytes.data());
        check(usb16x16::unpack_s24le(bytes.data()) == 8388607, "S24 just under full scale clamps");
        check(usb16x16::float_to_s32(just_under) == 2147483520, "S32 just under full scale is exact");
    }
    for (const float cold : {-1.0F, -1.02F, -1.5F}) {
        std::array<std::uint8_t, 3> bytes{};
        usb16x16::float_to_s24(cold, bytes.data());
        check(usb16x16::unpack_s24le(bytes.data()) == -8388608, "S24 negative full scale clamps");
        check(usb16x16::float_to_s32(cold) == -2147483648LL, "S32 negative full scale clamps");
    }
    // The largest representable S24 value round-trips unchanged.
    {
        std::array<std::uint8_t, 3> bytes{};
        usb16x16::pack_s24le(8388607, bytes.data());
        std::array<std::uint8_t, 3> again{};
        usb16x16::float_to_s24(usb16x16::s24_to_float(bytes.data()), again.data());
        check(usb16x16::unpack_s24le(again.data()) == 8388607, "S24 max survives float round trip");
        check(usb16x16::float_to_s32(usb16x16::s32_to_float(2147483647)) == 2147483647,
              "S32 max survives float round trip");
        check(usb16x16::float_to_s32(usb16x16::s32_to_float(-2147483647 - 1)) == -2147483647 - 1,
              "S32 min survives float round trip");
    }
    check(usb16x16::exceeds_full_scale(1.0F), "exactly +1.0 counts as clipped");
    check(usb16x16::exceeds_full_scale(-1.0001F), "below -1.0 counts as clipped");
    check(!usb16x16::exceeds_full_scale(-1.0F), "exactly -1.0 is representable");
    check(!usb16x16::exceeds_full_scale(0.999F), "in-range sample is not clipped");
}

void test_ring_wrap() {
    usb16x16::AudioRing ring(12);
    std::vector<float> input(10 * usb16x16::kChannels);
    for (std::size_t frame = 0; frame < 10; ++frame) {
        for (std::size_t channel = 0; channel < usb16x16::kChannels; ++channel) {
            input[frame * usb16x16::kChannels + channel] = static_cast<float>(frame * 100 + channel);
        }
    }
    check(ring.push(input.data(), 8), "first ring push");
    ring.pop(6);
    check(ring.push(input.data() + 8 * usb16x16::kChannels, 2), "wrapped ring push");
    check(ring.size() == 4, "wrapped ring size");
    check(ring.sample(0, 3) == 603.0F, "wrapped ring retained frame");
    check(ring.sample(3, 15) == 915.0F, "wrapped ring last frame");
}

void test_resampler_unity() {
    usb16x16::AudioRing ring(128);
    std::vector<float> input(64 * usb16x16::kChannels);
    for (std::size_t frame = 0; frame < 64; ++frame) {
        for (std::size_t channel = 0; channel < usb16x16::kChannels; ++channel) {
            input[frame * usb16x16::kChannels + channel] =
                static_cast<float>(frame) * 0.001F + static_cast<float>(channel) * 0.00001F;
        }
    }
    check(ring.push(input.data(), 64), "resampler input push");
    std::vector<float> output(48 * usb16x16::kChannels);
    usb16x16::FarrowResampler resampler;
    const auto produced = resampler.render(ring, output.data(), 48, 1.0);
    check(produced == 48, "unity resampler output count");
    for (std::size_t frame = 0; frame < produced; ++frame) {
        check(std::abs(output[frame * usb16x16::kChannels] - input[(frame + 1) * usb16x16::kChannels]) < 1.0e-7F,
              "unity resampler samples");
    }
}

void test_resampler_long_run_rate() {
    constexpr std::size_t target = 192;
    constexpr std::size_t iterations = 20000;
    constexpr double ratio = 1.0 - 32.0e-6;
    std::vector<float> block((target + 256) * usb16x16::kChannels, 0.0F);

    const auto exercise = [&](const std::size_t input_frames, const double source_step) {
        usb16x16::AudioRing ring(4096);
        usb16x16::FarrowResampler resampler;
        check(ring.push(block.data(), target + 256), "rate test initial ring push");
        std::vector<float> output(256 * usb16x16::kChannels);
        std::size_t produced_total = 0;
        for (std::size_t iteration = 0; iteration < iterations; ++iteration) {
            check(ring.push(block.data(), input_frames), "rate test input push");
            const double excess = static_cast<double>(ring.size() - target - 3);
            const std::size_t wanted = std::min<std::size_t>(
                output.size() / usb16x16::kChannels,
                static_cast<std::size_t>(excess / source_step));
            produced_total += resampler.render(ring, output.data(), wanted, source_step);
        }
        const double expected = static_cast<double>(iterations * input_frames) / source_step;
        check(std::abs(static_cast<double>(produced_total) - expected) < 260.0,
              "rate test preserves fractional frame accounting");
    };

    exercise(96, ratio);
    exercise(128, 1.0 / ratio);
}

void test_shared_estimator_sign_and_reciprocal() {
    usb16x16::SharedDriftEstimator estimator;
    for (int update = 0; update < 20; ++update) {
        estimator.update_phase_error(10.0);
    }
    check(estimator.ppm() > 0.0, "positive differential phase raises USB/RAV estimate");
    const double q = estimator.clock_ratio();
    check(std::abs(q * (1.0 / q) - 1.0) < 1.0e-12, "direction ratios are reciprocal");

    for (int update = 0; update < 100; ++update) {
        estimator.update_phase_error(-10.0);
    }
    check(estimator.ppm() < 0.0, "negative differential phase lowers estimate");
}

void test_estimator_bounds() {
    usb16x16::SharedDriftEstimator estimator;
    for (int update = 0; update < 10000; ++update) {
        estimator.update_phase_error(10000.0);
    }
    check(estimator.ppm() <= 250.0, "positive ppm bound");
    for (int update = 0; update < 20000; ++update) {
        estimator.update_phase_error(-10000.0);
    }
    check(estimator.ppm() >= -250.0, "negative ppm bound");
}

void test_shared_rate_estimator() {
    usb16x16::SharedDriftEstimator estimator;
    for (int update = 0; update < 20; ++update) {
        estimator.update_rate_observation(-18.0);
    }
    check(estimator.ppm() < -17.0 && estimator.ppm() >= -18.0,
          "rate observation converges with bounded slew");
    check(std::abs(estimator.observed_ppm() + 18.0) < 1.0e-9,
          "rate observation is retained");
    const double q = estimator.clock_ratio();
    check(std::abs(q * (1.0 / q) - 1.0) < 1.0e-12,
          "rate estimate remains reciprocal");
}

void test_estimator_seed() {
    // Phase 5 Stage B2: a seeded estimator starts at the seed, and a first
    // rate observation equal to the seed leaves it there with no slew, so a
    // session seeded with the previous session's converged ppm runs its
    // first minute at that rate instead of at nominal.
    usb16x16::SharedDriftEstimator estimator;
    estimator.reset(-15.0);
    check(std::abs(estimator.ppm() + 15.0) < 1.0e-12, "seed sets the initial ppm");
    estimator.update_rate_observation(-15.0);
    check(std::abs(estimator.ppm() + 15.0) < 1.0e-12, "observation at the seed does not move it");
    estimator.update_rate_observation(-17.0);
    check(estimator.ppm() < -15.0 && estimator.ppm() >= -17.0, "a different observation slews from the seed");
    estimator.reset(-300.0);
    check(estimator.ppm() >= -250.0, "seed is clamped to the estimator bound");
}

void test_level_servo() {
    usb16x16::LevelServo servo;
    check(!servo.have_setpoint(), "level servo starts without a setpoint");
    check(servo.update(400.0) == 0.0, "no setpoint means no bias");

    servo.set_setpoint(360.0);
    check(servo.have_setpoint() && servo.setpoint() == 360.0, "setpoint is retained");
    check(servo.update(360.0) == 0.0, "at the setpoint the bias is zero");
    check(std::abs(servo.update(370.0) - 0.5) < 1.0e-12, "10 frames high gives +0.5 ppm at gain 0.05");
    check(std::abs(servo.update(350.0) + 0.5) < 1.0e-12, "10 frames low gives -0.5 ppm");
    check(servo.update(540.0) == 2.0, "180 frames high clamps at 2 ppm");
    check(servo.update(180.0) == -2.0, "180 frames low clamps at -2 ppm");
    // Beyond the wide-error threshold the wider clamp applies: the cold-boot
    // excess of about 480 frames drains at 4.8 ppm, not 2.
    check(servo.update(840.0) == 8.0, "480 frames high uses the wide clamp");
    check(servo.update(460.0) == 2.0, "100 frames high is under the wide threshold, so the normal 2 ppm clamp");
    check(servo.update(2000.0) == 8.0, "far above clamps at the wide limit");
    check(servo.bias() == 8.0, "bias is retained");

    usb16x16::LevelServo::Config tight;
    tight.gain_ppm_per_frame = 0.05;
    tight.clamp_ppm = 3.0;
    usb16x16::LevelServo strong(tight);
    strong.set_setpoint(72.0);
    check(strong.update(132.0) == 3.0, "configured gain and clamp are honoured");
}

void test_median_wake_interval() {
    using usb16x16::median_wake_interval;
    check(median_wake_interval({}) == 0, "no wakes gives no period");
    check(median_wake_interval({5000}) == 0, "one wake gives no period");
    check(median_wake_interval({0, 1000}) == 1000, "two wakes give their interval");
    // Eight wakes on a 1000 us tick: the first interval is short (the wake
    // that drained a backlog) and one wake in the middle is 300 us late, so
    // its neighbours read 1300 and 700. The median is the tick.
    check(median_wake_interval({0, 400, 1400, 2400, 3700, 4400, 5400, 6400}) == 1000,
          "median of seven intervals ignores the short first and the late wake");
    // Five wakes are four intervals: 1000, 1004, 1000, 1006, whose two middles are 1000 and 1004.
    check(median_wake_interval({0, 1000, 2004, 3004, 4010}) == 1002, "even count takes the mean of the two middles");
}

void test_grid_phase() {
    check(usb16x16::grid_phase_ns(1500, 1000, 1000) == 500, "phase inside the cycle");
    check(usb16x16::grid_phase_ns(3500, 1000, 1000) == 500, "phase wraps by whole cycles");
    check(usb16x16::grid_phase_ns(700, 1000, 1000) == 700, "negative difference wraps to positive");
    check(usb16x16::grid_phase_ns(5, 0, 0) == 0, "zero tick is zero phase");
    check(usb16x16::phase_in_window(300, 200, 400), "inside a plain window");
    check(!usb16x16::phase_in_window(500, 200, 400), "outside a plain window");
    check(usb16x16::phase_in_window(950, 900, 100), "inside a wrapping window, high side");
    check(usb16x16::phase_in_window(50, 900, 100), "inside a wrapping window, low side");
    check(!usb16x16::phase_in_window(500, 900, 100), "outside a wrapping window");
}

void test_next_aligned_time() {
    using usb16x16::next_aligned_time;
    check(next_aligned_time(1000, 100, 900) == 1000, "not_before at or before the reference gives the reference");
    check(next_aligned_time(1000, 100, 1000) == 1000, "exactly the reference is not before it");
    check(next_aligned_time(1000, 100, 1001) == 1100, "one past the reference is the next period");
    check(next_aligned_time(1000, 100, 1100) == 1100, "exactly a period later lands on it");
    check(next_aligned_time(1000, 100, 1250) == 1300, "two and a half periods later rounds up");
    check(next_aligned_time(1000, 0, 5000) == 1000, "a zero period gives the reference");
    // The bridge's numbers: a wake 3.7 s ago on a 999 us tick, prepare wanted no sooner than now + 50 us.
    const std::int64_t wake = 123456789000, tick = 999000, now = wake + 3700123456;
    const std::int64_t target = next_aligned_time(wake, tick, now + 50000);
    check(target >= now + 50000 && target < now + 50000 + tick, "the target is inside one tick of the earliest allowed instant");
    check((target - wake) % tick == 0, "the target is on the wake's tick grid");
}

void test_windowed_regression() {
    usb16x16::WindowedLinearRegression regression;
    double slope = 0.0;
    check(!regression.slope(slope), "regression needs two samples");
    for (std::size_t sample = 0;
         sample < usb16x16::WindowedLinearRegression::kCapacity + 20;
         ++sample) {
        const double independent = 1000.0 + static_cast<double>(sample);
        regression.add(independent, -73.0 + 2.5 * independent);
    }
    check(regression.size() == usb16x16::WindowedLinearRegression::kCapacity,
          "regression retains a fixed window");
    check(regression.slope(slope), "regression produces a slope");
    check(std::abs(slope - 2.5) < 1.0e-12,
          "regression removes intercept and survives window rollover");
}

void test_applied_ratio_correction() {
    constexpr double frames_per_second_per_ppm =
        2.0 * usb16x16::kNominalRate * 1.0e-6;
    constexpr double required_ppm = -25.0;
    usb16x16::WindowedLinearRegression regression;
    double differential_frames = 400.0;
    double applied_ppm_seconds = 0.0;
    for (int second = 0; second < 120; ++second) {
        const double applied_ppm = second < 60 ? 0.0 : -18.0;
        differential_frames +=
            frames_per_second_per_ppm * (required_ppm - applied_ppm);
        applied_ppm_seconds += applied_ppm;
        regression.add(static_cast<double>(second + 1),
                       differential_frames +
                           frames_per_second_per_ppm * applied_ppm_seconds);
    }
    double corrected_slope = 0.0;
    check(regression.slope(corrected_slope), "corrected phase regression produces a slope");
    check(std::abs(corrected_slope / frames_per_second_per_ppm - required_ppm) < 1.0e-10,
          "corrected phase regression removes the applied ratio trajectory");
}

// A block of `frames` frames with every channel at a non-zero value, then
// `zero_frames` frames of exact zero on the channels in `mask`, then
// `frames` more non-zero frames. Written so a detector can be fed the same
// stream in any split.
std::vector<float> zero_run_stream(const std::size_t frames,
                                   const std::size_t zero_frames,
                                   const std::uint32_t mask) {
    std::vector<float> stream((2 * frames + zero_frames) * usb16x16::kChannels, 0.001F);
    for (std::size_t frame = frames; frame < frames + zero_frames; ++frame) {
        for (std::size_t channel = 0; channel < usb16x16::kChannels; ++channel) {
            if ((mask & (1U << channel)) != 0U) {
                stream[frame * usb16x16::kChannels + channel] = 0.0F;
            }
        }
    }
    return stream;
}

void test_impulse_trace_detector() {
    using usb16x16::ImpulseTraceDetector;
    ImpulseTraceDetector::Event event{};
    // The harness impulse: 0.25 full scale on channel 1 (index 0), one
    // sample, 12000 frames apart, with 0.1 noise on the other channels.
    std::vector<float> stream(static_cast<std::size_t>(300) * usb16x16::kChannels, 0.0F);
    for (std::size_t frame = 0; frame < 300; ++frame) {
        for (std::size_t channel = 1; channel < usb16x16::kChannels; ++channel) {
            stream[frame * usb16x16::kChannels + channel] = (frame % 2 == 0) ? 0.1F : -0.1F;
        }
    }
    stream[static_cast<std::size_t>(50) * usb16x16::kChannels] = 0.25F;
    stream[static_cast<std::size_t>(51) * usb16x16::kChannels] = -0.15F; // ringing inside the hold-off
    stream[static_cast<std::size_t>(200) * usb16x16::kChannels] = -0.25F;
    {
        ImpulseTraceDetector detector(ImpulseTraceDetector::Config{0, 0.1F, 100});
        detector.observe(stream.data(), 120, 7000);
        check(detector.pop_event(event), "the impulse is reported");
        check(event.position == 7050 && event.value == 0.25F, "position is the stream index of the first sample over threshold");
        check(!detector.pop_event(event), "the sample inside the hold-off is not a second event");
        detector.observe(stream.data() + 120 * usb16x16::kChannels, 180, 7120);
        check(detector.pop_event(event) && event.position == 7200 && event.value == -0.25F,
              "a negative impulse after the hold-off is reported across a block boundary");
        check(detector.events() == 2 && detector.dropped_events() == 0, "two events counted");
        // Noise on channel 2 never fires a detector on channel 1.
        ImpulseTraceDetector quiet(ImpulseTraceDetector::Config{2, 0.2F, 100});
        quiet.observe(stream.data(), 300, 0);
        check(!quiet.pop_event(event) && quiet.events() == 0, "0.1 noise on another channel is under the threshold");
        // The hold-off is a position, so a restart re-arms it.
        detector.observe(stream.data(), 60, 7240);
        check(!detector.pop_event(event), "an impulse 90 frames after the last is inside the 100-frame hold-off");
        detector.reset();
        detector.observe(stream.data(), 60, 7240);
        check(detector.pop_event(event) && event.position == 7290, "reset re-arms the detector");
    }
}

void test_zero_run_detector() {
    using usb16x16::ZeroRunDetector;
    ZeroRunDetector::Event event{};

    // The 2026-09-04 hole: 41 exact zeros on every channel, split across
    // two observe calls at an arbitrary point, is one event with the full
    // mask, the right start and the right length.
    {
        ZeroRunDetector detector;
        const auto stream = zero_run_stream(100, 41, 0xFFFFU);
        detector.observe(stream.data(), 120, 5000);
        check(!detector.pop_event(event), "no event before the run ends");
        detector.observe(stream.data() + 120 * usb16x16::kChannels, 121, 5120);
        check(detector.pop_event(event), "all-channel hole reports one event");
        check(event.start_frame == 5100, "hole start is the stream position of its first zero frame");
        check(event.length == 41, "hole length is 41");
        check(event.channel_mask == 0xFFFFU, "hole mask covers all sixteen channels");
        check(!detector.pop_event(event), "one hole is one event, not sixteen");
        check(detector.events() == 1 && detector.zero_frames() == 41 && detector.longest() == 41,
              "counters record the hole once");
        check(detector.long_runs() == 0 && detector.dropped_events() == 0, "nothing else is counted");
    }
    // A run under the minimum is ignored; one over the maximum is silence
    // and counted per channel as a long run, not reported.
    {
        ZeroRunDetector detector(ZeroRunDetector::Config{8, 480});
        const auto brief = zero_run_stream(10, 7, 0xFFFFU);
        detector.observe(brief.data(), 27, 0);
        check(!detector.pop_event(event) && detector.events() == 0, "a 7-frame run is under the minimum");
        const auto silence = zero_run_stream(10, 481, 0xFFFFU);
        detector.observe(silence.data(), 501, 27);
        check(!detector.pop_event(event) && detector.events() == 0, "a 481-frame run is silence, not a hole");
        check(detector.long_runs() == 16, "the long run is counted once per channel");
        const auto boundary = zero_run_stream(10, 480, 0xFFFFU);
        detector.observe(boundary.data(), 500, 528);
        check(detector.pop_event(event) && event.length == 480, "exactly the maximum is reported");
        const auto minimum = zero_run_stream(10, 8, 0x0004U);
        detector.observe(minimum.data(), 28, 1028);
        check(detector.pop_event(event) && event.length == 8 && event.channel_mask == 0x0004U,
              "exactly the minimum on one channel is reported with that channel's bit");
    }
    // Two channels whose runs end on the same frame with different starts
    // are two events; the ones that match coalesce.
    {
        ZeroRunDetector detector;
        std::vector<float> stream(60 * usb16x16::kChannels, 0.5F);
        for (std::size_t frame = 10; frame < 30; ++frame) {
            stream[frame * usb16x16::kChannels + 1] = 0.0F;
            stream[frame * usb16x16::kChannels + 9] = 0.0F;
        }
        for (std::size_t frame = 20; frame < 30; ++frame) {
            stream[frame * usb16x16::kChannels + 3] = 0.0F;
        }
        detector.observe(stream.data(), 60, 0);
        check(detector.pop_event(event) && event.start_frame == 10 && event.length == 20 &&
                  event.channel_mask == ((1U << 1) | (1U << 9)),
              "channels 1 and 9 share a run and one event");
        check(detector.pop_event(event) && event.start_frame == 20 && event.length == 10 &&
                  event.channel_mask == (1U << 3),
              "channel 3's shorter run is its own event");
        check(!detector.pop_event(event), "no third event");
    }
    // reset() forgets an open run: a direction restart must not report the
    // ring that was cleared as a hole.
    {
        ZeroRunDetector detector;
        std::vector<float> zeros(20 * usb16x16::kChannels, 0.0F);
        std::vector<float> signal(20 * usb16x16::kChannels, 0.25F);
        detector.observe(signal.data(), 20, 0);
        detector.observe(zeros.data(), 20, 20);
        detector.reset();
        detector.observe(signal.data(), 20, 40);
        check(!detector.pop_event(event) && detector.events() == 0, "a run open at reset is not reported");
    }
    // The queue holds kEventCapacity events; further ones are counted as
    // dropped but still tallied.
    {
        ZeroRunDetector detector;
        const auto one = zero_run_stream(4, 10, 0xFFFFU);
        for (std::size_t repeat = 0; repeat < ZeroRunDetector::kEventCapacity + 3; ++repeat) {
            detector.observe(one.data(), 18, repeat * 18);
        }
        check(detector.events() == ZeroRunDetector::kEventCapacity + 3, "every hole is tallied");
        check(detector.dropped_events() == 3, "holes beyond the queue are counted as dropped");
        std::size_t popped = 0;
        while (detector.pop_event(event)) {
            ++popped;
        }
        check(popped == ZeroRunDetector::kEventCapacity, "the queue drains its capacity");
    }
    // Silent channels never report: a stream with only channel 2 driven and
    // a hole on channel 2 yields one event with only bit 2.
    {
        ZeroRunDetector detector;
        std::vector<float> stream(200 * usb16x16::kChannels, 0.0F);
        for (std::size_t frame = 0; frame < 200; ++frame) {
            stream[frame * usb16x16::kChannels + 2] = (frame >= 100 && frame < 141) ? 0.0F : 0.1F;
        }
        detector.observe(stream.data(), 200, 0);
        check(detector.pop_event(event) && event.start_frame == 100 && event.length == 41 &&
                  event.channel_mask == (1U << 2),
              "a hole on the one driven channel carries only that channel");
        check(!detector.pop_event(event) && detector.long_runs() == 0,
              "undriven channels report nothing while their runs stay open");
    }
}

// ------------------------------------------------------------ monitor block

using Targets = usb16x16::MonitorGains::Targets;

Targets monitor_targets(const double gain, const std::uint32_t ramp) {
    Targets targets;
    targets.gain.fill(gain);
    targets.ramp_frames.fill(ramp);
    return targets;
}

// A different, non-trivial value on every channel and frame, exact in float.
std::vector<float> monitor_signal(const std::size_t frames) {
    std::vector<float> block(frames * usb16x16::kChannels);
    for (std::size_t frame = 0; frame < frames; ++frame) {
        for (std::size_t channel = 0; channel < usb16x16::kChannels; ++channel) {
            block[frame * usb16x16::kChannels + channel] = static_cast<float>(
                0.9 * std::sin(0.013 * static_cast<double>(frame + 1) * static_cast<double>(channel + 1)));
        }
    }
    return block;
}

bool same_bytes(const std::vector<float>& a, const std::vector<float>& b) {
    return a.size() == b.size() && std::memcmp(a.data(), b.data(), a.size() * sizeof(float)) == 0;
}

void test_monitor_default_is_untouched() {
    usb16x16::MonitorGains monitor;
    check(monitor.at_rest_unity(), "a new monitor block is at rest at unity");
    std::vector<float> block = monitor_signal(256);
    // A negative zero and the smallest denormal as well: a multiply by 1.0
    // keeps both, but a flush-to-zero or a sign slip on the way would not.
    block[0] = -0.0F;
    block[1] = std::numeric_limits<float>::denorm_min();
    const std::vector<float> before = block;
    monitor.process(block.data(), 256);
    check(same_bytes(block, before), "the default monitor block leaves the buffer bit-identical");
    std::string reason;
    check(monitor.publish(monitor_targets(1.0, 480), reason), "publishing unity is accepted");
    monitor.process(block.data(), 256);
    check(same_bytes(block, before) && monitor.at_rest_unity(),
          "publishing unity onto unity starts no ramp and touches nothing");
}

void test_monitor_ramp_reaches_its_target_exactly() {
    constexpr std::size_t n = 480;
    usb16x16::MonitorGains monitor;
    std::string reason;
    Targets targets = monitor_targets(1.0, n);
    targets.gain[0] = 0.0;
    check(monitor.publish(targets, reason), "a ramp to zero on output 1 is accepted");
    std::vector<float> block(2 * n * usb16x16::kChannels, 1.0F);
    monitor.process(block.data(), 2 * n);
    const auto at = [&](const std::size_t frame, const std::size_t channel) {
        return block[frame * usb16x16::kChannels + channel];
    };
    check(at(n - 1, 0) == 0.0F && at(n - 2, 0) > 0.0F, "a ramp of N reaches zero exactly on its Nth sample");
    check(at(0, 0) == static_cast<float>(1.0 - 1.0 / static_cast<double>(n)),
          "the first sample of a ramp is one step from where it started");
    double worst = 1.0 - static_cast<double>(at(0, 0));
    for (std::size_t frame = 1; frame < 2 * n; ++frame) {
        worst = std::max(worst, std::abs(static_cast<double>(at(frame, 0)) - static_cast<double>(at(frame - 1, 0))));
    }
    check(worst <= 1.0 / static_cast<double>(n) + 1.2e-7, "no step of a ramp of N is larger than 1/N");
    bool rest_silent = true;
    for (std::size_t frame = n - 1; frame < 2 * n; ++frame) rest_silent = rest_silent && at(frame, 0) == 0.0F;
    check(rest_silent && monitor.gain(0) == 0.0, "after the ramp the output stays at exactly zero");
    bool others = true;
    for (std::size_t frame = 0; frame < 2 * n; ++frame) {
        for (std::size_t channel = 1; channel < usb16x16::kChannels; ++channel) others = others && at(frame, channel) == 1.0F;
    }
    check(others, "channels whose target did not move are untouched");
    check(!monitor.at_rest_unity(), "a channel at zero is not at rest at unity");
}

void test_monitor_retarget_mid_ramp_is_continuous() {
    usb16x16::MonitorGains monitor;
    std::string reason;
    check(monitor.publish(monitor_targets(0.0, 480), reason), "the ramp down is accepted");
    std::vector<float> first(200 * usb16x16::kChannels, 1.0F);
    monitor.process(first.data(), 200);
    const double reached = monitor.gain(3);
    check(reached > 0.5 && reached < 0.6, "200 of 480 frames down is part way");
    check(monitor.publish(monitor_targets(1.0, 1920), reason), "the retarget is accepted");
    std::vector<float> second(2000 * usb16x16::kChannels, 1.0F);
    monitor.process(second.data(), 2000);
    const double up_step = (1.0 - reached) / 1920.0;
    const double bound = std::max(1.0 / 480.0, up_step) + 1.2e-7;
    const double across = std::abs(static_cast<double>(second[3]) - static_cast<double>(first[199 * usb16x16::kChannels + 3]));
    check(across <= bound && second[3] > first[199 * usb16x16::kChannels + 3],
          "a retarget mid-ramp turns at the gain it had reached, with no jump");
    double worst = 0.0;
    for (std::size_t frame = 1; frame < 2000; ++frame) {
        worst = std::max(worst, std::abs(static_cast<double>(second[frame * usb16x16::kChannels + 3]) -
                                         static_cast<double>(second[(frame - 1) * usb16x16::kChannels + 3])));
    }
    check(worst <= up_step + 1.2e-7, "the new ramp moves at its own step from the gain it started at");
    check(second[1919 * usb16x16::kChannels + 3] == 1.0F && monitor.at_rest_unity(),
          "the retargeted ramp lands on unity exactly and the block is at rest again");
}

void test_monitor_publish_keeps_other_ramps() {
    // Output 2 ramps down over 480; at frame 100 a publish moves output 1 only.
    // Output 2 must carry on along the ramp it was on, not start a new one.
    Targets down = monitor_targets(1.0, 480);
    down.gain[1] = 0.0;
    Targets other = down;
    other.gain[0] = 0.5;
    other.ramp_frames.fill(48);
    const auto run = [&](const bool publish_other) {
        usb16x16::MonitorGains monitor;
        std::string reason;
        monitor.publish(down, reason);
        std::vector<float> block(480 * usb16x16::kChannels, 1.0F);
        monitor.process(block.data(), 100);
        if (publish_other) monitor.publish(other, reason);
        monitor.process(block.data() + 100 * usb16x16::kChannels, 380);
        std::vector<float> second(480);
        for (std::size_t frame = 0; frame < 480; ++frame) second[frame] = block[frame * usb16x16::kChannels + 1];
        return second;
    };
    check(same_bytes(run(true), run(false)), "a publish that moves other outputs leaves a ramp in progress alone");
}

void test_monitor_is_block_size_independent() {
    constexpr std::size_t frames = 4032;  // 336 * 12; 336 is 7 * 48
    constexpr std::size_t middle = 1008;
    Targets first;
    Targets second;
    for (std::size_t channel = 0; channel < usb16x16::kChannels; ++channel) {
        first.gain[channel] = static_cast<double>(channel) / 15.0;
        first.ramp_frames[channel] = static_cast<std::uint32_t>(97 * (channel + 1));
        second.gain[channel] = 1.0 - static_cast<double>(channel) / 31.0;
        second.ramp_frames[channel] = static_cast<std::uint32_t>(1501 - 61 * channel);
    }
    const std::vector<float> input = monitor_signal(frames);
    const auto run = [&](const std::size_t block, const bool retarget) {
        usb16x16::MonitorGains monitor;
        std::string reason;
        monitor.publish(first, reason);
        std::vector<float> out = input;
        std::size_t done = 0;
        while (done < frames) {
            if (retarget && done == middle) {
                monitor.publish(second, reason);
            }
            std::size_t count = std::min(block, frames - done);
            if (retarget && done < middle) count = std::min(count, middle - done);
            monitor.process(out.data() + done * usb16x16::kChannels, count);
            done += count;
        }
        return out;
    };
    for (const bool retarget : {false, true}) {
        const std::vector<float> whole = run(frames, retarget);
        bool same = true;
        for (const std::size_t block : {std::size_t{1}, std::size_t{7}, std::size_t{48}}) {
            same = same && same_bytes(run(block, retarget), whole);
        }
        check(same, retarget ? "with a publish mid-run, blocks of 1, 7, 48 and the whole agree bit for bit"
                             : "blocks of 1, 7, 48 and the whole agree bit for bit");
    }
}

void test_monitor_publish_refuses() {
    usb16x16::MonitorGains monitor;
    std::string reason;
    for (const double bad : {std::numeric_limits<double>::quiet_NaN(), std::numeric_limits<double>::infinity(),
                             -std::numeric_limits<double>::infinity(), -0.5, 1.5, 1.0000001}) {
        Targets targets = monitor_targets(0.5, 10);
        targets.gain[7] = bad;
        reason.clear();
        check(!monitor.publish(targets, reason) && !reason.empty(),
              "a gain that is not finite or not in [0, 1] is refused with a reason");
    }
    check(monitor.generation() == 0, "a refused publish publishes nothing");
    std::vector<float> block = monitor_signal(16);
    const std::vector<float> before = block;
    monitor.process(block.data(), 16);
    check(same_bytes(block, before), "after refusals the block is still untouched");
    check(monitor.publish(monitor_targets(0.5, 10), reason), "a valid publish is accepted");
    check(!monitor.publish(monitor_targets(0.25, 10), reason) && reason == "previous update not yet taken",
          "a second publish before the audio thread took the first is refused");
    monitor.process(nullptr, 0);
    check(monitor.generation() == 1, "process with no frames takes the published set");
    check(monitor.gain(0) == 1.0, "taking a set moves no gain until there are samples");
    check(monitor.publish(monitor_targets(0.25, 10), reason), "after the take the next publish is accepted");
}

void test_monitor_zero_ramp_is_a_step() {
    usb16x16::MonitorGains monitor;
    std::string reason;
    monitor.publish(monitor_targets(0.5, 0), reason);
    std::vector<float> block = monitor_signal(4);
    const std::vector<float> before = block;
    monitor.process(block.data(), 4);
    bool halved = true;
    for (std::size_t i = 0; i < block.size(); ++i) {
        halved = halved && block[i] == static_cast<float>(static_cast<double>(before[i]) * 0.5);
    }
    check(halved, "a ramp of 0 is taken as 1: the first sample is at the target");
}

void test_monitor_start_from_silence() {
    usb16x16::MonitorGains monitor;
    std::string reason;
    Targets targets = monitor_targets(1.0, 1);
    targets.gain[5] = 0.0;
    targets.gain[6] = 0.5;
    monitor.publish(targets, reason);
    monitor.process(nullptr, 0);
    monitor.start_from_silence(100);
    check(!monitor.at_rest_unity() && monitor.gain(0) == 0.0, "start_from_silence drops every gain to zero");
    std::vector<float> block(200 * usb16x16::kChannels, 1.0F);
    monitor.process(block.data(), 200);
    const auto at = [&](const std::size_t frame, const std::size_t channel) {
        return block[frame * usb16x16::kChannels + channel];
    };
    check(at(0, 0) == static_cast<float>(0.01) && at(99, 0) == 1.0F && at(199, 0) == 1.0F,
          "a start ramp rises from one step above zero to the target on its last sample");
    check(at(99, 6) == 0.5F && at(0, 6) == static_cast<float>(0.005), "a start ramp rises to each channel's own target");
    bool silent = true;
    for (std::size_t frame = 0; frame < 200; ++frame) silent = silent && at(frame, 5) == 0.0F;
    check(silent, "a channel whose target is zero stays silent through a start");
    usb16x16::MonitorGains unity;
    unity.start_from_silence(10);
    std::vector<float> rising(20 * usb16x16::kChannels, 1.0F);
    unity.process(rising.data(), 20);
    check(rising[0] == 0.1F && rising[9 * usb16x16::kChannels] == 1.0F && unity.at_rest_unity(),
          "a default block started from silence rises to unity and comes to rest there");
}

void test_monitor_ramp_constants() {
    static_assert(usb16x16::monitor_ramp_frames_fast(48000) == 480);
    static_assert(usb16x16::monitor_ramp_frames_level(48000) == 1920);
    check(usb16x16::monitor_ramp_frames_fast(44100) == 441 && usb16x16::monitor_ramp_frames_level(44100) == 1764 &&
              usb16x16::monitor_ramp_frames_fast(96000) == 960 && usb16x16::monitor_ramp_frames_level(96000) == 3840,
          "the monitor ramps are 10 ms and 40 ms at every rate");
}

// ------------------------------------------------------- monitor section
//
// Phase 3, step 2: the artifact's optional `monitor` section (sets, outputs,
// labels, fold-downs) and the fold-downs at the stage's input.

// The monitor vector bridge-artifact.test.mjs pins: the pinned shape vector
// with a section added. The Python applier pins the same key.
std::string dsp_pinned_monitor_section() {
    return "monitor 1\nsets 2\nset front speakers\nset cans headphones\n"
           "outs 3\nout 0 speaker 0\nout 3 sub 0\nout 5 speaker 1\n"
           "label 0 Left  main\nlabel 3 Sub\n"
           "expandsets 2\n0\n-\n"
           "folds 2\nfold 0 stereo 2\n0 0 1\n0 2 0.7071067811865476\n"
           "fold 0 mono 3\n0 0 0.5\n0 1 0.5\n3 3 1\n";
}

std::string with_section(const std::string& artifact, const std::string& section) {
    const std::size_t end = artifact.rfind("end\n");
    return artifact.substr(0, end) + section + "end\n";
}

bool load_refused(const std::string& text) {
    try {
        usb16x16::DspStage::load(text);
    } catch (const std::runtime_error&) {
        return true;
    }
    return false;
}

void test_monitor_section_shape_matches_the_pinned_vector() {
    const std::string artifact = with_section(dsp_pinned_vector(), dsp_pinned_monitor_section());
    auto stage = usb16x16::DspStage::load(artifact);
    auto plain = usb16x16::DspStage::load(dsp_pinned_vector());
    check(stage.has_monitor() && !plain.has_monitor(), "the section is seen when present and only then");
    std::string expected = plain.shape();
    expected.erase(expected.size() - 4);   // "end\n"
    expected +=
        "monitor 1\nsets 2\nset front speakers\nset cans headphones\n"
        "outs 3\nout 0 speaker 0\nout 3 sub 0\nout 5 speaker 1\n"
        "expandsets 2\n0\n-\n"
        "folds 2\nfold 0 stereo 2\n0 0 1\n0 2 0.7071067811865476\n"
        "fold 0 mono 3\n0 0 0.5\n0 1 0.5\n3 3 1\nend\n";
    check(stage.shape() == expected, "the monitor shape is every section line but the labels, before end");
    check(stage.shape_key() == "e119252efe5c29dceede375386fe80d48bb1596b6f206894408520f6c2e29694",
          "the monitor shape key matches the vector pinned in bridge-artifact.test.mjs");
    check(plain.shape_key() == "7d17e4176422b77db999ae52bb02599d7c92da8a7cb95c369583980ecb4e57d0",
          "without the section the key is the old pinned one");
    // Labels are not shape; fold gains and the words' spacing as tokens are.
    std::string relabelled = artifact;
    relabelled.replace(relabelled.find("label 3 Sub"), 11, "label 3 Subwoofer");
    check(usb16x16::DspStage::load(relabelled).shape_key() == stage.shape_key(), "a label is not shape");
    std::string spaced = artifact;
    spaced.replace(spaced.find("out 3 sub 0"), 11, "out   3  sub 0");
    check(usb16x16::DspStage::load(spaced).shape_key() == stage.shape_key(), "words, not spacing, are shape");
    std::string regained = artifact;
    regained.replace(regained.find("0 2 0.7071067811865476"), 22, "0 2 0.5");
    check(usb16x16::DspStage::load(regained).shape_key() != stage.shape_key(), "a fold gain is shape");
    std::string reason;
    auto other = usb16x16::DspStage::load(regained);
    check(!stage.publish(other, reason) && reason == "shape differs",
          "so a live publish can never change a fold");
    check(!stage.publish(plain, reason) && reason == "shape differs",
          "and the section's presence is shape");
}

void test_monitor_topology_accessors() {
    auto stage = usb16x16::DspStage::load(with_section(dsp_pinned_vector(), dsp_pinned_monitor_section()));
    const usb16x16::MonitorTopology& topology = stage.monitor();
    using Kind = usb16x16::MonitorTopology::Kind;
    using Role = usb16x16::MonitorTopology::Role;
    check(topology.sets.size() == 2, "two sets");
    check(topology.sets[0].id == "front" && topology.sets[0].kind == Kind::speakers, "set 0 is front, speakers");
    check(topology.sets[1].id == "cans" && topology.sets[1].kind == Kind::headphones, "set 1 is cans, headphones");
    check((topology.sets[0].folds == std::vector<std::string>{"full", "stereo", "mono"}),
          "a speakers set lists full first, then its folds in artifact order");
    check((topology.sets[1].folds == std::vector<std::string>{"full"}), "headphones have full only");
    check(topology.outs.size() == 3 && topology.outs[1].index == 3 && topology.outs[1].role == Role::sub &&
              (topology.outs[1].sets == std::vector<std::size_t>{0}),
          "outputs carry index, role and sets");
    check(topology.outs[2].index == 5 && topology.outs[2].sets[0] == 1, "output 6 belongs to the headphones");
    check(topology.labels[0] == "Left  main", "a label is the rest of its line, inner spacing kept");
    check(topology.labels[3] == "Sub" && topology.labels[5].empty(), "an output without a label line has none");
    check(topology.set_index("cans") == 1 && topology.set_index("rear") == usb16x16::MonitorTopology::npos,
          "sets are found by ID");
    check(topology.fold_index(0, "mono") == 2 && topology.fold_index(0, "full") == 0 &&
              topology.fold_index(1, "mono") == usb16x16::MonitorTopology::npos &&
              topology.fold_index(5, "full") == usb16x16::MonitorTopology::npos,
          "folds are found by name within their set");
    auto plain = usb16x16::DspStage::load(dsp_pinned_vector());
    check(!plain.has_monitor() && plain.monitor().sets.empty(), "no section, no topology");
}

void test_monitor_section_loader_refuses() {
    const std::string base = dsp_pinned_vector();
    const std::string good = dsp_pinned_monitor_section();
    check(!load_refused(with_section(base, good)), "the pinned section loads");
    // Each replacement of one piece of the section must be refused.
    const std::vector<std::pair<std::string, std::string>> mutations{
        {"monitor 1\n", "monitor 2\n"},
        {"sets 2\n", "sets 0\n"},
        {"sets 2\n", "sets 3\n"},
        {"sets 2\nset front speakers\nset cans headphones\n",
         "sets 9\nset a speakers\nset b speakers\nset c speakers\nset d speakers\nset e speakers\n"
         "set f speakers\nset g speakers\nset h speakers\nset i speakers\n"},
        {"set front speakers", "set Front speakers"},
        {"set front speakers", "set 1front speakers"},
        {"set front speakers", "set abcdefghijabcdefghijabcdefghijabc speakers"},
        {"set cans headphones", "set front headphones"},
        {"set cans headphones", "set cans monitors"},
        {"set cans headphones", "set cans headphones extra"},
        {"outs 3\n", "outs 4\n"},
        {"outs 3\n", "outs 17\n"},
        {"out 3 sub 0", "out 0 sub 0"},
        {"out 3 sub 0", "out 16 sub 0"},
        {"out 3 sub 0", "out 3 woofer 0"},
        {"out 3 sub 0", "out 3 sub"},
        {"out 3 sub 0", "out 3 sub 2"},
        {"out 3 sub 0", "out 3 sub 1"},
        {"out 0 speaker 0", "out 0 speaker 0 1"},
        {"out 3 sub 0", "out 3 sub 0 0"},
        {"label 3 Sub", "label 4 Sub"},
        {"label 3 Sub", "label 0 Sub"},
        {"label 3 Sub", "label 3 Sub\tWoofer"},
        {"label 3 Sub", "label 3 abcdefghijabcdefghijabcdefghijabc"},
        {"label 3 Sub", "label 3"},
        {"expandsets 2\n0\n-\n", "expandsets 1\n0\n"},
        {"expandsets 2\n0\n-\n", "expandsets 3\n0\n-\n0\n"},
        {"expandsets 2\n0\n-\n", "expandsets 2\n0\n2\n"},
        {"expandsets 2\n0\n-\n", "expandsets 2\n0\n- 1\n"},
        {"folds 2\n", "folds 3\n"},
        {"folds 2\n", "folds 9\n"},
        {"fold 0 stereo 2", "fold 1 stereo 2"},
        {"fold 0 stereo 2", "fold 2 stereo 2"},
        {"fold 0 stereo 2", "fold 0 full 2"},
        {"fold 0 stereo 2", "fold 0 Stereo 2"},
        {"fold 0 stereo 2", "fold 0 abcdefghijabcdefg 2"},
        {"fold 0 mono 3", "fold 0 stereo 3"},
        {"fold 0 stereo 2", "fold 0 stereo 0"},
        {"fold 0 stereo 2", "fold 0 stereo 3"},
        {"0 2 0.7071067811865476", "0 0 0.7071067811865476"},
        {"0 2 0.7071067811865476", "0 16 0.7071067811865476"},
        {"0 2 0.7071067811865476", "0 2 nan"},
        {"0 2 0.7071067811865476", "0 2 inf"},
        {"0 2 0.7071067811865476", "0 2 0x1p-1"},
        {"0 2 0.7071067811865476", "0 2 1e999"},
        {"0 2 0.7071067811865476", "0 2 0.5 1"},
        {"3 3 1\n", "3 3 1\nend\n"},
    };
    for (const auto& [from, to] : mutations) {
        std::string section = good;
        const std::size_t at = section.find(from);
        if (at == std::string::npos) {
            check(false, "mutation target present: " + from);
            continue;
        }
        section.replace(at, from.size(), to);
        check(load_refused(with_section(base, section)), "a malformed monitor section is refused: " + to);
    }
    check(load_refused(base.substr(0, base.rfind("end\n")) + good), "a section with no end is refused");
    // Five folds in one set is one too many; four is the limit.
    std::string four = "monitor 1\nsets 1\nset s speakers\nouts 0\nexpandsets 2\n0\n0\nfolds 4\n";
    for (const char* name : {"a", "b", "c", "d"}) four += std::string("fold 0 ") + name + " 1\n0 0 1\n";
    check(!load_refused(with_section(base, four)), "four folds in a set load");
    std::string five = four;
    five.replace(five.find("folds 4"), 7, "folds 5");
    five += "fold 0 e 1\n0 0 1\n";
    check(load_refused(with_section(base, five)), "a fifth fold in a set is refused");
    std::string shared = "monitor 1\nsets 2\nset a speakers\nset b speakers\nouts 1\nout 3 sub 0 1\n"
                         "expandsets 2\n0\n1\nfolds 0\n";
    check(!load_refused(with_section(base, shared)), "a sub shared by two speaker sets loads");
    std::string phones_sub = "monitor 1\nsets 2\nset a speakers\nset b headphones\nouts 1\nout 3 sub 1\n"
                             "expandsets 2\n0\n1\nfolds 0\n";
    check(load_refused(with_section(base, phones_sub)), "a sub in a headphones set is refused");
    std::string blank_lines = good;
    blank_lines.replace(blank_lines.find("outs 3\n"), 7, "\n   \nouts 3\n\n");
    check(usb16x16::DspStage::load(with_section(base, blank_lines)).shape_key() ==
              usb16x16::DspStage::load(with_section(base, good)).shape_key(),
          "blank lines inside the section are ignored, as artifactShape ignores them");
}

// Sixteen inputs straight to sixteen outputs, one internal channel each, plus
// a seventeenth row: internal 15 reads input 2 raw (a headphones row) and goes
// to output 16. Input 16 drives nothing.
std::string fold_identity_body() {
    std::string text = "expand 16\n";
    for (std::size_t channel = 0; channel < 15; ++channel) {
        text += std::to_string(channel) + " " + std::to_string(channel) + " 1\n";
    }
    text += "15 2 1\nbranch 0\nassign 16\n";
    for (std::size_t channel = 0; channel < 16; ++channel) {
        text += std::to_string(channel) + " " + std::to_string(channel) + " 1\n";
    }
    text += "output 0\n";
    return text;
}

// One speakers set (rows 0-14) and headphones (row 15); fold 1 "test" is the
// matrix fold_test_gain below; fold 2 "pass" keeps input 1 alone at 0.5.
std::string fold_identity_section() {
    std::string text = "monitor 1\nsets 2\nset spk speakers\nset hp headphones\nouts 16\n";
    for (std::size_t channel = 0; channel < 15; ++channel) text += "out " + std::to_string(channel) + " speaker 0\n";
    text += "out 15 speaker 1\nexpandsets 16\n";
    for (std::size_t row = 0; row < 15; ++row) text += "0\n";
    text += "-\nfolds 2\nfold 0 test 6\n0 0 1\n0 2 0.5\n1 1 1\n1 2 0.25\n4 6 -0.75\n3 3 1\n"
            "fold 0 pass 1\n0 0 0.5\n";
    return text;
}

double fold_test_gain(const std::size_t dest, const std::size_t source) {
    const std::array<std::array<double, 3>, 6> rows{{{0, 0, 1}, {0, 2, 0.5}, {1, 1, 1},
                                                      {1, 2, 0.25}, {4, 6, -0.75}, {3, 3, 1}}};
    for (const auto& row : rows) {
        if (static_cast<std::size_t>(row[0]) == dest && static_cast<std::size_t>(row[1]) == source) return row[2];
    }
    return 0.0;
}

usb16x16::DspStage fold_stage() {
    return usb16x16::DspStage::load(dsp_artifact(fold_identity_body() + fold_identity_section(), 16));
}

// Frames of a constant (DC) value per input channel.
std::vector<float> fold_dc(const std::size_t frames) {
    std::vector<float> block(frames * usb16x16::kChannels);
    for (std::size_t frame = 0; frame < frames; ++frame) {
        for (std::size_t channel = 0; channel < usb16x16::kChannels; ++channel) {
            block[frame * usb16x16::kChannels + channel] = 0.5F - 0.0625F * static_cast<float>(channel);
        }
    }
    return block;
}

void test_monitor_full_is_bit_identical_to_no_section() {
    // With every set on full, the section changes nothing: the same samples,
    // through a real filter chain, as the artifact without it.
    std::string body = "expand 3\n0 0 0.5\n0 2 0.25\n1 1 -1\nbranch 1\n0 1\n";
    body += std::string(kBellUp) + "\nassign 3\n0 0 1\n5 1 0.75\n6 0 0.5\noutput 1\n5 17 0.5 1\n";
    body += std::string(kBellDown) + "\n";
    const std::string section = "monitor 1\nsets 1\nset s speakers\nouts 1\nout 0 speaker 0\n"
                                "expandsets 3\n0\n0\n-\nfolds 1\nfold 0 mono 2\n0 0 0.5\n0 1 0.5\n";
    auto plain = usb16x16::DspStage::load(dsp_artifact(body, 2));
    auto folded = usb16x16::DspStage::load(with_section(dsp_artifact(body, 2), section));
    const std::vector<float> input = monitor_signal(2000);
    std::vector<float> a = input;
    std::vector<float> b = input;
    for (std::size_t frame = 0; frame < 2000; frame += 100) {
        plain.process(a.data() + frame * usb16x16::kChannels, 100);
        folded.process(b.data() + frame * usb16x16::kChannels, 100);
    }
    check(same_bytes(a, b), "a section with every set on full is bit-identical to no section");
    check(folded.set_fold(0, 0), "asking for full while on full is accepted");
    folded.process(b.data(), 100);
    check(!folded.fold_crossfading(0), "and starts nothing");
}

void test_monitor_fold_applies_its_matrix() {
    auto stage = fold_stage();
    check(stage.set_fold(0, 1), "the test fold is requested");
    std::vector<float> settle(480 * usb16x16::kChannels, 0.0F);
    stage.process(settle.data(), 480);
    check(stage.fold(0) == 1 && !stage.fold_crossfading(0), "480 samples (10 ms at 48 kHz) finish the crossfade");
    bool exact = true;
    for (std::size_t input = 0; input < usb16x16::kChannels; ++input) {
        std::vector<float> block(usb16x16::kChannels, 0.0F);
        block[input] = 0.8F;
        stage.process(block.data(), 1);
        for (std::size_t output = 0; output < usb16x16::kChannels; ++output) {
            // Output 16 is the headphones row: input 3, unfolded. Output o < 15
            // is the speakers set's view at o.
            const double gain = output == 15 ? (input == 2 ? 1.0 : 0.0) : fold_test_gain(output, input);
            const float want = static_cast<float>(gain * static_cast<double>(0.8F));
            if (block[output] != want) {
                exact = false;
                std::cerr << "  fold: input " << input << " output " << output << " gave " << block[output]
                          << ", want " << want << '\n';
            }
        }
    }
    check(exact, "each input reaches the outputs its fold rows name, at their gains, and nothing else");
    check(stage.set_fold(0, 0), "back to full");
    stage.process(settle.data(), 480);
    std::vector<float> block = fold_dc(4);
    std::vector<float> want = block;
    // Output 16 carries input 3 (row 15 reads input 2); input 16 drives nothing.
    for (std::size_t frame = 0; frame < 4; ++frame) want[frame * 16 + 15] = want[frame * 16 + 2];
    stage.process(block.data(), 4);
    check(same_bytes(block, want), "full again is the identity");
}

// The documented crossfade arithmetic, from fold A's and fold B's outputs.
std::vector<double> crossfade_reference(const std::vector<double>& from, const std::vector<double>& to,
                                        const std::size_t ramp, const std::size_t frames) {
    std::vector<double> out(frames * usb16x16::kChannels);
    double a = 0.0;
    std::size_t remaining = ramp;
    const double step = 1.0 / static_cast<double>(ramp);
    for (std::size_t frame = 0; frame < frames; ++frame) {
        if (remaining > 0) {
            a += step;
            if (--remaining == 0) a = 1.0;
        }
        for (std::size_t channel = 0; channel < usb16x16::kChannels; ++channel) {
            // Once it is over the set is simply on B.
            out[frame * usb16x16::kChannels + channel] =
                frame >= ramp ? to[channel] : (1.0 - a) * from[channel] + a * to[channel];
        }
    }
    return out;
}

void test_monitor_crossfade_is_bounded_and_exact() {
    auto stage = fold_stage();
    const std::size_t n = usb16x16::monitor_ramp_frames_fast(48000);
    // DC in: what each fold gives per output (row 15 never folds).
    const std::vector<float> dc = fold_dc(1);
    std::vector<double> full(usb16x16::kChannels);
    std::vector<double> test(usb16x16::kChannels, 0.0);
    for (std::size_t output = 0; output < usb16x16::kChannels; ++output) {
        const double x = static_cast<double>(dc[output]);
        full[output] = output == 15 ? static_cast<double>(dc[2]) : (output < 15 ? x : 0.0);
        if (output == 15) {
            test[output] = full[output];
            continue;
        }
        for (std::size_t input = 0; input < usb16x16::kChannels; ++input) {
            test[output] += fold_test_gain(output, input) * static_cast<double>(dc[input]);
        }
    }
    check(stage.set_fold(0, 1), "full -> test");
    const std::size_t frames = 2 * n;
    std::vector<float> block = fold_dc(frames);
    stage.process(block.data(), frames);
    const std::vector<double> reference = crossfade_reference(full, test, n, frames);
    bool exact = true;
    bool bounded = true;
    double worst = 0.0;
    for (std::size_t frame = 0; frame < frames; ++frame) {
        for (std::size_t channel = 0; channel < usb16x16::kChannels; ++channel) {
            const std::size_t i = frame * usb16x16::kChannels + channel;
            if (block[i] != static_cast<float>(reference[i])) exact = false;
            if (frame == 0) continue;
            // One step of the crossfade moves |B - A| / N, plus float rounding.
            const double moved = std::abs(static_cast<double>(block[i]) - static_cast<double>(block[i - 16]));
            const double allowed = std::abs(test[channel] - full[channel]) / static_cast<double>(n) + 1e-7;
            worst = std::max(worst, moved / allowed);
            if (moved > allowed) bounded = false;
        }
    }
    check(exact, "the crossfade is the documented arithmetic, sample for sample");
    check(bounded, "no per-sample step exceeds |B - A| / N (plus a float ulp)");
    check(block[(n - 1) * 16 + 0] == static_cast<float>(test[0]) && block[(n - 2) * 16 + 0] != block[(n - 1) * 16 + 0],
          "the Nth sample lands exactly on the new fold, the one before it does not");
    check(worst > 0.5, "the bound has teeth: the crossfade does use it");
}

void test_monitor_fold_is_block_size_independent() {
    const std::vector<float> input = monitor_signal(3000);
    const auto run = [&](const std::size_t block) {
        auto stage = fold_stage();
        std::vector<float> out = input;
        // Requests at frames 0, 700 and 1500, each after the last crossfade
        // ended. (A request deferred by a crossfade starts at the next block
        // top, which does depend on the block size, by design.)
        for (std::size_t frame = 0; frame < 3000;) {
            if (frame == 0) stage.set_fold(0, 1);
            if (frame == 700) stage.set_fold(0, 2);
            if (frame == 1500) stage.set_fold(0, 0);
            std::size_t want = std::min<std::size_t>(block, 3000 - frame);
            for (const std::size_t at : {std::size_t{700}, std::size_t{1500}}) {
                if (frame < at) want = std::min(want, at - frame);
            }
            stage.process(out.data() + frame * usb16x16::kChannels, want);
            frame += want;
        }
        return out;
    };
    const std::vector<float> whole = run(3000);
    check(same_bytes(whole, run(7)) && same_bytes(whole, run(1)) && same_bytes(whole, run(480)),
          "folds and crossfades give the same samples whatever the block size");
}

void test_monitor_request_during_crossfade_waits() {
    auto stage = fold_stage();
    const std::size_t n = usb16x16::monitor_ramp_frames_fast(48000);
    std::vector<float> block = fold_dc(n);
    check(stage.set_fold(0, 1), "full -> test");
    stage.process(block.data(), 100);
    check(stage.fold_crossfading(0) && stage.fold(0) == 0, "crossfading, still on full");
    check(stage.set_fold(0, 2), "a new request mid-crossfade is stored");
    stage.process(block.data(), n - 100);
    check(stage.fold(0) == 1 && !stage.fold_crossfading(0), "the first crossfade finishes on its own target");
    stage.process(block.data(), 0);
    check(stage.fold_crossfading(0) && stage.fold(0) == 1, "the deferred request starts at the next block top");
    stage.process(block.data(), n);
    check(stage.fold(0) == 2 && !stage.fold_crossfading(0), "and finishes on it");
    // A request that comes back to the current fold during a crossfade still
    // lets the crossfade finish, then crossfades back.
    stage.set_fold(0, 0);
    stage.process(block.data(), 10);
    stage.set_fold(0, 2);
    stage.process(block.data(), n - 10);
    check(stage.fold(0) == 0, "the crossfade to full completed");
    stage.process(block.data(), 1);
    check(stage.fold_crossfading(0), "and the return to 'pass' then begins");
}

void test_monitor_set_fold_range_and_state() {
    auto stage = fold_stage();
    check(stage.set_fold(0, 2) && stage.set_fold(0, 0), "speakers: full, test, pass");
    check(!stage.set_fold(0, 3), "a fold past the set's list is refused");
    check(stage.set_fold(1, 0) && !stage.set_fold(1, 1), "headphones: full only");
    check(!stage.set_fold(2, 0), "a set past the list is refused");
    auto plain = usb16x16::DspStage::load(dsp_pinned_vector());
    check(!plain.set_fold(0, 0), "no section, no folds");
    check(plain.fold(0) == 0 && !plain.fold_crossfading(0), "and the accessors say full");
    // reset() leaves fold selection alone; a move carries it.
    stage.set_fold(0, 1);
    std::vector<float> block = fold_dc(480);
    stage.process(block.data(), 480);
    stage.reset();
    check(stage.fold(0) == 1, "reset keeps the fold");
    stage.set_fold(0, 2);
    usb16x16::DspStage moved = std::move(stage);
    check(moved.has_monitor() && !stage.has_monitor(), "a move transfers the section");
    moved.process(block.data(), 1);
    check(moved.fold_crossfading(0), "and the pending request with it");
    moved.process(block.data(), 480);
    check(moved.fold(0) == 2 && moved.monitor().sets[0].folds[2] == "pass", "the moved stage completes it");
}

} // namespace

int main() {
    test_monitor_default_is_untouched();
    test_monitor_ramp_reaches_its_target_exactly();
    test_monitor_retarget_mid_ramp_is_continuous();
    test_monitor_publish_keeps_other_ramps();
    test_monitor_is_block_size_independent();
    test_monitor_publish_refuses();
    test_monitor_zero_ramp_is_a_step();
    test_monitor_start_from_silence();
    test_monitor_ramp_constants();
    test_dsp_stage_is_inert_until_loaded();
    test_dsp_routing_gain_and_polarity();
    test_dsp_delay_moves_the_impulse();
    test_dsp_delay_is_the_largest_not_the_sum();
    test_dsp_crossover_branches_are_minus_six_at_the_corner();
    test_dsp_band_matches_its_design_gain();
    test_dsp_refuses_what_it_cannot_read();
    test_dsp_refuses_an_artifact_for_another_rate();
    test_dsp_reset_clears_filter_state();
    test_dsp_is_block_size_agnostic();
    test_sha256_known_vectors();
    test_dsp_shape_key_matches_the_pinned_vector();
    test_dsp_publish_keeps_filter_state();
    test_dsp_unity_skip_is_exact();
    test_dsp_unity_skip_survives_reset();
    test_dsp_publish_refuses_a_different_shape();
    test_dsp_publish_waits_for_the_audio_thread();
    test_dsp_publish_shrinking_delay_stays_in_bounds();
    test_dsp_moved_stage_keeps_working();
    test_monitor_section_shape_matches_the_pinned_vector();
    test_monitor_topology_accessors();
    test_monitor_section_loader_refuses();
    test_monitor_full_is_bit_identical_to_no_section();
    test_monitor_fold_applies_its_matrix();
    test_monitor_crossfade_is_bounded_and_exact();
    test_monitor_fold_is_block_size_independent();
    test_monitor_request_during_crossfade_waits();
    test_monitor_set_fold_range_and_state();

    test_level_meter_measures_a_window();
    test_level_meter_closes_windows_on_block_boundaries();
    test_level_meter_clip_count_is_cumulative();
    test_level_meter_snapshot_is_never_torn();

    test_packed_24();
    test_full_scale_conversion_does_not_wrap();
    test_ring_wrap();
    test_resampler_unity();
    test_resampler_long_run_rate();
    test_shared_estimator_sign_and_reciprocal();
    test_estimator_bounds();
    test_shared_rate_estimator();
    test_estimator_seed();
    test_level_servo();
    test_median_wake_interval();
    test_grid_phase();
    test_next_aligned_time();
    test_windowed_regression();
    test_applied_ratio_correction();
    test_zero_run_detector();
    test_impulse_trace_detector();
    if (failures != 0) {
        std::cerr << failures << " test(s) failed\n";
        return EXIT_FAILURE;
    }
    std::cout << "all bridge core tests passed\n";
    return EXIT_SUCCESS;
}
