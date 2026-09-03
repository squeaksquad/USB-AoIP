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
    test_windowed_regression();
    test_applied_ratio_correction();
    if (failures != 0) {
        std::cerr << failures << " test(s) failed\n";
        return EXIT_FAILURE;
    }
    std::cout << "all bridge core tests passed\n";
    return EXIT_SUCCESS;
}
