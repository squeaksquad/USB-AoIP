// Mac-side test of the owner's PI law against a model of the plant: a depth fed
// by the rate difference of two clocks, steered through an integer ppm control,
// observed once a second with wake jitter on the reading.
//   c++ -std=c++20 -O2 -Wall -Wextra -Wpedantic -Werror -o /tmp/servo_test servo_test.cpp && /tmp/servo_test
#include "servo.hpp"

#include <cstdio>
#include <cstdlib>
#include <random>

using usb16x16::owner::PitchPi;
using usb16x16::owner::pitch_value;

namespace {

struct Outcome {
    double worst_error_after_settle{};
    double worst_error_ever{};
    double final_integral{};
};

// sign as pitch_value takes it: -1 models the outgoing direction, +1 the return.
Outcome run(double clock_offset_ppm, int sign, double seed_integral, double start_error, unsigned seconds) {
    PitchPi servo;
    servo.restart(seed_integral);
    std::mt19937 rng(7);
    std::normal_distribution<double> jitter(0.0, 1.5);   // frames of reading noise on a one-second mean
    double error = start_error;
    int pitch = pitch_value(servo.output(), sign);
    Outcome outcome;
    for (unsigned second = 0; second < seconds; ++second) {
        // Outgoing depth rises with the host's rate and with Capture Pitch;
        // the return queue falls with the host's rate and with Playback Pitch.
        const double applied_ppm = static_cast<double>(pitch - 1000000);
        const double rate_ppm = sign < 0 ? clock_offset_ppm + applied_ppm : -(clock_offset_ppm + applied_ppm);
        error += 0.048 * rate_ppm;
        const double offset = servo.update(error + jitter(rng), 1.0);
        pitch = pitch_value(offset, sign);
        outcome.worst_error_ever = std::max(outcome.worst_error_ever, std::abs(error));
        if (second >= 600) outcome.worst_error_after_settle = std::max(outcome.worst_error_after_settle, std::abs(error));
    }
    outcome.final_integral = servo.integral();
    return outcome;
}

int failures = 0;
void check(bool ok, const char* what, const Outcome& o) {
    std::printf("%s %s: worst %.1f frames, after 600 s %.1f, integral %.1f ppm\n", ok ? "ok  " : "FAIL", what,
                o.worst_error_ever, o.worst_error_after_settle, o.final_integral);
    if (!ok) ++failures;
}

}  // namespace

int main() {
    // A cold start against a 30 ppm crystal difference, each direction.
    Outcome out = run(30.0, -1, 0.0, 0.0, 1800);
    check(out.worst_error_ever < 48.0 && out.worst_error_after_settle < 6.0 && std::abs(out.final_integral - 30.0) < 3.0,
          "outgoing, +30 ppm, cold", out);
    Outcome back = run(30.0, +1, 0.0, 0.0, 1800);
    check(back.worst_error_ever < 48.0 && back.worst_error_after_settle < 6.0 && std::abs(back.final_integral + 30.0) < 3.0,
          "return, +30 ppm, cold", back);
    // The other way round, and a seeded start, which should barely move.
    Outcome negative = run(-40.0, -1, 0.0, 0.0, 1800);
    check(negative.worst_error_ever < 64.0 && negative.worst_error_after_settle < 6.0, "outgoing, -40 ppm, cold", negative);
    Outcome seeded = run(30.0, +1, -30.0, 0.0, 1800);
    check(seeded.worst_error_ever < 8.0, "return, +30 ppm, seeded from the other direction", seeded);
    // A start 40 frames off the setpoint with the offset known.
    Outcome offset = run(30.0, -1, 30.0, 40.0, 1800);
    check(offset.worst_error_ever < 41.0 && offset.worst_error_after_settle < 6.0, "outgoing, 40 frames high, seeded", offset);
    // The control saturates rather than winding up when the offset is out of range.
    Outcome wild = run(400.0, -1, 0.0, 0.0, 120);
    check(std::abs(wild.final_integral) <= 250.0, "outgoing, 400 ppm (out of range), no wind-up", wild);
    return failures == 0 ? 0 : 1;
}
