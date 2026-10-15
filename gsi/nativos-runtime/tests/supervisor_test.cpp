#include "../src/session_supervisor.h"
#include <cassert>
#include <csignal>
#include <cstdio>
#include <poll.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

int markerFd;
ino_t originalMount;
bool keepRunning = false;
int payload() {
#ifndef NATIVOS_TEST_NO_PID_NAMESPACE
    assert(getpid() == 2 && getppid() == 1);
#endif
    struct stat mount{};
    assert(stat("/proc/self/ns/mnt", &mount) == 0);
    assert(mount.st_ino != originalMount);
    assert(write(markerFd, "R", 1) == 1);
    pid_t orphan = fork();
    assert(orphan >= 0);
    if (orphan == 0) {
        assert(setsid() >= 0);
        signal(SIGTERM, SIG_IGN);
        for (;;) pause();
    }
    if (keepRunning) for (;;) pause();
    return 17;
}
void runCase(int termination) {
    struct stat mount{};
    assert(stat("/proc/self/ns/mnt", &mount) == 0);
    originalMount = mount.st_ino;
    int pipeFds[2];
    assert(pipe(pipeFds) == 0);
    pid_t runner = fork();
    assert(runner >= 0);
    if (runner == 0) {
        close(pipeFds[0]);
        markerFd = pipeFds[1];
        keepRunning = termination != 0;
        _exit(nativos::superviseSession(payload));
    }
    close(pipeFds[1]);
    pollfd ready{pipeFds[0], POLLIN, 0};
    assert(poll(&ready, 1, 5000) > 0);
    char marker;
    assert(read(pipeFds[0], &marker, 1) == 1 && marker == 'R');
    if (termination) assert(kill(runner, termination) == 0);
    // EOF proves even the orphan's inherited pipe descriptor was closed.
    assert(poll(&ready, 1, 5000) > 0);
    assert(read(pipeFds[0], &marker, 1) == 0);
    int status;
    assert(waitpid(runner, &status, 0) == runner);
    if (termination == SIGKILL) assert(WIFSIGNALED(status) && WTERMSIG(status) == SIGKILL);
    else if (termination == SIGTERM) assert(WIFEXITED(status) && WEXITSTATUS(status) == 143);
    else assert(WIFEXITED(status) && WEXITSTATUS(status) == 17);
    assert(stat("/proc/self/ns/mnt", &mount) == 0 && mount.st_ino == originalMount);
    close(pipeFds[0]);
}
int main() {
    if (geteuid() != 0) return 77;
    runCase(0);
    runCase(SIGTERM);
    runCase(SIGKILL);
    std::puts("Supervisor tests passed: private namespace, exit status, orphan cleanup, stop and runner crash");
}
