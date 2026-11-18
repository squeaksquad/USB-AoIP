// Mac-side test of the monitor block's control (monitor_ctl.hpp): the three
// files' parsers and writer against docs/web/MONITOR-FILES.md itself (its
// examples are read from the repository, so the document and this code cannot
// drift), what plays, the ramps, the two-step set switch, the start rule.
//   c++ -std=c++20 -O2 -Wall -Wextra -Wpedantic -Werror -I ../../dsp-core/include
//       -o /tmp/monitor_ctl_test monitor_ctl_test.cpp ../../dsp-core/src/bridge_core.cpp && /tmp/monitor_ctl_test [MONITOR-FILES.md]
// (one line; the contract is found from this file's path unless named)
#include "monitor_ctl.hpp"

#include <sys/stat.h>
#include <unistd.h>

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <functional>
#include <memory>
#include <sstream>
#include <string>
#include <vector>

namespace m = usb16x16::owner::monitor;
using usb16x16::DspStage;
using usb16x16::MonitorGains;

namespace {

int failures = 0;

void check(bool condition, const std::string& message) {
    if (!condition) {
        std::printf("FAIL: %s\n", message.c_str());
        ++failures;
    }
}

constexpr std::size_t kChannels = usb16x16::kChannels;
constexpr std::int64_t kMs = 1000000;

// ---- fixtures ------------------------------------------------------------------

std::string straight() {
    std::string text = "usb16x16-dsp 1\npreset monitor-test\nrate 48000\nchannels 16\ninternal 16\nmaxdelay 480\nexpand 16\n";
    for (std::size_t c = 0; c < kChannels; ++c) text += std::to_string(c) + " " + std::to_string(c) + " 1\n";
    text += "branch 0\nassign 16\n";
    for (std::size_t c = 0; c < kChannels; ++c) text += std::to_string(c) + " " + std::to_string(c) + " 1\n";
    text += "output 16\n";
    for (std::size_t c = 0; c < kChannels; ++c) text += std::to_string(c) + " 0 1 0\n";
    return text + "end\n";
}

// mains (0, 1 and the sub 2, shared with nearfield), nearfield (3, 4), phones (14, 15); 5..13 in no set.
std::string monitored() {
    std::string text = straight();
    text.erase(text.size() - 4);
    text += "monitor 1\nsets 3\nset mains speakers\nset nearfield speakers\nset phones headphones\n"
            "outs 7\nout 0 speaker 0\nout 1 speaker 0\nout 2 sub 0 1\nout 3 speaker 1\nout 4 speaker 1\n"
            "out 14 speaker 2\nout 15 speaker 2\n"
            "label 0 L\nlabel 1 R\nlabel 2 Sub \"big\" \\ one\nlabel 3 NF L\nlabel 4 NF R\nlabel 14 Phones L\nlabel 15 Phones R\n"
            "expandsets 16\n0\n0\n-\n1\n1\n-\n-\n-\n-\n-\n-\n-\n-\n-\n2\n2\n"
            "folds 2\nfold 0 mono 2\n0 0 0.5\n0 1 0.5\nfold 1 stereo 1\n3 3 1\n";
    return text + "end\n";
}

const std::string kZeros = "0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0";

std::string flags_with(std::initializer_list<std::size_t> on) {
    std::string text;
    for (std::size_t i = 0; i < kChannels; ++i) {
        bool set = false;
        for (const std::size_t n : on) set = set || n == i;
        text += std::string(i == 0 ? "" : ",") + (set ? "1" : "0");
    }
    return text;
}

struct SetLine {
    std::string id;
    std::string level{"-20.0"};
    std::string trim{"0.0"};
    int dim{0};
    int mute{0};
    std::string fold{"full"};
};

std::string state_text(std::uint64_t seq, const std::string& active, const std::vector<SetLine>& sets,
                       const std::string& solo = kZeros, const std::string& mute = kZeros, const std::string& dim_db = "-20.0",
                       const std::string& subs = "on") {
    std::string text = "MONITOR-STATE v=1 seq=" + std::to_string(seq) + "\nactive=" + active + "\ndim_db=" + dim_db + "\nsubs=" + subs + "\n";
    for (const SetLine& s : sets) {
        text += "set id=" + s.id + " level_db=" + s.level + " trim_db=" + s.trim + " dim=" + std::to_string(s.dim) +
                " mute=" + std::to_string(s.mute) + " fold=" + s.fold + "\n";
    }
    return text + "solo=" + solo + "\nmute=" + mute + "\nend\n";
}

std::string limits_text(const std::string& max_db = "0.0", const std::string& start = "last",
                        const std::string& start_db = "-30.0", const std::string& refs = "") {
    return "MONITOR-LIMITS v=1\nmax_db=" + max_db + "\nstart=" + start + "\nstart_db=" + start_db + "\nlock=0\n" + refs + "end\n";
}

void put(const std::string& path, const std::string& text) {
    // By rename, as the web service does, so the inode changes every time.
    const std::string temporary = path + ".new";
    std::FILE* file = std::fopen(temporary.c_str(), "wb");
    std::fwrite(text.data(), 1, text.size(), file);
    std::fclose(file);
    std::rename(temporary.c_str(), path.c_str());
}

std::string slurp(const std::string& path) {
    std::ifstream file(path, std::ios::binary);
    std::stringstream text;
    text << file.rdbuf();
    return text.str();
}

std::string replaced(std::string text, const std::string& from, const std::string& to) {
    const std::size_t at = text.find(from);
    if (at == std::string::npos) {
        std::printf("FIXTURE: '%s' not found\n", from.c_str());
        std::exit(2);
    }
    return text.replace(at, from.size(), to);
}

double db_gain(double db) { return std::pow(10.0, db / 20.0); }
bool near(double a, double b) { return std::abs(a - b) < 1e-12; }

struct Rig {
    std::string directory;
    DspStage stage;
    std::unique_ptr<MonitorGains> gains = std::make_unique<MonitorGains>();
    std::unique_ptr<m::MonitorControl> control;
    m::MonitorControl::Paths paths;

    explicit Rig(const std::string& root, const std::string& name, const std::string& artifact = monitored()) {
        directory = root + "/" + name;
        ::mkdir(directory.c_str(), 0755);
        stage = DspStage::load(artifact);
        paths = {directory + "/state", directory + "/saved", directory + "/limits", directory + "/monitor.status"};
        control = std::make_unique<m::MonitorControl>(stage, *gains, paths, 48000);
    }
    void take() { gains->process(nullptr, 0); }
    m::Status status() {
        std::string reason;
        const auto parsed = m::parse_status(slurp(paths.status), reason);
        check(parsed.has_value(), "the status file parses: " + reason);
        return parsed.value_or(m::Status{});
    }
};

// ---- the contract's examples ----------------------------------------------------

std::vector<std::string> contract_examples(const std::string& path) {
    const std::string text = slurp(path);
    std::vector<std::string> blocks;
    const std::string open = "### Example\n\n```\n";
    std::size_t at = 0;
    while ((at = text.find(open, at)) != std::string::npos) {
        at += open.size();
        const std::size_t end = text.find("```", at);
        blocks.push_back(text.substr(at, end - at));
        at = end;
    }
    return blocks;
}

void test_contract_examples(const std::vector<std::string>& examples) {
    check(examples.size() == 3, "MONITOR-FILES.md has its three examples");
    if (examples.size() != 3) return;
    std::string reason;
    const auto state = m::parse_state(examples[0], reason);
    check(state.has_value(), "the contract's state example parses: " + reason);
    if (state) {
        check(state->seq == 42 && state->active == "mains" && state->dim_db == -200 && state->subs && state->sets.size() == 3,
              "the state example's header lines");
        check(state->sets[0].level == -185 && state->sets[1].trim == -15 && state->sets[1].fold == "stereo",
              "the state example's set lines");
        check(state->out_mute[14] && state->out_mute[15] && !state->out_mute[13] && !state->solo[0], "the state example's arrays");
        check(m::render_state(*state) == examples[0], "the state example renders back byte for byte");
    }
    const auto limits = m::parse_limits(examples[1], reason);
    check(limits.has_value(), "the contract's limits example parses: " + reason);
    if (limits) {
        check(limits->max_db == -60 && limits->start == m::StartRule::reference && limits->start_db == -300 && limits->lock,
              "the limits example's fields");
        check(limits->refs.size() == 2 && limits->refs[0].note == "79 dB SPL C at the desk" && limits->refs[1].level == -200,
              "the limits example's refs");
        check(limits->reference("mains") == -180 && limits->reference("phones") == -100, "a reference, or -10.0 for a set with none");
        check(m::render_limits(*limits) == examples[1], "the limits example renders back byte for byte");
    }
    const auto clamped = m::parse_limits(replaced(examples[1], "start_db=-30.0", "start_db=-1.0"), reason);
    check(clamped && clamped->start_db == -60, "a reader clamps start_db to max_db");
    const auto status = m::parse_status(examples[2], reason);
    check(status.has_value(), "the contract's status example parses: " + reason);
    if (status) {
        check(status->gen == 17 && status->seq == 42u && status->mode == m::Mode::applied && status->t_us == 81234567890ULL,
              "the status example's header");
        check(status->sets.size() == 3 && status->sets[1].gain == -255 && status->sets[2].headphones &&
                  status->sets[0].folds.size() == 3,
              "the status example's sets");
        check(status->outs.size() == 9 && status->outs[6].n == 3 && status->outs[6].set == "nearfield" && status->outs[6].sub,
              "the status example's outputs, a shared sub on one line per set");
        check(m::render_status(*status) == examples[2], "the status example renders back byte for byte");
    }
}

// ---- refusals -------------------------------------------------------------------

void expect_state(const std::string& text, bool valid, const std::string& what) {
    std::string reason;
    const bool parsed = m::parse_state(text, reason).has_value();
    check(parsed == valid, std::string(valid ? "accepted: " : "refused: ") + what + (parsed ? "" : " (" + reason + ")"));
}

void test_state_refusals(const std::string& good) {
    expect_state(good, true, "the example");
    const std::vector<std::pair<std::string, std::string>> bad = {
        {"\n", "\r\n"},
        {"subs=on", "subs=on\t"},
        {"mains", "m\xC3\xA4ins"},
        {"level_db=-18.5", "level_db=-18.5 "},
        {"level_db=-18.5", " level_db=-18.5"},
        {"set id=mains", "set  id=mains"},
        {"set id=mains", " set id=mains"},
        {"dim_db=-20.0\nsubs=on", "subs=on\ndim_db=-20.0"},
        {"subs=on\n", "subs=on\nsubs=on\n"},
        {"subs=on\n", "subs=on\nextra=1\n"},
        {"seq=42", "seq=+42"},
        {"seq=42", "seq="},
        {"seq=42", "seq=1234567890123456789"},
        {"v=1", "v=2"},
        {"dim_db=-20.0", "dim_db=+20.0"},
        {"dim_db=-20.0", "dim_db=-2e1"},
        {"dim_db=-20.0", "dim_db=nan"},
        {"dim_db=-20.0", "dim_db=-inf"},
        {"dim_db=-20.0", "dim_db=-20"},
        {"dim_db=-20.0", "dim_db=-20.00"},
        {"dim_db=-20.0", "dim_db=-40.1"},
        {"dim_db=-20.0", "dim_db=0.1"},
        {"dim_db=-20.0", "dim_db=-.5"},
        {"level_db=-18.5", "level_db=-60.1"},
        {"level_db=-18.5", "level_db=0.1"},
        {"level_db=-18.5", "level_db=-1000.0"},
        {"trim_db=0.0 dim=0 mute=0 fold=full\nset id=nearfield", "trim_db=12.1 dim=0 mute=0 fold=full\nset id=nearfield"},
        {"dim=0 mute=0 fold=full\nset id=nearfield", "dim=2 mute=0 fold=full\nset id=nearfield"},
        {"active=mains", "active=studio"},
        {"active=mains", "active=Mains"},
        {"set id=phones", "set id=Phones"},
        {"set id=phones", "set id=1phones"},
        {"set id=phones", "set id=" + std::string(33, 'p')},
        {"set id=phones", "set id=mains"},
        {"fold=stereo", "fold=Stereo"},
        {"fold=stereo", "fold=" + std::string(17, 's')},
        {"fold=stereo", "fold="},
        {"solo=0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0", "solo=0,0,0,0,0,0,0,0,0,0,0,0,0,0,0"},
        {"solo=0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0", "solo=0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0"},
        {"solo=0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0", "solo=0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,2"},
        {"mute=0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,1\n", ""},
        {"end\n", "end"},
        {"end\n", "end\n\n"},
        {"end\n", "end\nend\n"},
        {"end\n", "END\n"},
    };
    for (const auto& [from, to] : bad) expect_state(replaced(good, from, to), false, "'" + from + "' -> '" + to + "'");
    expect_state("", false, "an empty file");
    expect_state("end\n", false, "only an end line");
    expect_state(replaced(good, "trim_db=0.0 dim=0 mute=0 fold=full\nset id=nearfield",
                          "trim_db=-0.0 dim=0 mute=0 fold=full\nset id=nearfield"),
                 true, "-0.0 is a number");
    expect_state(replaced(good, "level_db=-18.5", "level_db=-060.0"), true, "three digits with a leading zero");
    expect_state(state_text(1, "all", {}), true, "no sets, active all");
    std::vector<SetLine> sixteen;
    for (int i = 0; i < 16; ++i) sixteen.push_back({"s" + std::to_string(i)});
    expect_state(state_text(1, "s15", sixteen), true, "sixteen sets");
    sixteen.push_back({"s16"});
    expect_state(state_text(1, "all", sixteen), false, "seventeen sets");
}

void test_limits_refusals(const std::string& good) {
    std::string reason;
    const auto ok = [&](const std::string& text) { return m::parse_limits(text, reason).has_value(); };
    check(ok(good), "the limits example parses");
    const std::vector<std::pair<std::string, std::string>> bad = {
        {"max_db=-6.0", "max_db=-30.1"},  {"max_db=-6.0", "max_db=0.1"},     {"max_db=-6.0", "max_db=-6"},
        {"start=reference", "start=ref"}, {"start=reference", "start=last "}, {"start_db=-30.0", "start_db=-60.1"},
        {"lock=1", "lock=yes"},           {"lock=1\n", ""},                  {"note=\"\"", "note=\"a\"b\""},
        {"note=\"\"", "note=\"a\\b\""},   {"note=\"\"", "note="},            {"ref id=nearfield", "ref id=mains"},
        {"ref id=nearfield", "ref  id=nearfield"}, {"MONITOR-LIMITS v=1", "MONITOR-LIMITS v=2"},
        {"level_db=-20.0", "level_db=-61.0"}, {"end\n", "end\nref id=x level_db=0.0 note=\"\"\n"},
    };
    for (const auto& [from, to] : bad) check(!ok(replaced(good, from, to)), "limits refused: '" + from + "' -> '" + to + "'");
    check(ok(replaced(good, "note=\"\"", "note=\"" + std::string(64, 'n') + "\"")), "a 64-character note is accepted");
    check(!ok(replaced(good, "note=\"\"", "note=\"" + std::string(65, 'n') + "\"")), "a 65-character note is refused");
    std::string refs;
    for (int i = 0; i < 16; ++i) refs += "ref id=r" + std::to_string(i) + " level_db=-10.0 note=\"\"\n";
    check(ok(limits_text("0.0", "last", "-30.0", refs)), "sixteen refs");
    check(!ok(limits_text("0.0", "last", "-30.0", refs + "ref id=r16 level_db=-10.0 note=\"\"\n")), "seventeen refs");
    const auto clamped = m::parse_limits(limits_text("-12.0", "fixed", "-3.0", "ref id=a level_db=-1.0 note=\"\"\n"), reason);
    check(clamped && clamped->start_db == -120 && clamped->refs[0].level == -120 && clamped->reference("b") == -120,
          "start_db, refs and the default reference are clamped to max_db");
}

void test_status_refusals(const std::string& good) {
    std::string reason;
    const auto ok = [&](const std::string& text) { return m::parse_status(text, reason).has_value(); };
    const std::vector<std::pair<std::string, std::string>> bad = {
        {"active=mains", "active=studio"},
        {"out n=5 set=nearfield", "out n=5 set=studio"},
        {"out n=5 set=nearfield", "out n=4 set=nearfield"},
        {"out n=15 set=phones", "out n=16 set=phones"},
        {"folds=full,mono gain_db=-30.0", "folds=mono gain_db=-30.0"},
        {"fold=stereo folds=full,stereo,mono", "fold=stereo folds=full,mono"},
        {"folds=full,mono gain_db=-30.0", "folds=full,mono,mono gain_db=-30.0"},
        {"folds=full,mono gain_db=-30.0", "folds=full,mono gain_db=inf"},
        {"seq=42", "seq=nonexistent"},
        {"state=applied", "state=running"},
        {"reason=\"\"", "reason=\"" + std::string(129, 'r') + "\""},
        {"label=\"L\"", "label=\"L\"\""},
        {"set id=phones", "set id=mains"},
    };
    for (const auto& [from, to] : bad) check(!ok(replaced(good, from, to)), "status refused: '" + from + "' -> '" + to + "'");
    check(ok(replaced(good, "seq=42", "seq=none")), "seq=none is a status");
    check(ok(replaced(good, "gain_db=-30.0", "gain_db=-inf")), "gain_db=-inf is a status");
    std::string many = good;
    std::string outs;
    for (int i = 0; i < 16; ++i) {
        for (const char* set : {"mains", "nearfield", "phones", "x"}) {
            if (std::string(set) == "x") continue;
            outs += "out n=" + std::to_string(i) + " set=" + set + " role=speaker label=\"\"\n";
        }
    }
    const std::size_t first = many.find("out n=");
    const std::size_t last = many.find("solo=");
    many.replace(first, last - first, outs);
    check(ok(many), "48 out lines");
    std::string extra = outs;
    for (int i = 0; i < 16; ++i) extra += "out n=" + std::to_string(i) + " set=mains2 role=sub label=\"\"\n";
    std::string over = replaced(good, "set id=phones", "set id=mains2 kind=speakers level_db=-1.0 trim_db=0.0 dim=0 mute=0 fold=full folds=full gain_db=-1.0\nset id=x2 kind=speakers level_db=-1.0 trim_db=0.0 dim=0 mute=0 fold=full folds=full gain_db=-1.0\nset id=phones");
    const std::size_t a = over.find("out n=");
    over.replace(a, over.find("solo=") - a, extra);
    check(ok(over), "64 out lines");
    over = replaced(over, "solo=", "out n=0 set=x2 role=speaker label=\"\"\nsolo=");
    check(!ok(over), "65 out lines are refused");
}

void test_hostile_files(const std::string& root, const std::string& good) {
    const std::string dir = root + "/hostile";
    ::mkdir(dir.c_str(), 0755);
    std::string text;
    std::string reason;
    check(m::read_file(dir + "/nothing", m::kFileCap, text, reason) == m::Read::absent, "a missing file is absent");
    put(dir + "/good", good);
    check(m::read_file(dir + "/good", m::kFileCap, text, reason) == m::Read::ok && text == good, "a regular file is read whole");
    ::symlink((dir + "/good").c_str(), (dir + "/link").c_str());
    check(m::read_file(dir + "/link", m::kFileCap, text, reason) == m::Read::invalid, "a symbolic link is invalid (" + reason + ")");
    ::mkfifo((dir + "/fifo").c_str(), 0644);
    check(m::read_file(dir + "/fifo", m::kFileCap, text, reason) == m::Read::invalid, "a FIFO is invalid, and never blocks");
    ::mkdir((dir + "/directory").c_str(), 0755);
    check(m::read_file(dir + "/directory", m::kFileCap, text, reason) == m::Read::invalid, "a directory is invalid");
    put(dir + "/big", std::string(8193, 'x'));
    check(m::read_file(dir + "/big", m::kFileCap, text, reason) == m::Read::invalid, "8193 bytes is over the cap");
    put(dir + "/cap", std::string(8192, 'x'));
    check(m::read_file(dir + "/cap", m::kFileCap, text, reason) == m::Read::ok && text.size() == 8192, "8192 bytes is read");
    check(m::write_file(dir + "/written", "hello\n") && slurp(dir + "/written") == "hello\n", "the writer writes");
    struct stat info {};
    ::stat((dir + "/written").c_str(), &info);
    check((info.st_mode & 0777) == 0644, "the writer's file is 0644 whatever the umask");
    check(!m::write_file(dir + "/no/such/dir/file", "x"), "the writer reports a failure");
    // Nothing left behind: only the files made here.
    std::FILE* list = ::popen(("ls -A '" + dir + "' | grep -c '^\\.' || true").c_str(), "r");
    char count[16]{};
    if (list != nullptr) {
        std::fgets(count, sizeof count, list);
        ::pclose(list);
    }
    check(std::string(count) == "0\n", "the writer leaves no temporary file");
}

// ---- resolve --------------------------------------------------------------------

m::State state_of(const std::string& text) {
    std::string reason;
    auto state = m::parse_state(text, reason);
    if (!state) {
        std::printf("FIXTURE: state refused: %s\n", reason.c_str());
        std::exit(2);
    }
    return *state;
}

m::Limits limits_of(const std::string& text) {
    std::string reason;
    auto limits = m::parse_limits(text, reason);
    if (!limits) {
        std::printf("FIXTURE: limits refused: %s\n", reason.c_str());
        std::exit(2);
    }
    return *limits;
}

void test_resolve() {
    const DspStage stage = DspStage::load(monitored());
    const usb16x16::MonitorTopology& topology = stage.monitor();
    const m::Limits open = limits_of(limits_text());
    const std::vector<SetLine> three = {{"mains", "-18.5"}, {"nearfield", "-24.0", "-1.5"}, {"phones", "-30.0"}};

    // active=mains: mains and phones play, nearfield is silent, the shared sub follows mains.
    auto r = m::resolve(topology, state_of(state_text(1, "mains", three)), open);
    check(near(r.gain[0], db_gain(-18.5)) && near(r.gain[1], db_gain(-18.5)), "a set plays at its level");
    check(near(r.gain[2], db_gain(-18.5)), "a shared sub follows the active set");
    check(r.gain[3] == 0.0 && r.gain[4] == 0.0, "a speakers set that is not active is silent");
    check(near(r.gain[14], db_gain(-30.0)), "headphones ignore active");
    for (std::size_t n = 5; n < 14; ++n) check(r.gain[n] == 1.0, "an output in no set is untouched (" + std::to_string(n) + ")");
    check(r.sets[1].total == -255 && !r.sets[1].playing, "level plus trim, and not playing when not active");

    r = m::resolve(topology, state_of(state_text(1, "nearfield", three)), open);
    check(near(r.gain[2], db_gain(-25.5)) && r.gain[0] == 0.0 && near(r.gain[3], db_gain(-25.5)),
          "active nearfield: the shared sub follows nearfield");
    r = m::resolve(topology, state_of(state_text(1, "all", three)), open);
    check(near(r.gain[2], db_gain(-18.5)) && near(r.gain[0], db_gain(-18.5)) && near(r.gain[3], db_gain(-25.5)),
          "active all: every set plays, the sub follows the first of its sets");
    r = m::resolve(topology, state_of(state_text(1, "phones", three)), open);
    check(r.active == 0 && near(r.gain[0], db_gain(-18.5)) && r.gain[3] == 0.0,
          "a headphones set named active is taken as the first speakers set");
    auto with_studio = three;
    with_studio.push_back({"studio", "0.0"});
    r = m::resolve(topology, state_of(state_text(1, "studio", with_studio)), open);
    check(r.active == 0 && r.gain[3] == 0.0 && near(r.gain[0], db_gain(-18.5)),
          "an active set the preset lacks is the first speakers set; its line is ignored");

    // Clamps: level to max_db, level + trim to max_db, never above 0 dB.
    const m::Limits capped = limits_of(limits_text("-6.0"));
    r = m::resolve(topology, state_of(state_text(1, "all", {{"mains", "-3.0"}, {"nearfield", "-10.0", "12.0"}, {"phones", "-20.0", "3.0"}})),
                   capped);
    check(r.sets[0].level == -60 && r.sets[0].total == -60 && near(r.gain[0], db_gain(-6.0)), "a level is clamped to max_db");
    check(r.sets[1].total == -60 && near(r.gain[3], db_gain(-6.0)), "level plus trim is clamped to max_db");
    check(r.sets[2].total == -170, "a trim within max_db applies");
    r = m::resolve(topology, state_of(state_text(1, "all", {{"mains", "0.0", "12.0"}})), open);
    check(r.sets[0].total == 0 && r.gain[0] == 1.0, "never above 0 dB, whatever the trim");
    for (const double g : r.gain) check(g >= 0.0 && g <= 1.0, "every gain in [0, 1]");

    // Dim, mute, a missing set at its reference, folds.
    r = m::resolve(topology,
                   state_of(state_text(1, "all", {{"mains", "-18.5", "0.0", 1, 0, "mono"}, {"phones", "-30.0", "0.0", 0, 1, "mono"}},
                                       kZeros, kZeros, "-20.0")),
                   limits_of(limits_text("-6.0", "last", "-30.0", "ref id=nearfield level_db=-24.0 note=\"\"\n")));
    check(r.sets[0].total == -385 && near(r.gain[0], db_gain(-38.5)), "dim adds dim_db to the total");
    check(r.sets[2].mute && r.gain[14] == 0.0 && r.gain[15] == 0.0 && !r.sets[2].playing, "a muted set is silent");
    check(r.sets[1].level == -240 && r.sets[1].trim == 0 && near(r.gain[3], db_gain(-24.0)),
          "a set with no state line plays at its reference");
    check(r.sets[0].fold == 1 && r.sets[2].fold == 0 && r.sets[1].fold == 0, "a fold the set offers, else full");
    r = m::resolve(topology, state_of(state_text(1, "all", {{"mains", "-18.5", "0.0", 0, 0, "stereo"}})), capped);
    check(r.sets[0].fold == 0 && r.sets[1].level == -100 && r.sets[1].total == -100,
          "an unknown fold is full; a set with no ref plays at -10.0");

    // Subs, output mute, solo scoped to one set.
    r = m::resolve(topology, state_of(state_text(1, "all", three, kZeros, kZeros, "-20.0", "off")), open);
    check(r.gain[2] == 0.0 && near(r.gain[0], db_gain(-18.5)), "subs off silences the subs only");
    r = m::resolve(topology, state_of(state_text(1, "all", three, kZeros, flags_with({1, 6, 14}))), open);
    check(r.gain[1] == 0.0 && r.gain[14] == 0.0 && near(r.gain[0], db_gain(-18.5)) && r.gain[6] == 1.0,
          "an output mute silences its output; one in no set is untouched");
    r = m::resolve(topology, state_of(state_text(1, "all", three, flags_with({0, 7}))), open);
    check(near(r.gain[0], db_gain(-18.5)) && r.gain[1] == 0.0 && r.gain[2] == 0.0,
          "a solo silences the rest of its set, its sub too");
    check(near(r.gain[3], db_gain(-25.5)) && near(r.gain[14], db_gain(-30.0)) && r.gain[7] == 1.0,
          "a solo is scoped to its set: other sets play, an output in no set is untouched");
    r = m::resolve(topology, state_of(state_text(1, "nearfield", three, flags_with({3}))), open);
    check(near(r.gain[3], db_gain(-25.5)) && r.gain[4] == 0.0 && r.gain[2] == 0.0 && near(r.gain[14], db_gain(-30.0)),
          "a nearfield solo silences nearfield and the sub it shares, not the headphones");
    r = m::resolve(topology, state_of(state_text(1, "nearfield", three, flags_with({2}))), open);
    check(near(r.gain[2], db_gain(-25.5)) && r.gain[3] == 0.0 && r.gain[4] == 0.0, "a soloed shared sub plays alone in the active set");
    r = m::resolve(topology, state_of(state_text(1, "mains", three, flags_with({3}))), open);
    check(near(r.gain[0], db_gain(-18.5)) && near(r.gain[2], db_gain(-18.5)), "a solo in an inactive set does not touch the active one");
}

void test_ramp_choice() {
    const DspStage stage = DspStage::load(monitored());
    const auto& topology = stage.monitor();
    const m::Limits open = limits_of(limits_text());
    const std::vector<SetLine> three = {{"mains", "-18.5"}, {"nearfield", "-24.0"}, {"phones", "-30.0"}};
    const auto base = m::resolve(topology, state_of(state_text(1, "all", three)), open);
    const auto all_are = [](const std::array<std::uint32_t, kChannels>& ramps, std::uint32_t value) {
        for (const auto r : ramps) {
            if (r != value) return false;
        }
        return true;
    };
    auto levels = three;
    levels[0].level = "-12.0";
    levels[2].trim = "3.0";
    auto ramps = m::ramp_frames(base, m::resolve(topology, state_of(state_text(2, "all", levels)), open), false, 48000);
    check(all_are(ramps, 1920), "levels and trims only: 40 ms");
    auto muted = three;
    muted[1].mute = 1;
    ramps = m::ramp_frames(base, m::resolve(topology, state_of(state_text(2, "all", muted)), open), false, 48000);
    check(ramps[3] == 480 && ramps[4] == 480 && ramps[0] == 1920 && ramps[14] == 1920, "a set mute: 10 ms on that set");
    auto mixed = muted;
    mixed[0].level = "-12.0";
    ramps = m::ramp_frames(base, m::resolve(topology, state_of(state_text(2, "all", mixed)), open), false, 48000);
    check(ramps[3] == 480 && ramps[0] == 1920, "a mute here and a level there: each output its own ramp");
    auto folded = three;
    folded[0].fold = "mono";
    ramps = m::ramp_frames(base, m::resolve(topology, state_of(state_text(2, "all", folded)), open), false, 48000);
    check(ramps[0] == 480 && ramps[3] == 1920, "a fold: 10 ms on that set");
    ramps = m::ramp_frames(base, m::resolve(topology, state_of(state_text(2, "all", three, flags_with({0}))), open), false, 48000);
    check(ramps[0] == 480 && ramps[1] == 480 && ramps[2] == 480 && ramps[3] == 1920, "a solo: 10 ms on its set");
    ramps = m::ramp_frames(base, m::resolve(topology, state_of(state_text(2, "all", three, kZeros, flags_with({14}))), open), false, 48000);
    check(ramps[14] == 480 && ramps[15] == 1920, "an output mute: 10 ms on that output");
    for (const auto& changed : {state_text(2, "mains", three), state_text(2, "all", three, kZeros, kZeros, "-10.0"),
                                state_text(2, "all", three, kZeros, kZeros, "-20.0", "off")}) {
        ramps = m::ramp_frames(base, m::resolve(topology, state_of(changed), open), false, 48000);
        check(all_are(ramps, 480), "active, dim_db or subs: 10 ms everywhere");
    }
    check(all_are(m::ramp_frames(base, base, true, 48000), 480), "a limits change: 10 ms everywhere");
    check(all_are(m::ramp_frames(base, m::resolve(topology, state_of(state_text(2, "all", levels)), open), false, 96000), 3840),
          "the ramps follow the rate");
}

// ---- the control ----------------------------------------------------------------

void test_applied_status_and_retry(const std::string& root, const std::vector<std::string>& examples) {
    Rig rig(root, "applied");
    put(rig.paths.limits, limits_text());
    put(rig.paths.state, state_text(5, "mains", {{"mains", "-18.5"}, {"nearfield", "-24.0", "-1.5", 0, 0, "stereo"}, {"phones", "-30.0"}}));
    rig.control->poll(100 * kMs);
    check(rig.control->mode() == m::Mode::applied && rig.control->seq() == 5u && rig.control->applied() == 1,
          "a valid state file is applied at the first poll");
    check(rig.control->publishes() == 1 && near(rig.control->published().gain[0], db_gain(-18.5)) &&
              rig.control->published().gain[3] == 0.0 && rig.control->published().gain[7] == 1.0,
          "and published at once");
    const m::Status status = rig.status();
    check(status.gen == 1 && status.seq == 5u && status.mode == m::Mode::applied && status.active == "mains" && status.t_us == 100000,
          "the status header");
    check(status.sets.size() == 3 && status.sets[0].gain == -185 && !status.sets[1].gain && status.sets[1].fold == "stereo" &&
              status.sets[1].folds == std::vector<std::string>{"full", "stereo"} && status.sets[2].headphones &&
              status.sets[2].folds == std::vector<std::string>{"full"},
          "the status sets: gains, -inf for a set not playing, the folds offered");
    check(status.outs.size() == 8 && status.outs[2].n == 2 && status.outs[2].sub && status.outs[2].set == "mains" &&
              status.outs[3].n == 2 && status.outs[3].set == "nearfield" && status.outs[0].label == "L",
          "the status outputs: the shared sub once per set");
    check(status.outs[2].label == "Sub 'big' / one", "a label's quote and backslash are replaced");
    // The same line kinds, in the same order, as the contract's example.
    const auto kinds = [](const std::string& text) {
        std::string out;
        std::size_t at = 0;
        while (at < text.size()) {
            const std::size_t end = text.find('\n', at);
            const std::string line = text.substr(at, end - at);
            const std::string head = line.substr(0, line.find_first_of(" ="));
            if (out.empty() || out.substr(out.rfind(',') + 1) != head) out += "," + head;
            at = end + 1;
        }
        return out;
    };
    if (examples.size() == 3) check(kinds(slurp(rig.paths.status)) == kinds(examples[2]), "the status has the example's shape");
    check(m::render_status(status) == slurp(rig.paths.status), "the status round-trips through its own parser");

    // Unchanged: no rewrite.
    rig.control->poll(110 * kMs);
    rig.control->poll(120 * kMs);
    check(rig.control->status_gen() == 1, "no change, no rewrite");
    // The same state with a new seq: the status changes (seq), the gains do not.
    put(rig.paths.state, state_text(6, "mains", {{"mains", "-18.5"}, {"nearfield", "-24.0", "-1.5", 0, 0, "stereo"}, {"phones", "-30.0"}}));
    rig.control->poll(130 * kMs);
    check(rig.control->status_gen() == 2 && rig.status().seq == 6u && rig.control->publishes() == 1,
          "a new seq rewrites the status and publishes nothing");

    // Invalid: refused, the state in force stays.
    put(rig.paths.state, "MONITOR-STATE v=1 seq=7\nactive=mains\nend\n");
    rig.control->poll(140 * kMs);
    check(rig.control->mode() == m::Mode::refused && !rig.control->reason().empty() && rig.control->refused() == 1,
          "an invalid state file is refused");
    check(rig.control->publishes() == 1 && rig.control->state().seq == 6, "the previous state stays in force");
    const m::Status refused = rig.status();
    check(refused.mode == m::Mode::refused && refused.seq == 6u && !refused.reason.empty() && refused.sets[0].gain == -185,
          "the status says refused, with the last valid seq and its levels");

    // Previous update not yet taken: retried, always with the newest state.
    rig.take();
    put(rig.paths.state, state_text(8, "mains", {{"mains", "-10.0"}, {"phones", "-30.0"}}));
    rig.control->poll(150 * kMs);
    check(rig.control->publishes() == 2 && rig.control->mode() == m::Mode::applied, "a valid file after a refusal is applied");
    put(rig.paths.state, state_text(9, "mains", {{"mains", "-12.0"}, {"phones", "-30.0"}}));
    rig.control->poll(160 * kMs);
    check(rig.control->publishes() == 2, "a publish waits while the previous one is not taken");
    put(rig.paths.state, state_text(10, "mains", {{"mains", "-14.0"}, {"phones", "-30.0"}}));
    rig.control->poll(170 * kMs);
    check(rig.control->publishes() == 2, "still waiting");
    rig.take();
    rig.control->poll(180 * kMs);
    check(rig.control->publishes() == 3 && near(rig.control->published().gain[0], db_gain(-14.0)),
          "once taken, the newest state is published, not the one that waited");
    check(rig.control->published().ramp_frames[0] == 1920, "a level change ramps over 40 ms");
    rig.take();
    // A level then a mute before either is taken: the mute's 10 ms is kept for the muted set.
    put(rig.paths.state, state_text(11, "mains", {{"mains", "-14.0"}, {"phones", "-30.0", "0.0", 0, 1}}));
    rig.control->poll(190 * kMs);
    put(rig.paths.state, state_text(12, "mains", {{"mains", "-16.0"}, {"phones", "-30.0", "0.0", 0, 1}}));
    rig.control->poll(200 * kMs);   // the mute published at 190; this one waits
    rig.take();
    rig.control->poll(210 * kMs);
    check(rig.control->published().gain[14] == 0.0 && rig.control->published().ramp_frames[0] == 1920,
          "after a published mute, a level change is a level ramp");
}

void test_unpublished_mute_keeps_fast_ramp(const std::string& root) {
    Rig rig(root, "fastkeep");
    put(rig.paths.state, state_text(1, "mains", {{"mains", "-14.0"}, {"phones", "-30.0"}}));
    rig.control->poll(10 * kMs);   // published, not taken
    put(rig.paths.state, state_text(2, "mains", {{"mains", "-14.0"}, {"phones", "-30.0", "0.0", 0, 1}}));
    rig.control->poll(20 * kMs);   // the mute waits
    put(rig.paths.state, state_text(3, "mains", {{"mains", "-16.0"}, {"phones", "-30.0", "0.0", 0, 1}}));
    rig.control->poll(30 * kMs);   // a level change on top
    rig.take();
    rig.control->poll(40 * kMs);
    check(rig.control->published().gain[14] == 0.0 && rig.control->published().ramp_frames[14] == 480 &&
              rig.control->published().ramp_frames[0] == 1920,
          "a mute not yet published keeps its 10 ms when a level change lands on top of it");
}

void test_set_switch(const std::string& root) {
    Rig rig(root, "switch");
    const std::vector<SetLine> three = {{"mains", "-18.5"}, {"nearfield", "-24.0"}, {"phones", "-30.0"}};
    put(rig.paths.state, state_text(1, "mains", three));
    rig.control->poll(0);
    rig.take();
    const auto before = rig.control->published();
    put(rig.paths.state, state_text(2, "nearfield", three));
    rig.control->poll(10 * kMs);
    const auto first = rig.control->published();
    check(rig.control->publishes() == 2 && rig.control->switching(), "a switch publishes its first step");
    check(first.gain[0] == 0.0 && first.gain[1] == 0.0 && first.gain[3] == 0.0 && first.gain[4] == 0.0,
          "first step: the old set goes down and the new one has not come up");
    check(near(first.gain[2], std::min(before.gain[2], db_gain(-24.0))) && near(first.gain[14], db_gain(-30.0)),
          "first step: each output at min(old, new); the headphones untouched");
    for (const auto r : first.ramp_frames) check(r == 480, "the first step is a 10 ms ramp");
    rig.control->poll(30 * kMs);
    check(rig.control->publishes() == 2, "the second step waits for the first to be taken");
    rig.take();
    rig.control->poll(40 * kMs);   // seen taken here
    rig.control->poll(45 * kMs);
    check(rig.control->publishes() == 2, "and then for 10 ms after it was seen taken");
    rig.control->poll(50 * kMs);
    const auto second = rig.control->published();
    check(rig.control->publishes() == 3 && !rig.control->switching(), "the second step at 10 ms");
    check(near(second.gain[3], db_gain(-24.0)) && near(second.gain[2], db_gain(-24.0)) && second.gain[0] == 0.0,
          "second step: the new set at its level");
    for (const auto r : second.ramp_frames) check(r == 480, "the second step is a 10 ms ramp");
    check(rig.status().active == "nearfield" && rig.status().sets[1].gain == -240, "the status says nearfield");

    // A change during the wait replaces the final target.
    rig.take();
    put(rig.paths.state, state_text(3, "mains", three));
    rig.control->poll(60 * kMs);
    check(rig.control->publishes() == 4 && rig.control->switching(), "back to mains: first step");
    rig.take();
    rig.control->poll(65 * kMs);
    auto louder = three;
    louder[0].level = "-12.0";
    put(rig.paths.state, state_text(4, "mains", louder));
    rig.control->poll(70 * kMs);
    check(rig.control->publishes() == 4, "a level change during the wait publishes nothing that goes up");
    rig.control->poll(75 * kMs);
    check(rig.control->publishes() == 5 && near(rig.control->published().gain[0], db_gain(-12.0)),
          "the final step carries the newest level, on the first step's schedule");
    // A change during the wait that lowers something: a new first step, and the wait starts again.
    rig.take();
    put(rig.paths.state, state_text(5, "nearfield", louder));
    rig.control->poll(80 * kMs);
    rig.take();
    rig.control->poll(85 * kMs);
    auto quieter = louder;
    quieter[2].level = "-40.0";
    put(rig.paths.state, state_text(6, "nearfield", quieter));
    rig.control->poll(90 * kMs);
    check(rig.control->publishes() == 7 && near(rig.control->published().gain[14], db_gain(-40.0)) &&
              rig.control->published().gain[3] == 0.0,
          "a lower level during the wait goes down at once, the new set still down");
    rig.take();
    rig.control->poll(95 * kMs);
    check(rig.control->publishes() == 7, "the wait restarts from that step's take");
    rig.control->poll(105 * kMs);
    check(rig.control->publishes() == 8 && near(rig.control->published().gain[3], db_gain(-24.0)), "then the final step");
    // all -> one set: the others go down first, the one that stays is not dipped.
    rig.take();
    put(rig.paths.state, state_text(7, "all", quieter));
    rig.control->poll(110 * kMs);
    check(rig.control->publishes() == 9 && !rig.control->switching() && near(rig.control->published().gain[3], db_gain(-24.0)) &&
              near(rig.control->published().gain[0], db_gain(-12.0)),
          "to all: nothing goes down, so the new gains go out at once and the staying set is not dipped");
}

void test_start_rules(const std::string& root) {
    const std::vector<SetLine> remembered = {{"mains", "-18.0", "1.0", 1, 0, "mono"}, {"nearfield", "-22.0", "0.0", 0, 1}};
    const std::string saved = state_text(30, "nearfield", remembered, flags_with({0}), flags_with({15}), "-15.0", "off");
    {
        Rig rig(root, "start-defaults");
        rig.control->poll(1 * kMs);
        const m::Status status = rig.status();
        check(rig.control->mode() == m::Mode::start && status.mode == m::Mode::start && !status.seq,
              "no state file and no copy: state=start, seq=none");
        check(status.active == "mains" && status.dim_db == -200 && status.subs, "the defaults: the first speakers set active");
        check(status.sets[0].level == -300 && status.sets[1].level == -300 && status.sets[2].level == -300,
              "every set at start_db (defaults: start=last, -30.0)");
        check(rig.control->publishes() == 1 && near(rig.control->published().gain[0], db_gain(-30.0)), "and published");
    }
    {
        Rig rig(root, "start-last");
        put(rig.paths.limits, limits_text("-10.0", "last", "-40.0"));
        put(rig.paths.saved, saved);
        rig.control->poll(1 * kMs);
        const m::Status status = rig.status();
        check(status.mode == m::Mode::start && status.active == "nearfield" && status.dim_db == -150 && !status.subs,
              "start=last: the remembered copy");
        check(status.sets[0].level == -180 && status.sets[0].trim == 10 && status.sets[0].dim && status.sets[0].fold == "mono" &&
                  status.sets[1].mute && status.sets[2].level == -400,
              "start=last: the copy's sets; a set it lacks at start_db");
        check(!status.solo[0] && status.out_mute[15], "start=last: the copy's solo is ignored, its mutes kept");
    }
    {
        Rig rig(root, "start-last-none");
        put(rig.paths.limits, limits_text("-20.0", "last", "-10.0"));
        rig.control->poll(1 * kMs);
        check(rig.status().sets[0].level == -200, "start=last with no copy: start_db clamped to max_db");
    }
    {
        Rig rig(root, "start-reference");
        put(rig.paths.limits, limits_text("-20.0", "reference", "-40.0", "ref id=mains level_db=-25.0 note=\"\"\nref id=nearfield level_db=-10.0 note=\"\"\n"));
        put(rig.paths.saved, saved);
        rig.control->poll(1 * kMs);
        const m::Status status = rig.status();
        check(status.sets[0].level == -250 && status.sets[1].level == -200 && status.sets[2].level == -200,
              "start=reference: each set's reference, clamped (phones: -10.0 clamped to -20.0)");
        check(status.sets[0].dim && status.sets[1].mute && status.active == "nearfield" && !status.solo[0],
              "start=reference: the copy for everything but levels");
    }
    {
        Rig rig(root, "start-fixed");
        put(rig.paths.limits, limits_text("-12.0", "fixed", "-6.0"));
        put(rig.paths.saved, saved);
        rig.control->poll(1 * kMs);
        const m::Status status = rig.status();
        check(status.sets[0].level == -120 && status.sets[1].level == -120 && status.sets[0].dim,
              "start=fixed: start_db clamped, the copy for the rest");
    }
    {
        Rig rig(root, "start-fixed-none");
        put(rig.paths.limits, limits_text("0.0", "fixed", "-45.0"));
        rig.control->poll(1 * kMs);
        check(rig.status().sets[1].level == -450 && rig.status().active == "mains", "start=fixed with no copy");
    }
    {
        Rig rig(root, "start-invalid");
        put(rig.paths.saved, saved);
        put(rig.paths.state, "garbage\n");
        rig.control->poll(1 * kMs);
        const m::Status status = rig.status();
        check(status.mode == m::Mode::start && status.reason.find("state file refused") == 0 && status.active == "nearfield",
              "an invalid state file at the first poll: the start rule, with the reason");
        put(rig.paths.state, "MONITOR-STATE v=1 seq=x\n");
        rig.control->poll(2 * kMs);
        check(rig.status().mode == m::Mode::start && rig.control->refused() == 2, "it stays start through another invalid file");
        put(rig.paths.state, state_text(31, "mains", {{"mains", "-9.0"}}));
        rig.control->poll(3 * kMs);
        check(rig.status().mode == m::Mode::applied && rig.status().seq == 31u && rig.status().reason.empty(),
              "and becomes applied at the first valid one");
    }
    {
        Rig rig(root, "start-badcopy");
        put(rig.paths.saved, replaced(saved, "end\n", "end\nmore\n"));
        rig.control->poll(1 * kMs);
        check(rig.status().active == "mains" && rig.status().sets[0].level == -300, "an invalid copy is no copy");
    }
    {
        Rig rig(root, "start-linkcopy");
        put(rig.directory + "/real", saved);
        ::symlink((rig.directory + "/real").c_str(), rig.paths.saved.c_str());
        rig.control->poll(1 * kMs);
        check(rig.status().active == "mains", "a copy that is a link is no copy");
    }
    {
        Rig rig(root, "start-later");
        put(rig.paths.saved, saved);
        put(rig.paths.state, state_text(40, "mains", {{"mains", "-9.0"}}));
        rig.control->poll(1 * kMs);
        check(rig.status().mode == m::Mode::applied && rig.status().active == "mains",
              "with a valid state file the copy is not read");
    }
}

void test_limits_follow(const std::string& root) {
    Rig rig(root, "limits");
    put(rig.paths.state, state_text(1, "mains", {{"mains", "-3.0"}, {"phones", "-2.0"}}));
    rig.control->poll(1 * kMs);
    check(near(rig.control->published().gain[0], db_gain(-3.0)), "no limits file: max_db 0.0");
    rig.take();
    put(rig.paths.limits, limits_text("-10.0"));
    rig.control->poll(2 * kMs);
    check(near(rig.control->published().gain[0], db_gain(-10.0)) && rig.control->published().ramp_frames[0] == 480 &&
              rig.status().sets[0].level == -100,
          "a lower max_db lowers a set at once, 10 ms");
    rig.take();
    put(rig.paths.limits, "MONITOR-LIMITS v=1\nmax_db=-99.0\n");
    rig.control->poll(3 * kMs);
    check(!rig.control->limits_valid() && near(rig.control->published().gain[0], db_gain(-3.0)), "an invalid limits file is the defaults");
    rig.take();
    put(rig.paths.limits, limits_text("-10.0"));
    rig.control->poll(4 * kMs);
    rig.take();
    ::unlink(rig.paths.limits.c_str());
    rig.control->poll(5 * kMs);
    check(near(rig.control->published().gain[0], db_gain(-3.0)), "a limits file removed is the defaults");
}

void test_folds_reach_the_stage(const std::string& root) {
    Rig rig(root, "folds");
    put(rig.paths.state, state_text(1, "all", {{"mains", "-6.0", "0.0", 0, 0, "mono"}, {"nearfield", "-6.0", "0.0", 0, 0, "stereo"}}));
    rig.control->poll(1 * kMs);
    std::vector<float> block(kChannels, 0.0F);
    rig.stage.process(block.data(), 1);
    check(rig.stage.fold_crossfading(0) && rig.stage.fold_crossfading(1) && !rig.stage.fold_crossfading(2),
          "the folds asked for are requested of the stage");
    put(rig.paths.state, state_text(2, "all", {{"mains", "-6.0", "0.0", 0, 0, "5.1"}, {"nearfield", "-6.0"}}));
    rig.control->poll(2 * kMs);
    std::vector<float> long_block(kChannels * 1000, 0.0F);
    rig.stage.process(long_block.data(), 1000);
    rig.stage.process(long_block.data(), 1000);
    check(rig.stage.fold(0) == 0 && rig.stage.fold(1) == 0, "a fold the set lacks is full");
}

void test_idle(const std::string& root) {
    Rig rig(root, "idle", straight());
    put(rig.paths.state, state_text(1, "mains", {{"mains", "-6.0"}}));
    for (int i = 0; i < 5; ++i) rig.control->poll(i * kMs);
    const m::Status status = rig.status();
    check(rig.control->idle() && status.mode == m::Mode::idle && status.sets.empty() && status.outs.empty() && status.gen == 1,
          "a preset with no monitor section: one idle status, no set or out lines");
    check(status.reason == "the running preset has no monitor section" && status.active == "all", "the idle status says why");
    check(rig.control->publishes() == 0 && rig.gains->generation() == 0 && rig.control->applied() == 0,
          "and nothing is read or published");
    DspStage none;
    MonitorGains gains;
    m::MonitorControl unloaded(none, gains, {rig.directory + "/s", rig.directory + "/c", rig.directory + "/l",
                                             rig.directory + "/unloaded.status"},
                               48000);
    unloaded.poll(1);
    std::string reason;
    const auto parsed = m::parse_status(slurp(rig.directory + "/unloaded.status"), reason);
    check(parsed && parsed->mode == m::Mode::idle && parsed->reason == "no DSP preset", "no preset at all: idle too");
    // An idle status that could not be written is tried again.
    m::MonitorControl unwritable(none, gains, {"", "", "", rig.directory + "/missing/dir/status"}, 48000);
    unwritable.poll(1);
    unwritable.poll(2);
    check(unwritable.status_failures() == 2 && unwritable.status_gen() == 0, "an unwritable status is retried, gen unmoved");
}

}  // namespace

int main(int argc, char** argv) {
    std::string contract;
    if (argc > 1) {
        contract = argv[1];
    } else {
        std::string here = __FILE__;
        const std::size_t slash = here.rfind('/');
        here = slash == std::string::npos ? "." : here.substr(0, slash);
        contract = here + "/../../docs/web/MONITOR-FILES.md";
    }
    const std::vector<std::string> examples = contract_examples(contract);
    char root_template[] = "/tmp/monitor_ctl_test.XXXXXX";
    const char* tmp = std::getenv("TMPDIR");
    std::string pattern = std::string(tmp != nullptr ? tmp : "/tmp") + "/monitor_ctl_test.XXXXXX";
    std::vector<char> buffer(pattern.begin(), pattern.end());
    buffer.push_back('\0');
    const char* root = ::mkdtemp(buffer.data());
    if (root == nullptr) root = ::mkdtemp(root_template);
    if (root == nullptr) {
        std::printf("FAIL: no temporary directory\n");
        return 1;
    }
    test_contract_examples(examples);
    if (examples.size() == 3) {
        test_state_refusals(examples[0]);
        test_limits_refusals(examples[1]);
        test_status_refusals(examples[2]);
        test_hostile_files(root, examples[0]);
    }
    test_resolve();
    test_ramp_choice();
    test_applied_status_and_retry(root, examples);
    test_unpublished_mute_keeps_fast_ramp(root);
    test_set_switch(root);
    test_start_rules(root);
    test_limits_follow(root);
    test_folds_reach_the_stage(root);
    test_idle(root);
    std::system(("rm -rf '" + std::string(root) + "'").c_str());
    if (failures != 0) {
        std::printf("%d failure(s)\n", failures);
        return 1;
    }
    std::printf("monitor_ctl_test: all checks passed\n");
    return 0;
}
