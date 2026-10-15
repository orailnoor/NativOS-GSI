#!/usr/bin/env bash
set -euo pipefail
project="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
source="${HOST_LAB:?Set HOST_LAB}/guest/root/nativos-package-test/proot-v5.5.0"
revision="$(git -c safe.directory="$source" -C "$source" rev-parse HEAD)"
[[ "$revision" == 25dc6a3134891f98a79f57ce1c2c1b23ff15cad1 ]]
[[ "$(git -c safe.directory="$source/lib/uthash" -C "$source/lib/uthash" rev-parse HEAD)" == e493aa90a2833b4655927598f169c31cfcdf7861 ]]
[[ -f "$source/src/proot" && ! -L "$source/src/proot" ]]
candidate="$(mktemp -d /var/tmp/nativos-linux-packages.XXXXXXXX)"
cp -a --reflink=auto "${PREPARED_ROOTFS:?Set PREPARED_ROOTFS}/." "$candidate/"
install -m 0755 "$source/src/proot" "$candidate/usr/local/libexec/nativos-proot"
install -m 0755 "$project/gsi/packages/nativos-packages.py" "$candidate/usr/local/bin/nativos-packages"
digest="$(sha256sum "$candidate/usr/local/libexec/nativos-proot" | cut -d' ' -f1)"
printf '{"revision":"%s","proot_sha256":"%s","version":"5.5.0","build":"ARM64 Noble guest on PC, no phone builds","production_ready":false}\n' "$revision" "$digest" \
    > "$candidate/usr/local/share/nativos-packages/worker-manifest.json"
install -m 0644 "$source/COPYING" "$candidate/usr/local/share/nativos-packages/proot-COPYING"
printf 'CANDIDATE_ROOTFS=%s\n' "$candidate"
cat "$candidate/usr/local/share/nativos-packages/worker-manifest.json"
