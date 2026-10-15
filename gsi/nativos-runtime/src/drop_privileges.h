#pragma once
#include <cerrno>
#include <grp.h>
#include <linux/capability.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <unistd.h>

namespace nativos {
// Single-threaded session child only, AFTER privileged namespace/mount setup.
// On failure the caller MUST _exit; credentials may already have changed.
// This is one layer, not a sandbox: also close inherited descriptors, remove
// host mounts, apply SELinux/seccomp, and use a dedicated allocated Android UID.
inline bool dropPrivileges(uid_t uid, gid_t gid) {
    if (uid == 0 || gid == 0 || uid == static_cast<uid_t>(-1)
        || gid == static_cast<gid_t>(-1)) { errno = EINVAL; return false; }
    if (prctl(PR_SET_NO_NEW_PRIVS, 1L, 0L, 0L, 0L)) return false;
    if (prctl(PR_SET_KEEPCAPS, 0L, 0L, 0L, 0L)) return false;
    // Enumerate the running kernel's capabilities, not just build-time headers.
    // EINVAL ends enumeration; every other failure is fatal.
    for (int cap = 0; ; ++cap) {
        int present = prctl(PR_CAPBSET_READ, cap, 0L, 0L, 0L);
        if (present < 0) {
            if (errno != EINVAL) return false;
            break;
        }
        if (present && prctl(PR_CAPBSET_DROP, cap, 0L, 0L, 0L)) return false;
    }
    if (setgroups(0, nullptr) || setresgid(gid, gid, gid)
        || setresuid(uid, uid, uid)) return false;
    __user_cap_header_struct header{_LINUX_CAPABILITY_VERSION_3, 0};
    __user_cap_data_struct empty[2]{};
    if (syscall(SYS_capset, &header, empty)) return false;
    // Empty permitted/inheritable sets also clear all ambient capabilities.
    return true;
}
}
