#include "../src/runtime_storage.h"
#include <cassert>
#include <cstdio>
#include <cstdlib>

int main(int argc, char** argv) {
    assert(argc == 2 && geteuid() == 0);
    int fd = open(argv[1], O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    assert(fd >= 0);
    assert(!nativos::prepareStorage(fd, 0));
    assert(!nativos::prepareStorage(fd, 2000));
    assert(nativos::prepareStorage(fd, 10001));
    assert(nativos::prepareStorage(fd, 10001));
    int homes = openat(fd, "homes", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    assert(homes >= 0);
    struct stat st{};
    assert(fstatat(homes, "10001", &st, AT_SYMLINK_NOFOLLOW) == 0);
    assert(st.st_uid == 10001 && (st.st_mode & 0777) == 0700);
    assert(symlinkat("/", homes, "10002") == 0);
    assert(!nativos::prepareStorage(fd, 10002));
    struct stat root{};
    assert(stat("/", &root) == 0 && root.st_uid == 0);
    close(homes);
    int packages = openat(fd, "packages", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    assert(packages >= 0);
    assert(fstatat(packages, "10001", &st, AT_SYMLINK_NOFOLLOW) == 0);
    assert(st.st_uid == 10001 && (st.st_mode & 0777) == 0700);
    assert(symlinkat("/", packages, "10003") == 0);
    assert(!nativos::prepareStorage(fd, 10003));
    close(packages);
    close(fd);
    std::puts("Storage tests passed: UID bounds, repeat preparation, ownership, symlink rejection");
}
