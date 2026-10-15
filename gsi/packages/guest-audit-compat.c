/* Guest users/group database tools must not use Android's kernel audit API.
 * Return the supported "audit unavailable" result, never fake a successful
 * audit write. This library grants no capabilities and performs no syscalls.
 * errno constants are Linux UAPI; __errno_location is the guest glibc API.
 */
#include <asm-generic/errno.h>
extern int *__errno_location(void);
int audit_open(void) {
    *__errno_location() = EPROTONOSUPPORT;
    return -1;
}
