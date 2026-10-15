#pragma once
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <algorithm>
#include <cerrno>

// Fixed root-owned destination, capped at 64 KiB per attempt. Continue draining
// after the limit so desktop processes can never block on a full log pipe.
class StartupLog {
    int reader = -1;
    int file = -1;
    size_t written = 0;
public:
    ~StartupLog() { closeLog(); }
    void closeLog() {
        if (reader >= 0) close(reader);
        if (file >= 0) close(file);
        reader = file = -1;
    }
    int prepare() {
        closeLog();
        written = 0;
        file = open("/data/misc/nativos/startup.log",
                    O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0644);
        struct stat st{};
        if (file < 0 || fstat(file, &st) || !S_ISREG(st.st_mode)
            || st.st_uid != 0 || st.st_nlink != 1 || (st.st_mode & 0022)
            || ftruncate(file, 0) || fchmod(file, 0644)) {
            closeLog(); return -1;
        }
        int pipeFds[2];
        if (pipe2(pipeFds, O_CLOEXEC)) { closeLog(); return -1; }
        reader = pipeFds[0];
        if (fcntl(reader, F_SETFL, O_NONBLOCK)) {
            close(pipeFds[1]); closeLog(); return -1;
        }
        return pipeFds[1];
    }
    void drain() {
        char bytes[2048];
        // Bound work per event-loop iteration to preserve socket responsiveness.
        for (int i = 0; reader >= 0 && i < 32; ++i) {
            ssize_t n = read(reader, bytes, sizeof(bytes));
            if (n <= 0) break;
            size_t count = std::min(static_cast<size_t>(n), 65536 - written);
            size_t offset = 0;
            while (offset < count) {
                ssize_t out = write(file, bytes + offset, count - offset);
                if (out < 0 && errno == EINTR) continue;
                if (out <= 0) break;
                offset += static_cast<size_t>(out);
            }
            written += offset;
        }
    }
};
