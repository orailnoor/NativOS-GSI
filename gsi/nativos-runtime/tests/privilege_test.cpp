#include "../src/drop_privileges.h"
#include <cassert>
#include <cstdio>
#include <sys/wait.h>

int main() {
    if (geteuid() != 0) {
        std::puts("Privilege test requires root in WSL; no phone access is used");
        return 77;
    }
    pid_t child = fork();
    assert(child >= 0);
    if (child == 0) {
        assert(!nativos::dropPrivileges(0, 65534));
        assert(geteuid() == 0);
        // Nobody is a disposable HOST TEST identity, never a production AID.
        assert(nativos::dropPrivileges(65534, 65534));
        uid_t r, e, s;
        gid_t gr, ge, gs;
        assert(getresuid(&r, &e, &s) == 0);
        assert(r == 65534 && e == r && s == r);
        assert(getresgid(&gr, &ge, &gs) == 0);
        assert(gr == 65534 && ge == gr && gs == gr);
        assert(getgroups(0, nullptr) == 0);
        assert(prctl(PR_GET_NO_NEW_PRIVS, 0L, 0L, 0L, 0L) == 1);
        __user_cap_header_struct header{_LINUX_CAPABILITY_VERSION_3, 0};
        __user_cap_data_struct caps[2]{};
        assert(syscall(SYS_capget, &header, caps) == 0);
        for (const auto& cap : caps)
            assert(!cap.effective && !cap.permitted && !cap.inheritable);
        for (int cap = 0; ; ++cap) {
            int result = prctl(PR_CAPBSET_READ, cap, 0L, 0L, 0L);
            if (result < 0) { assert(errno == EINVAL); break; }
            assert(result == 0);
        }
        assert(setuid(0) == -1 && errno == EPERM);
        assert(setgid(0) == -1 && errno == EPERM);
        _exit(0);
    }
    int status;
    assert(waitpid(child, &status, 0) == child);
    assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);
    assert(geteuid() == 0);
    std::puts("Privilege-drop tests passed in isolated child; parent unchanged");
}
