#!/usr/bin/env bash
set -euo pipefail
directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
compiler="${CLANG:?Set CLANG to the reviewed LLVM compiler executable}"
"$compiler" --target=aarch64-linux-gnu -fPIC -shared -nostdlib -fuse-ld=lld \
  -Wall -Wextra -Werror -isystem /usr/include \
  -Wl,-soname,libnativos-guest-audit.so,-z,noexecstack,-z,relro,-z,now \
  "$directory/guest-audit-compat.c" -o "$directory/libnativos-guest-audit.so"
file "$directory/libnativos-guest-audit.so"
readelf -Ws "$directory/libnativos-guest-audit.so" | grep -E 'audit_open|errno_location'
sha256sum "$directory/libnativos-guest-audit.so"
