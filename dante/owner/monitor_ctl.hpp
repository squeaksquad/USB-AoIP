// The monitor block's control (phase 3, step 3): what the page asks for,
// what root allows, and what the owner plays, as one object with a poll() the
// owner's monitor thread calls every 10 ms. The three files and every rule
// for reading and writing them are docs/web/MONITOR-FILES.md; this follows
// that file, not the web service's code.
//
//   state   /run/usb-aoip-monitor/state            the web service writes it
//           /var/lib/usb-aoip-monitor/state        its remembered copy
//   limits  /var/lib/usb16x16-apply/monitor-limits root's applier writes it
//   status  /run/usb16x16-dante/monitor.status     written here
//
// Both inputs are untrusted. A file is read with O_NOFOLLOW | O_NONBLOCK, must
// be a regular file no larger than its cap, ASCII, lines in the fixed order,
// every number in its range; anything else is invalid and invalid is absent:
// nothing of it is used. Nothing here throws past the API.
//
// What plays, resolve(): per set, level = min(level, max_db), total =
// min(level + trim, max_db, 0 dB), plus dim_db when the set is dimmed; the
// gain is 10^(total/20), 0 when the set is muted or is a speakers set that is
// not the active one (`all` plays every set; headphones ignore `active`). A
// set of the preset with no state line plays at its reference (limits),
// clamped, trim 0, nothing on. An `active` the preset does not have as a
// speakers set is taken as the preset's first speakers set: never louder than
// asked. Per output: its set's gain; a sub shared by speaker sets follows the
// active set when that is one of its own, is silent when another set is
// active, and follows the first of its sets under `all`. Then subs=off
// silences role sub, an output mute silences the output, and a solo is scoped
// to one set: any soloed output of a set silences every unsoloed output of
// that set (a soloed main silences its subs too). An output in no set is
// untouched (gain 1, its flags ignored).
//
// Publishing to MonitorGains: per output, a 40 ms ramp when only levels and
// trims moved since the last published state, 10 ms when any flag did (dim,
// mute, active, subs, solo, output mute, dim_db, the limits, a fold). A set
// switch (the effective active set changed) is two publishes: first every
// output at min(old, new), 10 ms, so what goes down goes down; then, on a poll
// at least 10 ms after the audio thread has taken that one, the new gains at
// 10 ms. A change arriving between them replaces the final target (and, when
// it lowers something further, publishes a lower first step and restarts the
// wait). MonitorControl must be the gains' only publisher: it counts its
// publishes to know when one has been taken.
//
// The start rule, at the first poll when there is no valid state file (the
// owner's first start since boot, MONITOR-FILES.md): limits start=last takes
// the remembered copy (validated the same way, its solo ignored), and with
// none every set at min(start_db, max_db); start=reference takes the copy for
// everything but the levels, which are each set's reference; start=fixed
// likewise with start_db. Sets the copy does not list start at
// min(start_db, max_db) under `last`. With no copy: the first speakers set
// active, dim_db -20.0, subs on, nothing muted. The status then says
// state=start until a valid state file is read (an invalid one meanwhile
// only sets the reason).
//
// A stage with no monitor section (or no preset) writes one status, state=idle
// with no set or out lines, and does nothing else: the web service takes the
// file's existence as this owner knowing the monitor.
//
// Control thread only; allocation is fine here. No ALSA, so
// monitor_ctl_test.cpp and monitor_sim.cpp build and run on the Mac.
#pragma once

#include "usb16x16/bridge_core.hpp"

#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cerrno>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <initializer_list>
#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace usb16x16::owner::monitor {

constexpr std::size_t kFileCap = 8192;      // state and limits
constexpr std::size_t kStatusCap = 16384;
constexpr std::size_t kMaxSets = 16;        // set lines in a state file, ref lines, status set lines
constexpr std::size_t kMaxOutLines = 64;
constexpr std::size_t kMaxFolds = 8;
constexpr std::size_t kNoteMax = 64;
constexpr std::size_t kLabelMax = 64;
constexpr std::size_t kReasonMax = 128;
constexpr std::size_t npos = static_cast<std::size_t>(-1);

// dB in tenths. Every number in the files has exactly one decimal, so the sums
// resolve() makes are exact and print back as they were read.
using Tenths = int;

struct SetState {
    std::string id;
    Tenths level{-300};
    Tenths trim{0};
    bool dim{false};
    bool mute{false};
    std::string fold{"full"};
    bool operator==(const SetState&) const = default;
};

struct State {
    std::uint64_t seq{0};
    std::string active{"all"};
    Tenths dim_db{-200};
    bool subs{true};
    std::vector<SetState> sets;
    std::array<bool, kChannels> solo{};
    std::array<bool, kChannels> out_mute{};
    bool operator==(const State&) const = default;

    [[nodiscard]] const SetState* find(std::string_view id) const noexcept {
        for (const SetState& set : sets) {
            if (set.id == id) return &set;
        }
        return nullptr;
    }
};

enum class StartRule { last, reference, fixed };

struct Ref {
    std::string id;
    Tenths level{-100};
    std::string note;
    bool operator==(const Ref&) const = default;
};

// The defaults are what an absent or invalid file means.
struct Limits {
    Tenths max_db{0};
    StartRule start{StartRule::last};
    Tenths start_db{-300};
    bool lock{false};
    std::vector<Ref> refs;
    bool operator==(const Limits&) const = default;

    // A set's reference, clamped to max_db (-10.0 when it has no ref line).
    [[nodiscard]] Tenths reference(std::string_view id) const noexcept {
        for (const Ref& ref : refs) {
            if (ref.id == id) return std::min(ref.level, max_db);
        }
        return std::min(-100, max_db);
    }
    [[nodiscard]] Tenths start_level() const noexcept { return std::min(start_db, max_db); }
};

enum class Mode { idle, start, applied, refused };

[[nodiscard]] inline const char* mode_name(const Mode mode) noexcept {
    switch (mode) {
    case Mode::idle: return "idle";
    case Mode::start: return "start";
    case Mode::applied: return "applied";
    case Mode::refused: return "refused";
    }
    return "idle";
}

struct StatusSet {
    std::string id;
    bool headphones{false};
    Tenths level{};
    Tenths trim{};
    bool dim{false};
    bool mute{false};
    std::string fold;
    std::vector<std::string> folds;
    std::optional<Tenths> gain;   // nullopt is -inf
    bool operator==(const StatusSet&) const = default;
};

struct StatusOut {
    std::size_t n{};
    std::string set;
    bool sub{false};
    std::string label;
    bool operator==(const StatusOut&) const = default;
};

struct Status {
    std::uint64_t gen{1};
    std::optional<std::uint64_t> seq;   // nullopt is none
    Mode mode{Mode::idle};
    std::string reason;
    std::uint64_t t_us{0};
    std::string active{"all"};
    Tenths dim_db{-200};
    bool subs{true};
    std::vector<StatusSet> sets;
    std::vector<StatusOut> outs;
    std::array<bool, kChannels> solo{};
    std::array<bool, kChannels> out_mute{};
    bool operator==(const Status&) const = default;
};

// ------------------------------------------------------------------ text

namespace detail {

// One line of a monitor file, matched left to right, field by field. Any
// mismatch clears ok() and every later call fails too.
class Scan {
public:
    explicit Scan(std::string_view text) noexcept : rest_(text) {}

    bool lit(std::string_view expected) noexcept {
        if (!ok_ || rest_.substr(0, expected.size()) != expected) return ok_ = false;
        rest_.remove_prefix(expected.size());
        return true;
    }
    // A run of digits, `low` to `high` of them.
    bool digits(std::size_t low, std::size_t high, std::uint64_t& value) noexcept {
        const std::size_t length = run([](char c) { return c >= '0' && c <= '9'; });
        if (!ok_ || length < low || length > high) return ok_ = false;
        value = 0;
        for (std::size_t i = 0; i < length; ++i) {
            const auto digit = static_cast<std::uint64_t>(rest_[i] - '0');
            // Twenty digits can pass 2^64: t_us only, and it is only ordered, so it saturates.
            value = value > (UINT64_MAX - digit) / 10 ? UINT64_MAX : value * 10 + digit;
        }
        rest_.remove_prefix(length);
        return true;
    }
    // -?[0-9]{1,3}\.[0-9], into tenths, then `low` to `high` (tenths).
    bool db(Tenths& value, Tenths low, Tenths high) noexcept {
        if (!ok_) return false;
        std::string_view at = rest_;
        bool negative = false;
        if (!at.empty() && at[0] == '-') {
            negative = true;
            at.remove_prefix(1);
        }
        std::size_t whole = 0;
        int magnitude = 0;
        while (whole < at.size() && whole < 4 && at[whole] >= '0' && at[whole] <= '9') {
            magnitude = magnitude * 10 + (at[whole] - '0');
            ++whole;
        }
        if (whole < 1 || whole > 3 || at.size() < whole + 2 || at[whole] != '.' || at[whole + 1] < '0' ||
            at[whole + 1] > '9') {
            return ok_ = false;
        }
        magnitude = magnitude * 10 + (at[whole + 1] - '0');
        const Tenths parsed = negative ? -magnitude : magnitude;
        if (parsed < low || parsed > high) return ok_ = false;
        value = parsed;
        rest_.remove_prefix((negative ? 1 : 0) + whole + 2);
        return true;
    }
    bool flag(bool& value) noexcept {
        if (!ok_ || rest_.empty() || (rest_[0] != '0' && rest_[0] != '1')) return ok_ = false;
        value = rest_[0] == '1';
        rest_.remove_prefix(1);
        return true;
    }
    bool flags16(std::array<bool, kChannels>& values) noexcept {
        for (std::size_t i = 0; i < kChannels; ++i) {
            if (i != 0) lit(",");
            flag(values[i]);
        }
        return ok_;
    }
    // [a-z][a-z0-9-]{0,31}
    bool ident(std::string& value) {
        const std::size_t length = run([](char c) { return (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-'; });
        if (!ok_ || length < 1 || length > 32 || rest_[0] < 'a' || rest_[0] > 'z') return ok_ = false;
        value.assign(rest_.substr(0, length));
        rest_.remove_prefix(length);
        return true;
    }
    // [a-z0-9.]{1,16}
    bool fold(std::string& value) {
        const std::size_t length = run([](char c) { return (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '.'; });
        if (!ok_ || length < 1 || length > 16) return ok_ = false;
        value.assign(rest_.substr(0, length));
        rest_.remove_prefix(length);
        return true;
    }
    // "..." of at most `most` printable characters without " and backslash.
    bool quoted(std::size_t most, std::string& value) {
        if (!lit("\"")) return false;
        const std::size_t length = run([](char c) { return c >= ' ' && c <= '~' && c != '"' && c != '\\'; });
        if (!ok_ || length > most) return ok_ = false;
        value.assign(rest_.substr(0, length));
        rest_.remove_prefix(length);
        return lit("\"");
    }
    // One of `words`, which must end the field (a space or the end of the line follows).
    bool choice(std::initializer_list<std::string_view> words, std::size_t& index) noexcept {
        if (!ok_) return false;
        std::size_t at = 0;
        for (const std::string_view word : words) {
            if (rest_.substr(0, word.size()) == word && (rest_.size() == word.size() || rest_[word.size()] == ' ')) {
                index = at;
                rest_.remove_prefix(word.size());
                return true;
            }
            ++at;
        }
        return ok_ = false;
    }
    // Whether what is left starts with `text` (nothing consumed).
    [[nodiscard]] bool starts(std::string_view text) const noexcept { return ok_ && rest_.substr(0, text.size()) == text; }
    [[nodiscard]] bool done() const noexcept { return ok_ && rest_.empty(); }
    [[nodiscard]] bool ok() const noexcept { return ok_; }

private:
    template <typename Accept>
    std::size_t run(Accept accept) const noexcept {
        std::size_t length = 0;
        while (length < rest_.size() && accept(rest_[length])) ++length;
        return length;
    }

    std::string_view rest_;
    bool ok_{true};
};

// The lines of a file, after the rules every file shares: ASCII printable
// and newline only (no CR, no tab, nothing above 0x7E), every line ended by a
// newline, the last line `end`. False with `reason` otherwise.
inline bool split_lines(std::string_view text, std::vector<std::string_view>& lines, std::string& reason) {
    for (const char c : text) {
        if (c != '\n' && (c < ' ' || c > '~')) {
            reason = "a byte that is not printable ASCII (or a CR or tab)";
            return false;
        }
    }
    if (text.size() < 4 || text.substr(text.size() - 4) != "end\n" ||
        (text.size() > 4 && text[text.size() - 5] != '\n')) {
        reason = "does not end with an end line";
        return false;
    }
    lines.clear();
    std::size_t start = 0;
    while (start < text.size()) {
        const std::size_t end = text.find('\n', start);
        lines.push_back(text.substr(start, end - start));
        start = end + 1;
    }
    return true;
}

inline std::string line_reason(std::size_t index, const char* what) {
    return "line " + std::to_string(index + 1) + " is not the " + what + " line";
}

inline void append_db(std::string& out, const Tenths value) {
    if (value < 0) out += '-';
    const int magnitude = value < 0 ? -value : value;
    out += std::to_string(magnitude / 10);
    out += '.';
    out += static_cast<char>('0' + magnitude % 10);
}

inline void append_flags(std::string& out, const std::array<bool, kChannels>& flags) {
    for (std::size_t i = 0; i < kChannels; ++i) {
        if (i != 0) out += ',';
        out += flags[i] ? '1' : '0';
    }
}

}  // namespace detail

// Quoted text as the files allow it: printable ASCII without " and
// backslash (replaced by ' and /), at most `most` characters.
[[nodiscard]] inline std::string quotable(std::string_view text, std::size_t most) {
    std::string out;
    for (const char c : text) {
        if (out.size() >= most) break;
        if (c == '"') out += '\'';
        else if (c == '\\') out += '/';
        else if (c >= ' ' && c <= '~') out += c;
        else out += '?';
    }
    return out;
}

[[nodiscard]] inline std::string db_text(const Tenths value) {
    std::string out;
    detail::append_db(out, value);
    return out;
}

// MONITOR-FILES.md (a). nullopt with `reason` when any rule is broken.
[[nodiscard]] inline std::optional<State> parse_state(std::string_view text, std::string& reason) noexcept {
    try {
        std::vector<std::string_view> lines;
        if (!detail::split_lines(text, lines, reason)) return std::nullopt;
        std::size_t at = 0;
        const auto next = [&]() -> std::string_view { return at < lines.size() ? lines[at] : std::string_view{}; };
        State state;
        {
            detail::Scan scan(next());
            scan.lit("MONITOR-STATE v=1 seq=");
            scan.digits(1, 18, state.seq);
            if (!scan.done()) return reason = detail::line_reason(at, "header"), std::nullopt;
            ++at;
        }
        {
            detail::Scan scan(next());
            scan.lit("active=");
            scan.ident(state.active);
            if (!scan.done()) return reason = detail::line_reason(at, "active"), std::nullopt;
            ++at;
        }
        {
            detail::Scan scan(next());
            scan.lit("dim_db=");
            scan.db(state.dim_db, -400, 0);
            if (!scan.done()) return reason = detail::line_reason(at, "dim_db (-40.0 to 0.0)"), std::nullopt;
            ++at;
        }
        {
            detail::Scan scan(next());
            std::size_t subs = 0;
            scan.lit("subs=");
            scan.choice({"on", "off"}, subs);
            if (!scan.done()) return reason = detail::line_reason(at, "subs"), std::nullopt;
            state.subs = subs == 0;
            ++at;
        }
        while (next().substr(0, 4) == "set ") {
            SetState set;
            detail::Scan scan(next());
            scan.lit("set id=");
            scan.ident(set.id);
            scan.lit(" level_db=");
            scan.db(set.level, -600, 0);
            scan.lit(" trim_db=");
            scan.db(set.trim, -120, 120);
            scan.lit(" dim=");
            scan.flag(set.dim);
            scan.lit(" mute=");
            scan.flag(set.mute);
            scan.lit(" fold=");
            scan.fold(set.fold);
            if (!scan.done()) return reason = detail::line_reason(at, "set (or a number out of range)"), std::nullopt;
            if (state.find(set.id) != nullptr) return reason = "set " + set.id + " is listed twice", std::nullopt;
            if (state.sets.size() >= kMaxSets) return reason = "more than 16 sets", std::nullopt;
            state.sets.push_back(std::move(set));
            ++at;
        }
        if (state.active != "all" && state.find(state.active) == nullptr) {
            return reason = "the active set " + state.active + " is not listed", std::nullopt;
        }
        {
            detail::Scan scan(next());
            scan.lit("solo=");
            scan.flags16(state.solo);
            if (!scan.done()) return reason = detail::line_reason(at, "solo"), std::nullopt;
            ++at;
        }
        {
            detail::Scan scan(next());
            scan.lit("mute=");
            scan.flags16(state.out_mute);
            if (!scan.done()) return reason = detail::line_reason(at, "mute"), std::nullopt;
            ++at;
        }
        if (next() != "end") return reason = detail::line_reason(at, "end"), std::nullopt;
        if (++at != lines.size()) return reason = "lines after end", std::nullopt;
        return state;
    } catch (...) {
        reason = "out of memory";
        return std::nullopt;
    }
}

[[nodiscard]] inline std::string render_state(const State& state) {
    std::string out = "MONITOR-STATE v=1 seq=" + std::to_string(state.seq) + "\nactive=" + state.active + "\ndim_db=";
    detail::append_db(out, state.dim_db);
    out += std::string("\nsubs=") + (state.subs ? "on" : "off") + "\n";
    for (const SetState& set : state.sets) {
        out += "set id=" + set.id + " level_db=";
        detail::append_db(out, set.level);
        out += " trim_db=";
        detail::append_db(out, set.trim);
        out += std::string(" dim=") + (set.dim ? "1" : "0") + " mute=" + (set.mute ? "1" : "0") + " fold=" + set.fold + "\n";
    }
    out += "solo=";
    detail::append_flags(out, state.solo);
    out += "\nmute=";
    detail::append_flags(out, state.out_mute);
    return out + "\nend\n";
}

// MONITOR-FILES.md (b). start_db and every ref level come back clamped to max_db.
[[nodiscard]] inline std::optional<Limits> parse_limits(std::string_view text, std::string& reason) noexcept {
    try {
        std::vector<std::string_view> lines;
        if (!detail::split_lines(text, lines, reason)) return std::nullopt;
        if (lines.size() < 6) return reason = "too few lines", std::nullopt;
        Limits limits;
        if (lines[0] != "MONITOR-LIMITS v=1") return reason = detail::line_reason(0, "header"), std::nullopt;
        {
            detail::Scan scan(lines[1]);
            scan.lit("max_db=");
            scan.db(limits.max_db, -300, 0);
            if (!scan.done()) return reason = detail::line_reason(1, "max_db (-30.0 to 0.0)"), std::nullopt;
        }
        {
            detail::Scan scan(lines[2]);
            std::size_t rule = 0;
            scan.lit("start=");
            scan.choice({"last", "reference", "fixed"}, rule);
            if (!scan.done()) return reason = detail::line_reason(2, "start"), std::nullopt;
            limits.start = rule == 0 ? StartRule::last : rule == 1 ? StartRule::reference : StartRule::fixed;
        }
        {
            detail::Scan scan(lines[3]);
            scan.lit("start_db=");
            scan.db(limits.start_db, -600, 0);
            if (!scan.done()) return reason = detail::line_reason(3, "start_db (-60.0 to 0.0)"), std::nullopt;
        }
        {
            detail::Scan scan(lines[4]);
            scan.lit("lock=");
            scan.flag(limits.lock);
            if (!scan.done()) return reason = detail::line_reason(4, "lock"), std::nullopt;
        }
        for (std::size_t at = 5; at + 1 < lines.size(); ++at) {
            Ref ref;
            detail::Scan scan(lines[at]);
            scan.lit("ref id=");
            scan.ident(ref.id);
            scan.lit(" level_db=");
            scan.db(ref.level, -600, 0);
            scan.lit(" note=");
            scan.quoted(kNoteMax, ref.note);
            if (!scan.done()) return reason = detail::line_reason(at, "ref"), std::nullopt;
            for (const Ref& other : limits.refs) {
                if (other.id == ref.id) return reason = "ref " + ref.id + " is listed twice", std::nullopt;
            }
            if (limits.refs.size() >= kMaxSets) return reason = "more than 16 refs", std::nullopt;
            ref.level = std::min(ref.level, limits.max_db);
            limits.refs.push_back(std::move(ref));
        }
        limits.start_db = std::min(limits.start_db, limits.max_db);
        return limits;
    } catch (...) {
        reason = "out of memory";
        return std::nullopt;
    }
}

[[nodiscard]] inline std::string render_limits(const Limits& limits) {
    static constexpr const char* kRules[] = {"last", "reference", "fixed"};
    std::string out = "MONITOR-LIMITS v=1\nmax_db=";
    detail::append_db(out, limits.max_db);
    out += std::string("\nstart=") + kRules[static_cast<int>(limits.start)] + "\nstart_db=";
    detail::append_db(out, limits.start_db);
    out += std::string("\nlock=") + (limits.lock ? "1" : "0") + "\n";
    for (const Ref& ref : limits.refs) {
        out += "ref id=" + ref.id + " level_db=";
        detail::append_db(out, ref.level);
        out += " note=\"" + ref.note + "\"\n";
    }
    return out + "end\n";
}

[[nodiscard]] inline std::string render_status(const Status& status) {
    std::string out = "MONITOR v=1 gen=" + std::to_string(status.gen) +
                      " seq=" + (status.seq ? std::to_string(*status.seq) : std::string("none")) +
                      " state=" + mode_name(status.mode) + " reason=\"" + status.reason +
                      "\" t_us=" + std::to_string(status.t_us) + "\nactive=" + status.active + "\ndim_db=";
    detail::append_db(out, status.dim_db);
    out += std::string(" subs=") + (status.subs ? "on" : "off") + "\n";
    for (const StatusSet& set : status.sets) {
        out += "set id=" + set.id + " kind=" + (set.headphones ? "headphones" : "speakers") + " level_db=";
        detail::append_db(out, set.level);
        out += " trim_db=";
        detail::append_db(out, set.trim);
        out += std::string(" dim=") + (set.dim ? "1" : "0") + " mute=" + (set.mute ? "1" : "0") + " fold=" + set.fold + " folds=";
        for (std::size_t i = 0; i < set.folds.size(); ++i) out += (i == 0 ? "" : ",") + set.folds[i];
        out += " gain_db=";
        if (set.gain) detail::append_db(out, *set.gain);
        else out += "-inf";
        out += "\n";
    }
    for (const StatusOut& o : status.outs) {
        out += "out n=" + std::to_string(o.n) + " set=" + o.set + " role=" + (o.sub ? "sub" : "speaker") + " label=\"" +
               o.label + "\"\n";
    }
    out += "solo=";
    detail::append_flags(out, status.solo);
    out += " mute=";
    detail::append_flags(out, status.out_mute);
    return out + "\nend\n";
}

// MONITOR-FILES.md (c): the web service's reading of what this writes, so the
// tests can hold the writer to the contract.
[[nodiscard]] inline std::optional<Status> parse_status(std::string_view text, std::string& reason) noexcept {
    try {
        std::vector<std::string_view> lines;
        if (!detail::split_lines(text, lines, reason)) return std::nullopt;
        std::size_t at = 0;
        const auto next = [&]() -> std::string_view { return at < lines.size() ? lines[at] : std::string_view{}; };
        Status status;
        {
            detail::Scan scan(next());
            std::uint64_t seq = 0;
            std::size_t mode = 0;
            scan.lit("MONITOR v=1 gen=");
            scan.digits(1, 18, status.gen);
            scan.lit(" seq=");
            if (scan.starts("none")) {
                scan.lit("none");
            } else {
                scan.digits(1, 18, seq);
                status.seq = seq;
            }
            scan.lit(" state=");
            scan.choice({"idle", "start", "applied", "refused"}, mode);
            scan.lit(" reason=");
            scan.quoted(kReasonMax, status.reason);
            scan.lit(" t_us=");
            scan.digits(1, 20, status.t_us);
            if (!scan.done()) return reason = detail::line_reason(at, "header"), std::nullopt;
            status.mode = static_cast<Mode>(mode);
            ++at;
        }
        {
            detail::Scan scan(next());
            scan.lit("active=");
            scan.ident(status.active);
            if (!scan.done()) return reason = detail::line_reason(at, "active"), std::nullopt;
            ++at;
        }
        {
            detail::Scan scan(next());
            std::size_t subs = 0;
            scan.lit("dim_db=");
            scan.db(status.dim_db, -400, 0);
            scan.lit(" subs=");
            scan.choice({"on", "off"}, subs);
            if (!scan.done()) return reason = detail::line_reason(at, "dim_db"), std::nullopt;
            status.subs = subs == 0;
            ++at;
        }
        while (next().substr(0, 4) == "set ") {
            StatusSet set;
            detail::Scan scan(next());
            std::size_t kind = 0;
            scan.lit("set id=");
            scan.ident(set.id);
            scan.lit(" kind=");
            scan.choice({"speakers", "headphones"}, kind);
            scan.lit(" level_db=");
            scan.db(set.level, -600, 0);
            scan.lit(" trim_db=");
            scan.db(set.trim, -120, 120);
            scan.lit(" dim=");
            scan.flag(set.dim);
            scan.lit(" mute=");
            scan.flag(set.mute);
            scan.lit(" fold=");
            scan.fold(set.fold);
            scan.lit(" folds=");
            do {
                std::string fold;
                if (!scan.fold(fold)) break;
                set.folds.push_back(std::move(fold));
            } while (set.folds.size() <= kMaxFolds && scan.starts(",") && scan.lit(","));
            scan.lit(" gain_db=");
            if (scan.starts("-inf")) {
                scan.lit("-inf");
            } else {
                Tenths gain = 0;
                scan.db(gain, -9999, 9999);
                set.gain = gain;
            }
            set.headphones = kind == 1;
            if (!scan.done() || set.folds.empty() || set.folds.size() > kMaxFolds) {
                return reason = detail::line_reason(at, "set"), std::nullopt;
            }
            std::vector<std::string> sorted = set.folds;
            std::sort(sorted.begin(), sorted.end());
            if (std::adjacent_find(sorted.begin(), sorted.end()) != sorted.end() ||
                std::find(sorted.begin(), sorted.end(), "full") == sorted.end() ||
                std::find(sorted.begin(), sorted.end(), set.fold) == sorted.end()) {
                return reason = "set " + set.id + ": folds must be distinct, include full and the set's fold", std::nullopt;
            }
            for (const StatusSet& other : status.sets) {
                if (other.id == set.id) return reason = "set " + set.id + " is listed twice", std::nullopt;
            }
            if (status.sets.size() >= kMaxSets) return reason = "more than 16 sets", std::nullopt;
            status.sets.push_back(std::move(set));
            ++at;
        }
        const auto listed = [&](const std::string& id) {
            return std::any_of(status.sets.begin(), status.sets.end(), [&](const StatusSet& s) { return s.id == id; });
        };
        if (status.active != "all" && !listed(status.active)) {
            return reason = "the active set " + status.active + " is not listed", std::nullopt;
        }
        while (next().substr(0, 4) == "out ") {
            StatusOut o;
            detail::Scan scan(next());
            std::uint64_t n = 0;
            std::size_t role = 0;
            scan.lit("out n=");
            scan.digits(1, 2, n);
            scan.lit(" set=");
            scan.ident(o.set);
            scan.lit(" role=");
            scan.choice({"speaker", "sub"}, role);
            scan.lit(" label=");
            scan.quoted(kLabelMax, o.label);
            if (!scan.done()) return reason = detail::line_reason(at, "out"), std::nullopt;
            o.n = static_cast<std::size_t>(n);
            o.sub = role == 1;
            const bool repeated = std::any_of(status.outs.begin(), status.outs.end(),
                                              [&](const StatusOut& other) { return other.n == o.n && other.set == o.set; });
            if (o.n > 15 || !listed(o.set) || repeated || status.outs.size() >= kMaxOutLines) {
                return reason = "line " + std::to_string(at + 1) + ": an output out of range, of an unknown set or repeated",
                       std::nullopt;
            }
            status.outs.push_back(std::move(o));
            ++at;
        }
        {
            detail::Scan scan(next());
            scan.lit("solo=");
            scan.flags16(status.solo);
            scan.lit(" mute=");
            scan.flags16(status.out_mute);
            if (!scan.done()) return reason = detail::line_reason(at, "solo"), std::nullopt;
            ++at;
        }
        if (next() != "end") return reason = detail::line_reason(at, "end"), std::nullopt;
        if (++at != lines.size()) return reason = "lines after end", std::nullopt;
        return status;
    } catch (...) {
        reason = "out of memory";
        return std::nullopt;
    }
}

// ------------------------------------------------------------------ files

enum class Read { ok, absent, invalid };

// The reading rule: no link followed, never blocking on a FIFO, a regular
// file of at most `cap` bytes (cap + 1 are read to tell).
[[nodiscard]] inline Read read_file(const std::string& path, std::size_t cap, std::string& text, std::string& reason) noexcept {
    try {
        const int descriptor = ::open(path.c_str(), O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
        if (descriptor < 0) {
            if (errno == ENOENT || errno == ENOTDIR) return Read::absent;
            reason = errno == ELOOP ? "a symbolic link" : std::string("cannot be opened: ") + std::strerror(errno);
            return Read::invalid;
        }
        struct stat info {};
        if (::fstat(descriptor, &info) != 0 || !S_ISREG(info.st_mode)) {
            ::close(descriptor);
            reason = "not a regular file";
            return Read::invalid;
        }
        text.assign(cap + 1, '\0');
        std::size_t total = 0;
        while (total < cap + 1) {
            const ssize_t got = ::read(descriptor, text.data() + total, cap + 1 - total);
            if (got < 0) {
                if (errno == EINTR) continue;
                ::close(descriptor);
                reason = std::string("cannot be read: ") + std::strerror(errno);
                return Read::invalid;
            }
            if (got == 0) break;
            total += static_cast<std::size_t>(got);
        }
        ::close(descriptor);
        if (total > cap) {
            reason = "larger than " + std::to_string(cap) + " bytes";
            return Read::invalid;
        }
        text.resize(total);
        return Read::ok;
    } catch (...) {
        reason = "out of memory";
        return Read::invalid;
    }
}

// The writing rule: a temporary file beside `path` whose name starts with a
// dot, created O_CREAT | O_EXCL | O_NOFOLLOW, mode 0644 by fchmod whatever the
// umask, written whole, fsync'd, renamed over the file. False when any step
// failed; the old file, if any, is left as it was.
[[nodiscard]] inline bool write_file(const std::string& path, const std::string& text) noexcept {
    try {
        static std::atomic<unsigned> counter{0};
        const std::size_t slash = path.rfind('/');
        const std::string directory = slash == std::string::npos ? std::string() : path.substr(0, slash + 1);
        const std::string name = slash == std::string::npos ? path : path.substr(slash + 1);
        const std::string temporary = directory + "." + name + "." + std::to_string(::getpid()) + "." +
                                      std::to_string(counter.fetch_add(1, std::memory_order_relaxed)) + ".tmp";
        const int descriptor = ::open(temporary.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0644);
        if (descriptor < 0) return false;
        bool ok = ::fchmod(descriptor, 0644) == 0;
        std::size_t written = 0;
        while (ok && written < text.size()) {
            const ssize_t result = ::write(descriptor, text.data() + written, text.size() - written);
            if (result < 0) {
                if (errno == EINTR) continue;
                ok = false;
                break;
            }
            written += static_cast<std::size_t>(result);
        }
        ok = ok && ::fsync(descriptor) == 0;
        ok = ::close(descriptor) == 0 && ok;
        if (!ok || std::rename(temporary.c_str(), path.c_str()) != 0) {
            ::unlink(temporary.c_str());
            return false;
        }
        return true;
    } catch (...) {
        return false;
    }
}

// ------------------------------------------------------------------ resolve

struct ResolvedSet {
    Tenths level{};
    Tenths trim{};
    bool dim{false};
    bool mute{false};
    std::size_t fold{0};
    bool playing{false};
    Tenths total{};        // after dim
    double gain{0.0};      // 0 when not playing
    bool solo{false};      // an output of this set is soloed
    bool operator==(const ResolvedSet&) const = default;
};

struct Resolved {
    std::size_t active{npos};   // a speakers set's index, npos for all
    Tenths dim_db{};
    bool subs{true};
    std::vector<ResolvedSet> sets;   // the topology's order
    std::array<double, kChannels> gain{};
    std::array<std::size_t, kChannels> scope{};   // the set an output follows; npos when in none
    std::array<bool, kChannels> solo{};
    std::array<bool, kChannels> out_mute{};
    bool operator==(const Resolved&) const = default;
};

// The effective active set: npos for all.
[[nodiscard]] inline std::size_t effective_active(const MonitorTopology& topology, const State& state) noexcept {
    if (state.active == "all") return npos;
    const std::size_t named = topology.set_index(state.active);
    if (named != MonitorTopology::npos && topology.sets[named].kind == MonitorTopology::Kind::speakers) return named;
    for (std::size_t set = 0; set < topology.sets.size(); ++set) {
        if (topology.sets[set].kind == MonitorTopology::Kind::speakers) return set;
    }
    return npos;
}

[[nodiscard]] inline Resolved resolve(const MonitorTopology& topology, const State& state, const Limits& limits) {
    Resolved out;
    out.active = effective_active(topology, state);
    out.dim_db = state.dim_db;
    out.subs = state.subs;
    out.solo = state.solo;
    out.out_mute = state.out_mute;
    out.gain.fill(1.0);
    out.scope.fill(npos);
    out.sets.resize(topology.sets.size());
    for (std::size_t s = 0; s < topology.sets.size(); ++s) {
        const MonitorTopology::Set& set = topology.sets[s];
        ResolvedSet& r = out.sets[s];
        if (const SetState* line = state.find(set.id)) {
            r.level = std::min(line->level, limits.max_db);
            r.trim = line->trim;
            r.dim = line->dim;
            r.mute = line->mute;
            const std::size_t fold = topology.fold_index(s, line->fold);
            r.fold = fold == MonitorTopology::npos ? 0 : fold;
        } else {
            r.level = limits.reference(set.id);
        }
        r.total = std::min({r.level + r.trim, limits.max_db, 0});
        if (r.dim) r.total += state.dim_db;
        const bool selected = set.kind == MonitorTopology::Kind::headphones || out.active == npos || out.active == s;
        r.playing = !r.mute && selected;
        r.gain = r.playing ? std::pow(10.0, static_cast<double>(r.total) / 200.0) : 0.0;
    }
    for (const MonitorTopology::Out& o : topology.outs) {
        for (const std::size_t s : o.sets) {
            if (state.solo[o.index]) out.sets[s].solo = true;
        }
    }
    for (const MonitorTopology::Out& o : topology.outs) {
        const std::size_t n = o.index;
        std::size_t scope = o.sets.front();
        double gain = out.sets[scope].gain;
        if (o.sets.size() > 1 && out.active != npos) {
            if (std::find(o.sets.begin(), o.sets.end(), out.active) != o.sets.end()) {
                scope = out.active;
                gain = out.sets[scope].gain;
            } else {
                gain = 0.0;
            }
        }
        if (!state.subs && o.role == MonitorTopology::Role::sub) gain = 0.0;
        if (state.out_mute[n]) gain = 0.0;
        if (out.sets[scope].solo && !state.solo[n]) gain = 0.0;
        out.gain[n] = gain;
        out.scope[n] = scope;
    }
    return out;
}

// Per output: the level ramp when only levels and trims moved between
// `before` and `after`, the fast one when any flag did.
[[nodiscard]] inline std::array<std::uint32_t, kChannels> ramp_frames(const Resolved& before, const Resolved& after,
                                                                    bool limits_changed, unsigned rate) noexcept {
    std::array<std::uint32_t, kChannels> ramps{};
    const bool global = limits_changed || before.active != after.active || before.dim_db != after.dim_db ||
                        before.subs != after.subs || before.sets.size() != after.sets.size();
    for (std::size_t n = 0; n < kChannels; ++n) {
        bool fast = global || before.scope[n] != after.scope[n] || before.solo[n] != after.solo[n] ||
                    before.out_mute[n] != after.out_mute[n];
        const std::size_t s = after.scope[n];
        if (!fast && s != npos) {
            const ResolvedSet& a = before.sets[s];
            const ResolvedSet& b = after.sets[s];
            fast = a.dim != b.dim || a.mute != b.mute || a.fold != b.fold || a.playing != b.playing || a.solo != b.solo;
        }
        ramps[n] = fast ? monitor_ramp_frames_fast(rate) : monitor_ramp_frames_level(rate);
    }
    return ramps;
}

// The state the owner starts from when there is no valid state file (see the
// header). `remembered` is the remembered copy, already validated.
[[nodiscard]] inline State start_state(const MonitorTopology& topology, const Limits& limits,
                                       const std::optional<State>& remembered) {
    State state;
    if (remembered) {
        state = *remembered;
    } else {
        for (std::size_t s = 0; s < topology.sets.size(); ++s) {
            if (topology.sets[s].kind == MonitorTopology::Kind::speakers) {
                state.active = topology.sets[s].id;
                break;
            }
        }
    }
    state.solo.fill(false);
    state.seq = 0;
    for (const MonitorTopology::Set& set : topology.sets) {
        SetState* line = nullptr;
        for (SetState& candidate : state.sets) {
            if (candidate.id == set.id) line = &candidate;
        }
        if (line == nullptr) {
            if (state.sets.size() >= kMaxSets) continue;
            state.sets.push_back(SetState{set.id, limits.start_level(), 0, false, false, "full"});
            line = &state.sets.back();
        }
        switch (limits.start) {
        case StartRule::last:
            if (!remembered) line->level = limits.start_level();
            break;
        case StartRule::reference: line->level = limits.reference(set.id); break;
        case StartRule::fixed: line->level = limits.start_level(); break;
        }
    }
    // A remembered active set this preset lacks is resolve()'s to map, as any state file's.
    return state;
}

// ------------------------------------------------------------------ control

class MonitorControl {
public:
    struct Paths {
        std::string state;
        std::string saved;
        std::string limits;
        std::string status;
    };

    // `gains` must have no other publisher. `rate` sets the ramp lengths.
    MonitorControl(DspStage& stage, MonitorGains& gains, Paths paths, unsigned rate)
        : stage_(stage), gains_(gains), paths_(std::move(paths)), rate_(rate), idle_(!stage.has_monitor()) {
        published_.gain.fill(1.0);
        published_.ramp_frames.fill(1);
        idle_reason_ = stage.loaded() ? "the running preset has no monitor section" : "no DSP preset";
    }

    // One step, at `now_ns` on any monotonic clock. Control thread only.
    void poll(std::int64_t now_ns) {
        now_ns_ = now_ns;
        if (idle_) {
            write_status();
            return;
        }
        bool limits_changed = false;
        if (changed(paths_.limits, limits_watch_)) {
            std::string text;
            std::string reason;
            std::optional<Limits> read;
            if (read_file(paths_.limits, kFileCap, text, reason) == Read::ok) read = parse_limits(text, reason);
            const Limits next = read ? *read : Limits{};
            limits_valid_ = read.has_value();
            if (first_ || !(next == limits_)) limits_changed = true;
            limits_ = next;
        }
        std::optional<State> valid;
        std::string invalid;
        if (changed(paths_.state, state_watch_)) {
            std::string text;
            const Read result = read_file(paths_.state, kFileCap, text, invalid);
            if (result == Read::ok) valid = parse_state(text, invalid);
            else if (result == Read::absent) invalid.clear();
            if (valid) invalid.clear();
            else if (!invalid.empty()) ++refused_;
        }
        bool dirty = limits_changed;
        if (valid) {
            ++applied_;
            current_ = std::move(*valid);
            seq_ = current_.seq;
            mode_ = Mode::applied;
            reason_.clear();
            dirty = true;
        } else if (first_) {
            current_ = start_state(stage_.monitor(), limits_, remembered());
            mode_ = Mode::start;
            reason_ = invalid.empty() ? std::string() : "state file refused: " + invalid;
            dirty = true;
        } else if (!invalid.empty()) {
            if (mode_ == Mode::start) {
                reason_ = "state file refused: " + invalid;
            } else {
                mode_ = Mode::refused;
                reason_ = invalid;
            }
        }
        first_ = false;
        if (dirty) plan(resolve(stage_.monitor(), current_, limits_), limits_changed);
        step(now_ns);
        write_status();
    }

    [[nodiscard]] bool idle() const noexcept { return idle_; }
    [[nodiscard]] Mode mode() const noexcept { return mode_; }
    [[nodiscard]] const std::string& reason() const noexcept { return reason_; }
    [[nodiscard]] std::optional<std::uint64_t> seq() const noexcept { return seq_; }
    [[nodiscard]] std::uint64_t applied() const noexcept { return applied_; }
    [[nodiscard]] std::uint64_t refused() const noexcept { return refused_; }
    [[nodiscard]] std::uint64_t publishes() const noexcept { return publishes_; }
    [[nodiscard]] std::uint64_t status_gen() const noexcept { return gen_; }
    [[nodiscard]] std::uint64_t status_failures() const noexcept { return status_failures_; }
    [[nodiscard]] bool limits_valid() const noexcept { return limits_valid_; }
    // A set switch waiting for its second publish.
    [[nodiscard]] bool switching() const noexcept { return waiting_ || want_inter_; }
    [[nodiscard]] const State& state() const noexcept { return current_; }
    [[nodiscard]] const Limits& limits() const noexcept { return limits_; }
    [[nodiscard]] const Resolved& resolved() const noexcept { return final_resolved_; }
    [[nodiscard]] const MonitorGains::Targets& published() const noexcept { return published_; }

private:
    struct Watch {
        bool present{false};
        dev_t device{};
        ino_t inode{};
        off_t size{};
        timespec mtime{};
    };

    // True when the file appeared, went or moved (device, inode, size, mtime;
    // lstat, so a link is seen as itself and read as invalid).
    static bool changed(const std::string& path, Watch& watch) noexcept {
        struct stat info {};
        if (::lstat(path.c_str(), &info) != 0) {
            const bool was = watch.present;
            watch = Watch{};
            return was;
        }
#ifdef __APPLE__
        const timespec modified = info.st_mtimespec;
#else
        const timespec modified = info.st_mtim;
#endif
        const bool same = watch.present && info.st_dev == watch.device && info.st_ino == watch.inode &&
                          info.st_size == watch.size && modified.tv_sec == watch.mtime.tv_sec &&
                          modified.tv_nsec == watch.mtime.tv_nsec;
        watch = Watch{true, info.st_dev, info.st_ino, info.st_size, modified};
        return !same;
    }

    std::optional<State> remembered() {
        std::string text;
        std::string reason;
        if (read_file(paths_.saved, kFileCap, text, reason) != Read::ok) return std::nullopt;
        return parse_state(text, reason);
    }

    // A new resolution: the folds at once, and what to publish next.
    void plan(Resolved next, bool limits_changed) {
        for (std::size_t s = 0; s < next.sets.size(); ++s) stage_.set_fold(s, next.sets[s].fold);
        const bool switched = have_final_ && next.active != final_resolved_.active;
        const bool switching = switched || waiting_ || want_inter_;
        MonitorGains::Targets target;
        target.gain = next.gain;
        if (switching || !have_published_) {
            target.ramp_frames.fill(monitor_ramp_frames_fast(rate_));
        } else {
            target.ramp_frames = ramp_frames(published_resolved_, next, limits_changed || limits_unpublished_, rate_);
        }
        limits_unpublished_ = limits_unpublished_ || limits_changed;
        final_ = target;
        final_resolved_ = std::move(next);
        have_final_ = true;
        if (switching) {
            MonitorGains::Targets down;
            down.ramp_frames.fill(monitor_ramp_frames_fast(rate_));
            for (std::size_t n = 0; n < kChannels; ++n) down.gain[n] = std::min(published_.gain[n], final_.gain[n]);
            if (down.gain != published_.gain) {
                want_ = down;
                want_inter_ = true;
            } else if (!waiting_) {
                want_ = final_;   // nothing has to come down first
                want_inter_ = false;
            } else {
                want_.reset();    // the published first step still holds; its wait goes on
                want_inter_ = false;
            }
        } else if (final_.gain != published_.gain || !have_published_) {
            want_ = final_;
            want_inter_ = false;
        } else {
            want_.reset();
            published_resolved_ = final_resolved_;
            limits_unpublished_ = false;
        }
    }

    void step(std::int64_t now_ns) {
        if (waiting_ && !want_) {
            if (gains_.generation() >= waiting_for_) {
                if (!taken_at_) taken_at_ = now_ns;
                if (now_ns - *taken_at_ >= kSwitchHoldNs) {
                    want_ = final_;
                    want_inter_ = false;
                }
            }
        }
        if (!want_) return;
        std::string reason;
        if (!gains_.publish(*want_, reason)) {
            if (reason != "previous update not yet taken") {
                ++publish_refusals_;
                want_.reset();
                want_inter_ = false;
            }
            return;
        }
        ++publishes_;
        have_published_ = true;
        published_ = *want_;
        if (want_inter_) {
            waiting_ = true;
            waiting_for_ = publishes_;
            taken_at_.reset();
        } else {
            waiting_ = false;
            published_resolved_ = final_resolved_;
            limits_unpublished_ = false;
        }
        want_.reset();
        want_inter_ = false;
    }

    Status build_status() const {
        Status status;
        status.mode = idle_ ? Mode::idle : mode_;
        status.reason = quotable(idle_ ? idle_reason_ : reason_, kReasonMax);
        status.seq = seq_;
        status.t_us = now_ns_ > 0 ? static_cast<std::uint64_t>(now_ns_ / 1000) : 0;
        if (idle_) return status;
        const MonitorTopology& topology = stage_.monitor();
        const Resolved& r = final_resolved_;
        status.active = r.active == npos ? std::string("all") : topology.sets[r.active].id;
        status.dim_db = current_.dim_db;
        status.subs = current_.subs;
        status.solo = current_.solo;
        status.out_mute = current_.out_mute;
        for (std::size_t s = 0; s < topology.sets.size() && s < kMaxSets; ++s) {
            const MonitorTopology::Set& set = topology.sets[s];
            const ResolvedSet& rs = r.sets[s];
            StatusSet line;
            line.id = set.id;
            line.headphones = set.kind == MonitorTopology::Kind::headphones;
            line.level = rs.level;
            line.trim = rs.trim;
            line.dim = rs.dim;
            line.mute = rs.mute;
            line.folds = set.folds;
            line.fold = set.folds[rs.fold];
            if (rs.playing) line.gain = rs.total;
            status.sets.push_back(std::move(line));
        }
        for (std::size_t s = 0; s < topology.sets.size() && s < kMaxSets; ++s) {
            for (const MonitorTopology::Out& o : topology.outs) {
                if (std::find(o.sets.begin(), o.sets.end(), s) == o.sets.end() || status.outs.size() >= kMaxOutLines) continue;
                status.outs.push_back(StatusOut{o.index, topology.sets[s].id, o.role == MonitorTopology::Role::sub,
                                                quotable(topology.labels[o.index], kLabelMax)});
            }
        }
        return status;
    }

    // Rewritten only when something but gen and t_us would change.
    void write_status() {
        Status status = build_status();
        status.gen = 0;
        status.t_us = 0;
        const std::string key = render_status(status);
        if (written_ && key == written_key_) return;
        status.gen = gen_ + 1;
        status.t_us = now_ns_ > 0 ? static_cast<std::uint64_t>(now_ns_ / 1000) : 0;
        if (!write_file(paths_.status, render_status(status))) {
            ++status_failures_;
            return;
        }
        ++gen_;
        written_ = true;
        written_key_ = key;
    }

    static constexpr std::int64_t kSwitchHoldNs = 10000000;   // 10 ms after the first step was taken

    DspStage& stage_;
    MonitorGains& gains_;
    Paths paths_;
    unsigned rate_;
    bool idle_;
    std::string idle_reason_;
    std::int64_t now_ns_{0};
    bool first_{true};
    Watch limits_watch_;
    Watch state_watch_;
    Limits limits_;
    bool limits_valid_{false};
    bool limits_unpublished_{false};
    State current_;
    Mode mode_{Mode::start};
    std::string reason_;
    std::optional<std::uint64_t> seq_;
    // What the audio thread was last given, and the resolution behind the last final publish.
    MonitorGains::Targets published_{};
    Resolved published_resolved_;
    bool have_published_{false};
    // Where the gains are going, and the resolution it came from.
    MonitorGains::Targets final_{};
    Resolved final_resolved_;
    bool have_final_{false};
    // The next publish, retried while the previous one is not yet taken.
    std::optional<MonitorGains::Targets> want_;
    bool want_inter_{false};
    // A switch's first step published; the final waits for its take plus 10 ms.
    bool waiting_{false};
    std::uint64_t waiting_for_{0};
    std::optional<std::int64_t> taken_at_;
    std::uint64_t applied_{0};
    std::uint64_t refused_{0};
    std::uint64_t publishes_{0};
    std::uint64_t publish_refusals_{0};
    std::uint64_t gen_{0};
    std::uint64_t status_failures_{0};
    bool written_{false};
    std::string written_key_;
};

}  // namespace usb16x16::owner::monitor
