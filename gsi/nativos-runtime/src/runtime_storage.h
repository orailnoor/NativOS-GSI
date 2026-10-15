#pragma once
#include <cerrno>
#include <fcntl.h>
#include <string>
#include <sys/stat.h>
#include <unistd.h>

namespace nativos {
inline int checkedDirectory(int parent, const char* name, uid_t owner, mode_t mode) {
    bool created = mkdirat(parent, name, mode) == 0;
    if (!created && errno != EEXIST) return -1;
    int fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return -1;
    struct stat st{};
    if (fstat(fd, &st) || (!created && st.st_uid != owner)
        || (created && fchown(fd, owner, owner)) || fchmod(fd, mode)) {
        close(fd);
        return -1;
    }
    return fd;
}
// baseFd must refer to the service-owned directory supplied by init.
inline bool prepareStorage(int baseFd, uid_t uid) {
    struct stat st{};
    if (uid < 10000 || uid > 19999 || fstat(baseFd, &st)
        || st.st_uid != 0 || !S_ISDIR(st.st_mode) || (st.st_mode & 0022)) return false;
    int session = checkedDirectory(baseFd, "session", 0, 0700);
    if (session < 0) return false;
    close(session);
    for (const char* area : {"display", "homes", "packages"}) {
        int parent = checkedDirectory(baseFd, area, 0, 0711);
        if (parent < 0) return false;
        int user = checkedDirectory(parent, std::to_string(uid).c_str(), uid, 0700);
        close(parent);
        if (user < 0) return false;
        if (std::string(area) == "display") {
            int sockets = checkedDirectory(user, ".X11-unix", uid, 0700);
            if (sockets < 0) { close(user); return false; }
            close(sockets);
        }
        close(user);
    }
    return true;
}
}
