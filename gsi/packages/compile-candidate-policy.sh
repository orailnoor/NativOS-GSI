#!/usr/bin/env bash
set -euo pipefail
project="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
combined="$(mktemp /tmp/nativos-package-policy.XXXXXXXX.cil)"
snapshot="$(mktemp -d /tmp/nativos-package-snapshot.XXXXXXXX)"
trap 'rm -f -- "$combined"; rm -rf -- "$snapshot"' EXIT
cp -a "$project/work/policy-snapshot/." "$snapshot/"
python3 "$project/gsi/packages/merge-package-policy.py" "$project/work/policy-snapshot/system/plat_sepolicy.cil" "$project/gsi/packages/packages.cil" "$snapshot/system/plat_sepolicy.cil"
cp "$project/gsi/nativos-runtime/nativos.cil" "$combined"
export EXTRA_CIL="$combined"
export SECILC="$project/work/aosp-selinux/secilc/secilc"
bash "$project/gsi/nativos-runtime/tests/compile-device-policy.sh" "$snapshot"
