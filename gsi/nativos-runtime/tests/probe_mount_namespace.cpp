#include <sched.h>
#include <sys/mount.h>
#include <unistd.h>
#include <cstdio>
#include <cstring>
int main(int argc, char** argv) {
    if (argc > 2 || (argc == 2 && strcmp(argv[1], "--session"))) return 1;
    if (geteuid() != 0) return 1;
    if (unshare(CLONE_NEWNS) || mount(nullptr, "/", nullptr, MS_REC | MS_PRIVATE, nullptr)) {
        perror("private probe namespace"); return 2;
    }
    const char* script = argc == 2 ? "/data/local/tmp/nativos-session-script-20261004.sh" : "/data/local/tmp/nativos-probe-script-20261003.sh";
    execl("/system/bin/sh", "sh", script, static_cast<char*>(nullptr));
    perror("probe script"); return 3;
}
