// Mac-side test of the owner's rate rules (rate_check.hpp).
//   c++ -std=c++20 -O2 -Wall -Wextra -Wpedantic -Werror -o /tmp/rate_check_test rate_check_test.cpp && /tmp/rate_check_test
// (one line)
#include "rate_check.hpp"

#include <cstdio>

using usb16x16::owner::GadgetRate;
using usb16x16::owner::is_dante_rate;
using usb16x16::owner::judge_gadget_rate;

namespace {

int failures = 0;

void check(bool condition, const char* message) {
    if (!condition) {
        std::printf("FAIL: %s\n", message);
        ++failures;
    }
}

void test_dante_rates() {
    check(usb16x16::owner::kDefaultRate == 48000, "the default is 48 kHz, as kRate was");
    for (const unsigned rate : {44100U, 48000U, 88200U, 96000U, 176400U, 192000U}) {
        check(is_dante_rate(rate), "every Dante rate is accepted");
    }
    for (const unsigned rate : {0U, 32000U, 47999U, 48001U, 64000U, 384000U}) {
        check(!is_dante_rate(rate), "anything else is refused");
    }
}

void test_gadget_rate() {
    check(judge_gadget_rate(48000, 48000, 48000) == GadgetRate::match, "both controls at --rate: join");
    check(judge_gadget_rate(0, 0, 48000) == GadgetRate::unknown, "host interface down: not known, open as before");
    check(judge_gadget_rate(-2, -2, 48000) == GadgetRate::unknown, "no controls on this kernel: not known");
    check(judge_gadget_rate(48000, 0, 48000) == GadgetRate::unknown, "one direction up at --rate: not known yet");
    check(judge_gadget_rate(96000, 96000, 48000) == GadgetRate::mismatch, "host at 96 kHz, owner at 48: stay closed");
    check(judge_gadget_rate(44100, 0, 48000) == GadgetRate::mismatch, "one direction at another rate: stay closed");
    check(judge_gadget_rate(48000, 44100, 48000) == GadgetRate::mismatch, "the two directions disagree: stay closed");
    check(judge_gadget_rate(96000, 96000, 96000) == GadgetRate::match, "the rule is --rate, not 48 kHz");
    check(judge_gadget_rate(48000, 48000, 96000) == GadgetRate::mismatch, "a 48 kHz host is refused at 96 kHz");
}

}  // namespace

int main() {
    test_dante_rates();
    test_gadget_rate();
    std::printf(failures == 0 ? "rate_check_test: all passed\n" : "rate_check_test: %d FAILED\n", failures);
    return failures == 0 ? 0 : 1;
}
