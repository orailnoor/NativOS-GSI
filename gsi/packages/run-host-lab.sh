#!/usr/bin/env bash
# Native ARM64 guest binaries emulated on x86 WSL; NOT device acceptance.
# PROOT_NO_SECCOMP below controls a tracing accelerator, not app isolation.
set -euo pipefail
lab="$(realpath -- "${1:?lab directory required}")"
shift
[[ "$lab" == /var/tmp/nativos-apt-lab.* && ! -L "$lab" ]]
[[ -f "$lab/host-tool-manifest.txt" && -d "$lab/guest" ]]
[[ $(stat -c %u "$lab/guest") == 65534 ]]
[[ $# -gt 0 ]]
exec setpriv --reuid=65534 --regid=65534 --clear-groups --bounding-set=-all --no-new-privs \
    env -i PATH=/usr/bin:/bin HOME=/root LANG=C.UTF-8 \
    LD_LIBRARY_PATH="$lab/tools/usr/lib/x86_64-linux-gnu" \
    PROOT_TMP_DIR="$lab/downloads" \
    PROOT_NO_SECCOMP=1 \
    "$lab/tools/usr/bin/proot" -0 -r "$lab/guest" -w /root \
    -b /dev/null -b /dev/zero -b /dev/random -b /dev/urandom -b /proc \
    -q "$lab/tools/usr/bin/qemu-aarch64" "$@"
