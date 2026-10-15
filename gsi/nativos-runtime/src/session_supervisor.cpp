#include "session_supervisor.h"
#include <cerrno>
#include <chrono>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dirent.h>
#include <fcntl.h>
#include <poll.h>
#include <sched.h>
#include <sys/mount.h>
#include <sys/prctl.h>
#include <sys/wait.h>
#include <unistd.h>

namespace {
volatile sig_atomic_t stopRequested = 0;
void onStop(int) { stopRequested = 1; }
bool handlers() {
    struct sigaction action{};
    action.sa_handler = onStop;
    sigemptyset(&action.sa_mask);
    return sigaction(SIGTERM, &action, nullptr) == 0
        && sigaction(SIGINT, &action, nullptr) == 0;
}
int exitCode(int status) {
    return WIFEXITED(status) ? WEXITSTATUS(status)
        : WIFSIGNALED(status) ? 128 + WTERMSIG(status) : 125;
}
// A subreaper owns adopted descendants too. Kill only its direct children,
// then repeat as further descendants are adopted. Unreaped children retain
// their PIDs, so a PID cannot be recycled between this read and kill().
void cleanupChildren() {
    for (;;) {
        char path[96];
        snprintf(path, sizeof(path), "/proc/self/task/%d/children", getpid());
        FILE* children = fopen(path, "re");
        if (children) {
            int pid;
            while (fscanf(children, "%d", &pid) == 1) {
                if (pid > 0) kill(pid, SIGKILL);
            }
            fclose(children);
        } else {
            // CONFIG_CHECKPOINT_RESTORE may omit the children file. The
            // kernel's PPid in stat provides the same direct-child boundary.
            DIR* proc = opendir("/proc");
            if (!proc) { perror("read session descendants"); return; }
            while (dirent* item = readdir(proc)) {
                char* end;
                long pid = strtol(item->d_name, &end, 10);
                if (*end || pid <= 0) continue;
                snprintf(path, sizeof(path), "/proc/%ld/stat", pid);
                FILE* stat = fopen(path, "re");
                if (!stat) continue;
                char line[2048];
                bool got = fgets(line, sizeof(line), stat) != nullptr;
                fclose(stat);
                char* commEnd = got ? strrchr(line, ')') : nullptr;
                int parent = 0;
                char state;
                if (commEnd && sscanf(commEnd + 1, " %c %d", &state, &parent) == 2
                    && parent == getpid()) kill(static_cast<pid_t>(pid), SIGKILL);
            }
            closedir(proc);
        }
        int status;
        pid_t result;
        do { result = waitpid(-1, &status, WNOHANG); } while (result > 0);
        if (result < 0 && errno == ECHILD) return;
        poll(nullptr, 0, 10);
    }
}
int finishSession(int code, bool pidNamespace) {
    if (!pidNamespace) cleanupChildren();
    return code;
}
int namespaceInit(int lifeline, int (*entry)(), bool pidNamespace) {
    // kill(-1) is safe only for PID 1 inside a private PID namespace. Vendor
    // kernels are allowed to omit CONFIG_PID_NS, so use a private process group
    // for the Linux payload on those devices instead.
    if ((pidNamespace && getpid() != 1) || !handlers()) return 125;
    if (!pidNamespace && prctl(PR_SET_CHILD_SUBREAPER, 1)) return 125;
    pid_t payload = fork();
    if (payload < 0) return 125;
    if (payload == 0) {
        if (!pidNamespace && setpgid(0, 0)) _exit(125);
        close(lifeline);
        signal(SIGTERM, SIG_DFL);
        signal(SIGINT, SIG_DFL);
        _exit(entry());
    }
    if (!pidNamespace) setpgid(payload, payload);
    bool terminating = false;
    auto deadline = std::chrono::steady_clock::now();
    for (;;) {
        pollfd life{lifeline, POLLIN, 0};
        int ready = poll(&life, 1, 50);
        if (ready > 0 && (life.revents & (POLLHUP | POLLERR | POLLNVAL))) return finishSession(125, pidNamespace);
        if (ready < 0 && errno != EINTR) return finishSession(125, pidNamespace);
        if (stopRequested && !terminating) {
            if (pidNamespace) kill(-1, SIGTERM);
            else kill(-payload, SIGTERM);
            terminating = true;
            deadline = std::chrono::steady_clock::now() + std::chrono::seconds(3);
        }
        if (terminating && std::chrono::steady_clock::now() >= deadline) return finishSession(143, pidNamespace);
        for (;;) {
            int status = 0;
            pid_t reaped = waitpid(-1, &status, WNOHANG);
            // Exiting PID 1 makes the kernel kill ALL namespace descendants,
            // including double-forked daemons that escaped process groups.
            if (reaped == payload) return finishSession(terminating ? 143 : exitCode(status), pidNamespace);
            if (reaped <= 0) break;
        }
    }
}
}

int nativos::superviseSession(int (*entry)()) {
    if (!entry || geteuid() != 0) return 125;
    stopRequested = 0;
    if (!handlers()) return 101;
    // A private mount namespace is required so Linux mounts never leak into
    // Android. PID, IPC and UTS namespaces are optional because many otherwise
    // Treble-compatible vendor kernels compile one or more of them out.
    if (unshare(CLONE_NEWNS)) return 102;
    bool pidNamespace = false;
#ifndef NATIVOS_TEST_NO_PID_NAMESPACE
    if (access("/proc/self/ns/pid", F_OK) == 0 && unshare(CLONE_NEWPID) == 0) {
        pidNamespace = true;
    }
#endif
    if (access("/proc/self/ns/ipc", F_OK) == 0) (void)unshare(CLONE_NEWIPC);
    if (access("/proc/self/ns/uts", F_OK) == 0) (void)unshare(CLONE_NEWUTS);
    if (mount(nullptr, "/", nullptr, MS_REC | MS_PRIVATE, nullptr)) return 103;
    int life[2];
    if (pipe2(life, O_CLOEXEC)) return 104;
    pid_t init = fork();
    if (init < 0) { close(life[0]); close(life[1]); return 105; }
    if (init == 0) {
        close(life[1]);
        if (prctl(PR_SET_PDEATHSIG, pidNamespace ? SIGKILL : SIGTERM)) _exit(125);
        // Lifeline also covers parent death before PR_SET_PDEATHSIG.
        _exit(namespaceInit(life[0], entry, pidNamespace));
    }
    close(life[0]);
    bool sent = false;
    auto deadline = std::chrono::steady_clock::now();
    int status = 0;
    for (;;) {
        pid_t reaped = waitpid(init, &status, WNOHANG);
        if (reaped == init) { close(life[1]); return exitCode(status); }
        if (reaped < 0 && errno != EINTR) {
            close(life[1]); // Child detects parent-lifeline closure and exits.
            return 125;
        }
        if (stopRequested && !sent) {
            kill(init, SIGTERM);
            sent = true;
            deadline = std::chrono::steady_clock::now() + std::chrono::seconds(4);
        }
        if (sent && std::chrono::steady_clock::now() >= deadline) kill(init, SIGKILL);
        poll(nullptr, 0, 50);
    }
}
