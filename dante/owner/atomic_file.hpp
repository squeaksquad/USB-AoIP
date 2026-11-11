// A small text file replaced whole, by rename, so a reader never sees half of
// one: the status and meter files the owner's off-loop threads publish.
#pragma once

#include <fcntl.h>
#include <unistd.h>

#include <cerrno>
#include <cstdio>
#include <string>

namespace usb16x16::owner {

// False when the file could not be written; the old one, if any, is left as it was.
inline bool write_file_atomically(const std::string& path, const std::string& text) noexcept {
    const std::string temporary = path + ".tmp";
    const int descriptor = ::open(temporary.c_str(), O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (descriptor < 0) return false;
    std::size_t written = 0;
    bool ok = true;
    while (written < text.size()) {
        const ssize_t result = ::write(descriptor, text.data() + written, text.size() - written);
        if (result < 0) {
            if (errno == EINTR) continue;
            ok = false;
            break;
        }
        written += static_cast<std::size_t>(result);
    }
    ::close(descriptor);
    if (!ok || std::rename(temporary.c_str(), path.c_str()) != 0) {
        ::unlink(temporary.c_str());
        return false;
    }
    return true;
}

}  // namespace usb16x16::owner
