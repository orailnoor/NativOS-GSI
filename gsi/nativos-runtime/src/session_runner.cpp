#include "session_supervisor.h"
#include "drop_privileges.h"
#include "protocol.h"
#include <cstdio>
#include <cstdlib>
#include <fcntl.h>
#include <string>
#include <sys/mount.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <unistd.h>

namespace {
#ifdef NATIVOS_SESSION_PROBE
// Diagnostic build only; production has no caller-selectable paths.
constexpr const char* runtimeRoot = "/data/local/tmp/nativos-session-20261004";
constexpr const char* base = "/data/local/tmp/nativos-session-20261004/v16/system/etc/nativos/linux";
constexpr const char* target = "/data/local/tmp/nativos-session-20261004/session";
constexpr const char* display = "/data/local/tmp/nativos-session-20261004/display";
#else
constexpr const char* runtimeRoot = "/data/misc/nativos";
constexpr const char* base = "/system/etc/nativos/linux";
constexpr const char* target = "/data/misc/nativos/session";
constexpr const char* display = "/data/misc/nativos/display";
#endif
uid_t desktopUid;
nativos::DisplaySize desktopSize;
int failure(int code, const char* operation) { perror(operation); return code; }
bool trustedDirectory(const char* path) {
    int fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return false;
    struct stat st{};
    bool valid = fstat(fd, &st) == 0 && st.st_uid == 0 && !(st.st_mode & 0022);
    close(fd);
    return valid;
}
bool temporary(const char* suffix, const char* options) {
    std::string path = std::string(target) + suffix;
    int fd = open(path.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return false;
    close(fd);
    // Keep private namespace files on the kernel's native tmpfs label. Some
    // Android vendor kernels reject an explicit SELinux context= mount option
    // even though ordinary tmpfs mounts are supported. SELinux confines this
    // label to nativos_session in policy.
    return mount("tmpfs", path.c_str(), "tmpfs", MS_NOSUID | MS_NODEV, options) == 0;
}
bool writeFile(const char* path, const std::string& data) {
    int fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0644);
    if (fd < 0) return false;
    size_t offset = 0;
    while (offset < data.size()) {
        ssize_t amount = write(fd, data.data() + offset, data.size() - offset);
        if (amount < 0 && errno == EINTR) continue;
        if (amount <= 0) { close(fd); return false; }
        offset += static_cast<size_t>(amount);
    }
    return close(fd) == 0;
}
int desktop() {
    // Android init may pass a restrictive umask. Root-created traversal
    // directories and the temporary passwd/group must remain readable after
    // switching to the desktop UID. Explicit 0700 modes remain private.
    umask(0022);
    if (!trustedDirectory(base) || !trustedDirectory(runtimeRoot)
        || !trustedDirectory(target) || !trustedDirectory(display)) return failure(21, "runtime directories");
    if (mount(base, target, nullptr, MS_BIND, nullptr)
        || mount(nullptr, target, nullptr, MS_BIND | MS_REMOUNT | MS_RDONLY | MS_NOSUID | MS_NODEV, nullptr))
        return failure(22, "readonly rootfs");
    if (!temporary("/run", "mode=0755,size=32m")) return failure(23, "run tmpfs");
    if (!temporary("/tmp", "mode=1777,size=256m")) return failure(38, "tmp tmpfs");
    if (!temporary("/home", "mode=0755,size=256m")) return failure(39, "home tmpfs");
    // Display socket is made in this fixed service-owned directory. Only its
    // dedicated socket subdirectory is writable by the authenticated launcher.
    std::string socketSource = std::string(display) + "/" + std::to_string(desktopUid) + "/.X11-unix";
#ifdef NATIVOS_SESSION_PROBE
    socketSource = "/data/user/0/com.nativOS/files/tmp/.X11-unix";
#endif
    std::string socketTarget = std::string(target) + "/tmp/.X11-unix";
    struct stat socketDir{};
    int socketFd = open(socketSource.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (socketFd < 0 || fstat(socketFd, &socketDir) || !S_ISDIR(socketDir.st_mode)
        || socketDir.st_uid != desktopUid) return failure(24, "display directory");
    // Bind the checked inode, not an app-writable pathname that could be swapped.
    std::string socketDescriptor = "/proc/self/fd/" + std::to_string(socketFd);
    if (mkdir(socketTarget.c_str(), 0755)
        || mount(socketDescriptor.c_str(), socketTarget.c_str(), nullptr, MS_BIND, nullptr)) return failure(25, "display mount");
    close(socketFd);
    std::string proc = std::string(target) + "/proc";
    if (!trustedDirectory(proc.c_str())
        || mount("proc", proc.c_str(), "proc", MS_NOSUID | MS_NODEV | MS_NOEXEC, nullptr)) return failure(26, "private proc");
    // Do not expose Android's /dev tree or block devices.
    std::string dev = std::string(target) + "/dev";
    if (!trustedDirectory(dev.c_str())
        || mount("tmpfs", dev.c_str(), "tmpfs", MS_NOSUID | MS_NOEXEC,
                 "mode=0755,size=4m")) return failure(27, "private dev");
    struct Device { const char* name; unsigned minor; };
    for (const Device node : {Device{"null", 3}, Device{"zero", 5}, Device{"random", 8}, Device{"urandom", 9}}) {
        std::string path = dev + "/" + node.name;
        if (mknod(path.c_str(), S_IFCHR | 0666, makedev(1, node.minor)) || chmod(path.c_str(), 0666)) return failure(28, "device node");
    }
    std::string shm = dev + "/shm";
    if (mkdir(shm.c_str(), 01777) || chmod(shm.c_str(), 01777)
        || mount("tmpfs", shm.c_str(), "tmpfs", MS_NOSUID | MS_NODEV | MS_NOEXEC,
                 "mode=1777,size=256m")) return failure(40, "shared memory");
    std::string pts = dev + "/pts";
    if (mkdir(pts.c_str(), 0755)
        || mount("devpts", pts.c_str(), "devpts", MS_NOSUID | MS_NOEXEC, "newinstance,ptmxmode=0666,mode=0620")
        || symlink("pts/ptmx", (dev + "/ptmx").c_str())
        || symlink("/proc/self/fd", (dev + "/fd").c_str())) return failure(29, "pty setup");
    std::string homeSource = std::string(runtimeRoot) + "/homes/" + std::to_string(desktopUid);
    int homeFd = open(homeSource.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    struct stat homeStat{};
    if (homeFd < 0 || fstat(homeFd, &homeStat) || homeStat.st_uid != desktopUid)
        return failure(30, "persistent home");
    int packageFd = -1;
    const bool packagesEnabled = access((std::string(base) + "/usr/local/libexec/nativos-proot").c_str(), X_OK) == 0;
    if (packagesEnabled) {
        std::string packageSource = std::string(runtimeRoot) + "/packages/" + std::to_string(desktopUid);
        packageFd = open(packageSource.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        struct stat packageStat{};
        if (packageFd < 0 || fstat(packageFd, &packageStat) || packageStat.st_uid != desktopUid
            || (packageStat.st_mode & 0077)) return failure(42, "persistent packages");
    }
    if (chdir(target) || chroot(".") || chdir("/")) return failure(31, "chroot");
    std::string uid = std::to_string(desktopUid);
    if (mkdir("/home/nativos", 0700)
        || mount(("/proc/self/fd/" + std::to_string(homeFd)).c_str(), "/home/nativos", nullptr, MS_BIND, nullptr))
        return failure(32, "persistent home mount");
    close(homeFd);
    if (packagesEnabled) {
        if (mount(("/proc/self/fd/" + std::to_string(packageFd)).c_str(), "/var/lib/nativos-packages", nullptr, MS_BIND, nullptr)
            || mount(nullptr, "/var/lib/nativos-packages", nullptr, MS_BIND | MS_REMOUNT | MS_NOSUID | MS_NODEV, nullptr))
            return failure(43, "package storage mount");
        close(packageFd);
    }
    if (mkdir("/run/user", 0755) || mkdir(("/run/user/" + uid).c_str(), 0700)
        || chown(("/run/user/" + uid).c_str(), desktopUid, desktopUid)) return failure(33, "desktop directories");
    // Private identity files exist only in the session's tmpfs. No host account
    // databases are changed and no scripts from Linux run with host root.
    if (!writeFile("/run/passwd", "root:x:0:0:root:/root:/bin/sh\nnativos:x:" + uid + ":" + uid + ":NativOS:/home/nativos:/bin/bash\n")
        || !writeFile("/run/group", "root:x:0:\nnativos:x:" + uid + ":\n")
        || mount("/run/passwd", "/etc/passwd", nullptr, MS_BIND, nullptr)
        || mount("/run/group", "/etc/group", nullptr, MS_BIND, nullptr)) return failure(34, "session identity");
    // Fixed output/config path, with bounded numeric dimensions only. No
    // caller-supplied shell command or rootfs path enters this configuration.
    const std::string configuration = "[core]\nxwayland=false\n\n[output:X11-1]\nmode="
        + std::to_string(desktopSize.width) + "x" + std::to_string(desktopSize.height)
        + "\nscale=2\n";
    if (!writeFile("/run/phoc.ini", configuration)) return failure(41, "display configuration");
    struct rlimit files{};
    if (getrlimit(RLIMIT_NOFILE, &files)) return failure(35, "descriptor limit");
    for (rlim_t fd = 3; fd < files.rlim_cur; ++fd) close(static_cast<int>(fd));
    umask(0077); // Desktop-created personal files default to private.
    if (!nativos::dropPrivileges(desktopUid, desktopUid)) return failure(36, "drop privileges");
    clearenv();
    setenv("PATH", "/usr/local/bin:/usr/bin:/bin", 1);
    setenv("HOME", "/home/nativos", 1);
    setenv("USER", "nativos", 1);
    setenv("LOGNAME", "nativos", 1);
    setenv("LANG", "C.UTF-8", 1);
    setenv("XDG_RUNTIME_DIR", ("/run/user/" + uid).c_str(), 1);
    setenv("XDG_SESSION_TYPE", "wayland", 1);
    setenv("XDG_CURRENT_DESKTOP", "Phosh", 1);
    setenv("DISPLAY", ":0", 1);
    setenv("WLR_BACKENDS", "x11", 1);
    setenv("WLR_X11_OUTPUTS", "1", 1);
    setenv("WLR_RENDERER", "pixman", 1);
    setenv("LIBGL_ALWAYS_SOFTWARE", "1", 1);
    setenv("GSK_RENDERER", "cairo", 1);
    // Embedded X11 offers software rendering without a host DRM device.
    // Prevent wlroots from requesting a DRI3 DRM fd, and tolerate older
    // vendor kernels without glibc's close_range syscall.
    setenv("LD_PRELOAD", "/usr/local/lib/libnativos-close-range.so:/usr/local/lib/libnodri3.so", 1);
    execl("/usr/bin/dbus-run-session", "dbus-run-session", "--", "/usr/bin/phoc",
          "-C", "/run/phoc.ini", "-E", "/usr/libexec/phosh -U", static_cast<char*>(nullptr));
    return failure(37, "Phosh exec");
}
}
int main(int argc, char** argv) {
    if (geteuid() != 0 || (argc != 2 && argc != 4)) return 125;
    if (argc == 4 && !nativos::displaySize(std::string("NATIVOS/1 START ")
            + argv[2] + " " + argv[3] + "\n", desktopSize)) return 125;
    char* end = nullptr;
    unsigned long uid = strtoul(argv[1], &end, 10);
    if (!end || *end || uid < 10000 || uid > 19999) return 125;
    desktopUid = static_cast<uid_t>(uid);
    return nativos::superviseSession(desktop);
}
