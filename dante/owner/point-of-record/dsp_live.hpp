// Live coefficient updates for the owner's DSP stage: the bridge's control
// thread (work/phase4-bridge/LIVE_COEFFICIENTS_DESIGN.md, step 3) as one
// object with a poll() the owner's thread calls every 50 ms. Same file
// protocol and the same status line, so whatever writes a live file for the
// bridge writes one for the owner.
//
// poll() stats the live file; when the inode, size or mtime moved it reads the
// file, loads it through DspStage::load (allocation is fine here: this is
// never the loop thread) and hands the numbers to the running stage with
// publish(), which refuses without touching anything the loop reads when the
// shape differs. "previous update not yet taken" is kept and retried on the
// next poll. A file that predates the process is ignored: a restart comes
// back on the installed preset, never on a preview left behind.
//
// The outcome of every file is one line, rewritten by rename:
//
//   DSPLIVE gen=N sha256=HEX state=idle|applied|refused|ignored reason="..." t_us=T
//
// where gen is the publish count the loop has taken so far.
//
// One difference from the bridge: its stage runs on every wake, the owner's
// only while a host is sending. The loop therefore calls OutDsp::take() on
// the wakes it does not filter, or a second update would wait for audio.
//
// No ALSA here, so dsp_live_test.cpp builds and runs on the Mac.
#pragma once

#include "atomic_file.hpp"
#include "usb16x16/bridge_core.hpp"

#include <sys/stat.h>
#include <time.h>

#include <cstdint>
#include <exception>
#include <fstream>
#include <optional>
#include <sstream>
#include <string>
#include <utility>

namespace usb16x16::owner {

class DspLive {
public:
    enum class Outcome { none, applied, refused, ignored };
    struct Event {
        Outcome outcome{Outcome::none};
        std::string sha;
        std::string reason;
    };

    // `started` is the wall clock the process began at: files older than it are ignored.
    DspLive(DspStage& stage, std::string path, std::string status_path, timespec started)
        : stage_(stage), path_(std::move(path)), status_path_(std::move(status_path)), started_(started) {
        clock_gettime(CLOCK_MONOTONIC, &born_);
    }

    // The status file's first line, so a reader can tell "no file yet" from "no owner".
    void announce() { write_status(std::string{}, "idle", "no live file yet"); }

    // One step. Control thread only.
    Event poll() {
        if (pending_) return try_publish();
        struct stat status{};
        if (::stat(path_.c_str(), &status) != 0) return {};   // absent is not an event
#ifdef __APPLE__
        const timespec modified = status.st_mtimespec;
#else
        const timespec modified = status.st_mtim;
#endif
        if (seen_any_ && status.st_ino == seen_inode_ && status.st_size == seen_size_ &&
            modified.tv_sec == seen_mtime_.tv_sec && modified.tv_nsec == seen_mtime_.tv_nsec) {
            return {};
        }
        seen_any_ = true;
        seen_inode_ = status.st_ino;
        seen_size_ = status.st_size;
        seen_mtime_ = modified;
        std::ifstream file(path_, std::ios::binary);
        std::ostringstream text;
        text << file.rdbuf();
        const std::string body = text.str();
        const std::string sha = sha256_hex(body);
        if (modified.tv_sec < started_.tv_sec ||
            (modified.tv_sec == started_.tv_sec && modified.tv_nsec < started_.tv_nsec)) {
            ++ignored_;
            write_status(sha, "ignored", "predates start");
            return {Outcome::ignored, sha, "predates start"};
        }
        try {
            pending_.emplace(DspStage::load(body, stage_.rate()));
        } catch (const std::exception& error) {
            ++refused_;
            write_status(sha, "refused", error.what());
            return {Outcome::refused, sha, error.what()};
        }
        pending_sha_ = sha;
        // Tried now rather than at the next poll, so the common case costs one interval, not two.
        return try_publish();
    }

    [[nodiscard]] std::uint64_t applied() const noexcept { return applied_; }
    [[nodiscard]] std::uint64_t refused() const noexcept { return refused_; }
    [[nodiscard]] std::uint64_t ignored() const noexcept { return ignored_; }
    [[nodiscard]] std::uint64_t status_failures() const noexcept { return status_failures_; }
    [[nodiscard]] bool waiting() const noexcept { return pending_.has_value(); }
    [[nodiscard]] const std::string& last_sha() const noexcept { return last_sha_; }

private:
    Event try_publish() {
        std::string reason;
        if (stage_.publish(*pending_, reason)) {
            ++applied_;
            last_sha_ = pending_sha_;
            write_status(pending_sha_, "applied", "");
            pending_.reset();
            return {Outcome::applied, last_sha_, ""};
        }
        if (reason == "previous update not yet taken") return {};
        ++refused_;
        write_status(pending_sha_, "refused", reason);
        pending_.reset();
        return {Outcome::refused, pending_sha_, reason};
    }

    void write_status(const std::string& sha, const char* state, const std::string& reason) noexcept {
        timespec now{};
        clock_gettime(CLOCK_MONOTONIC, &now);
        const long long elapsed_us = (now.tv_sec - born_.tv_sec) * 1000000LL + (now.tv_nsec - born_.tv_nsec) / 1000;
        const std::string line = "DSPLIVE gen=" + std::to_string(stage_.generation()) + " sha256=" + (sha.empty() ? "none" : sha) +
                           " state=" + state + " reason=\"" + reason + "\" t_us=" + std::to_string(elapsed_us) + "\n";
        if (!write_file_atomically(status_path_, line)) ++status_failures_;
    }

    DspStage& stage_;
    std::string path_;
    std::string status_path_;
    timespec started_{};
    timespec born_{};
    bool seen_any_{false};
    ino_t seen_inode_{};
    off_t seen_size_{};
    timespec seen_mtime_{};
    // A loaded update the loop has not yet made room for.
    std::optional<DspStage> pending_;
    std::string pending_sha_;
    std::string last_sha_;
    std::uint64_t applied_{0};
    std::uint64_t refused_{0};
    std::uint64_t ignored_{0};
    std::uint64_t status_failures_{0};
};

}  // namespace usb16x16::owner
