#include "protocol.h"
#include "runtime_storage.h"
#include "startup_log.h"
#include <cerrno>
#include <chrono>
#include <csignal>
#include <cstdlib>
#include <cstdio>
#include <fcntl.h>
#include <poll.h>
#include <string>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

namespace {
constexpr const char* runner = "/system/bin/nativos-session-runner";
volatile sig_atomic_t quit = 0;
void stopping(int) { quit = 1; }
bool authenticate(int fd, uid_t& uid) {
    ucred peer{};
    socklen_t len = sizeof(peer);
    if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &peer, &len) || len != sizeof(peer)) return false;
    char label[512]{};
    len = sizeof(label);
    if (getsockopt(fd, SOL_SOCKET, SO_PEERSEC, label, &len) || !len || len > sizeof(label)) return false;
    while (len && label[len - 1] == '\0') --len;
    if (!nativos::authorized(peer.uid, std::string_view(label, len))) return false;
    uid = peer.uid;
    return true;
}
std::string receive(int fd) {
    const auto until = std::chrono::steady_clock::now() + std::chrono::seconds(2);
    std::string request;
    while (request.size() < 64 && !quit) {
        auto remaining = std::chrono::duration_cast<std::chrono::milliseconds>(until - std::chrono::steady_clock::now()).count();
        if (remaining <= 0) return {};
        pollfd p{fd, POLLIN, 0};
        if (poll(&p, 1, static_cast<int>(remaining)) <= 0) return {};
        char byte;
        if (recv(fd, &byte, 1, 0) != 1) return {};
        request += byte;
        if (byte == '\n') return request;
    }
    return {};
}
bool validRunner() {
    struct stat st{};
    return lstat(runner, &st) == 0 && S_ISREG(st.st_mode) && st.st_uid == 0
        && !(st.st_mode & 0022) && (st.st_mode & 0100);
}
}

int main() {
    // Accept only the socket supplied by init. Never create an alternate socket.
    const char* value = getenv("ANDROID_SOCKET_nativos_runtime");
    if (!value) return 1;
    char* end = nullptr;
    long descriptor = strtol(value, &end, 10);
    if (!end || *end || descriptor < 3 || descriptor > 1048576) return 1;
    int server = static_cast<int>(descriptor);
    int type = 0;
    socklen_t size = sizeof(type);
    if (getsockopt(server, SOL_SOCKET, SO_TYPE, &type, &size) || type != SOCK_STREAM) return 1;
    if (fcntl(server, F_SETFD, FD_CLOEXEC) || listen(server, 8)) return 1;
    signal(SIGTERM, stopping);
    signal(SIGINT, stopping);
    signal(SIGPIPE, SIG_IGN);
    pid_t child = -1;
    uid_t sessionOwner = 0;
    bool terminating = false;
    bool failed = false;
    int failureCode = 0;
    StartupLog startupLog;
    auto deadline = std::chrono::steady_clock::now();
    while (!quit) {
        startupLog.drain();
        if (child > 0) {
            int status = 0;
            pid_t result = waitpid(child, &status, WNOHANG);
            if (result == child || (result < 0 && errno == ECHILD)) {
                failed = !terminating && (result < 0 || !WIFEXITED(status) || WEXITSTATUS(status) != 0);
                failureCode = !failed ? 0 : result < 0 ? 255
                    : WIFEXITED(status) ? WEXITSTATUS(status)
                    : WIFSIGNALED(status) ? 128 + WTERMSIG(status) : 254;
                child = -1;
                sessionOwner = 0;
                terminating = false;
            } else if (terminating && std::chrono::steady_clock::now() >= deadline) {
                kill(-child, SIGKILL);
            }
        }
        pollfd p{server, POLLIN, 0};
        if (poll(&p, 1, 250) <= 0) continue;
        int client = accept4(server, nullptr, nullptr, SOCK_CLOEXEC);
        if (client < 0) continue;
        std::string reply = "ERR UNAUTHORIZED\n";
        uid_t callerUid = 0;
        if (authenticate(client, callerUid)) {
            const std::string request = receive(client);
            const auto command = nativos::parse(request);
            nativos::DisplaySize dimensions;
            (void)nativos::displaySize(request, dimensions);
            // Do not let another authenticated UID stop or reuse this session.
            if (child > 0 && sessionOwner != callerUid && command != nativos::Command::Prepare) {
                reply = "ERR SESSION_OWNED\n";
            } else switch (command) {
            case nativos::Command::Prepare: {
                int baseFd = open("/data/misc/nativos", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
                bool prepared = baseFd >= 0 && nativos::prepareStorage(baseFd, callerUid);
                if (baseFd >= 0) close(baseFd);
                reply = prepared ? "OK PREPARED\n" : "ERR STORAGE_UNAVAILABLE\n";
                break;
            }
            case nativos::Command::Status:
                reply = terminating ? "OK STOPPING\n" : child > 0 ? "OK RUNNING\n"
                    : failed ? "ERR RUNNER_EXIT_" + std::to_string(failureCode) + "\n" : "OK STOPPED\n";
                break;
            case nativos::Command::Start:
                if (terminating) { reply = "ERR STOPPING\n"; break; }
                if (child > 0) { reply = "OK RUNNING\n"; break; }
                if (!validRunner()) { reply = "ERR RUNNER_UNAVAILABLE\n"; break; }
                {
                int logWriter = startupLog.prepare();
                if (logWriter < 0) { reply = "ERR STORAGE_UNAVAILABLE\n"; break; }
                child = fork();
                if (child == 0) {
                    if (dup2(logWriter, STDOUT_FILENO) < 0 || dup2(logWriter, STDERR_FILENO) < 0) _exit(124);
                    close(logWriter);
                    startupLog.closeLog();
                    close(server);
                    close(client);
                    if (setpgid(0, 0)) _exit(126);
                    const std::string uid = std::to_string(callerUid);
                    const std::string width = std::to_string(dimensions.width);
                    const std::string height = std::to_string(dimensions.height);
                    char* const argv[] = {const_cast<char*>(runner), const_cast<char*>(uid.c_str()),
                        const_cast<char*>(width.c_str()), const_cast<char*>(height.c_str()), nullptr};
                    char* const env[] = {const_cast<char*>("PATH=/system/bin"), nullptr};
                    execve(runner, argv, env);
                    perror("exec session runner");
                    _exit(127);
                }
                close(logWriter);
                }
                if (child > 0) { setpgid(child, child); sessionOwner = callerUid; }
                failed = child < 0;
                failureCode = failed ? 253 : 0;
                reply = failed ? "ERR SPAWN_FAILED\n" : "OK STARTING\n";
                break;
            case nativos::Command::Stop:
                if (child > 0 && !terminating) {
                    kill(-child, SIGTERM);
                    terminating = true;
                    deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
                }
                reply = child > 0 ? "OK STOPPING\n" : "OK STOPPED\n";
                break;
            default: reply = "ERR BAD_REQUEST\n";
            }
        }
        send(client, reply.data(), reply.size(), MSG_NOSIGNAL | MSG_DONTWAIT);
        close(client);
    }
    if (child > 0) { kill(-child, SIGKILL); waitpid(child, nullptr, 0); }
    close(server);
    return 0;
}
