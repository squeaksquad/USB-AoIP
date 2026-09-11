#include "usb16x16/bridge_core.hpp"

#include <array>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstdlib>
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

} // namespace

int main() {
    test_dsp_stage_is_inert_until_loaded();
    test_dsp_routing_gain_and_polarity();
    test_dsp_delay_moves_the_impulse();
    test_dsp_delay_is_the_largest_not_the_sum();
    test_dsp_crossover_branches_are_minus_six_at_the_corner();
    test_dsp_band_matches_its_design_gain();
    test_dsp_refuses_what_it_cannot_read();
    test_dsp_reset_clears_filter_state();
    test_dsp_is_block_size_agnostic();

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
