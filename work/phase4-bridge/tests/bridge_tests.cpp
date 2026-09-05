#include "usb16x16/bridge_core.hpp"

#include <array>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <string_view>
#include <vector>

namespace {

int failures = 0;

void check(const bool condition, const std::string_view message) {
    if (!condition) {
        std::cerr << "FAIL: " << message << '\n';
        ++failures;
    }
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
    if (failures != 0) {
        std::cerr << failures << " test(s) failed\n";
        return EXIT_FAILURE;
    }
    std::cout << "all bridge core tests passed\n";
    return EXIT_SUCCESS;
}
