#!/usr/bin/env bash
set -euo pipefail
snapshot="$(realpath -- "${1:?supply policy snapshot directory}")"
version="$(tr -d '\r\n' < "$snapshot/vendor/plat_sepolicy_vers.txt")"
[[ "$version" =~ ^[0-9]+(\.[0-9]+)?$ ]] || exit 1
inputs=("$snapshot/system/plat_sepolicy.cil" "$snapshot/system/mapping/$version.cil")
for candidate in \
    "$snapshot/system/mapping/$version.compat.cil" \
    "$snapshot/system_ext/system_ext_sepolicy.cil" \
    "$snapshot/system_ext/mapping/$version.cil" \
    "$snapshot/product/product_sepolicy.cil" \
    "$snapshot/product/mapping/$version.cil" \
    "$snapshot/vendor/plat_pub_versioned.cil" \
    "$snapshot/vendor/vendor_sepolicy.cil"; do
    if [[ -f "$candidate" ]]; then inputs+=("$candidate"); fi
done
if [[ -n "${EXTRA_CIL:-}" ]]; then inputs+=("$EXTRA_CIL"); fi
flags=()
if [[ "${STRUCTURAL_ONLY:-0}" == 1 ]]; then
    # The unchanged base already fails cross-version neverallow checks. This
    # diagnostic mode checks CIL linking only; it is NOT a security pass.
    flags+=(-N)
fi
build_dir="$(mktemp -d /tmp/nativos-policy.XXXXXX)"
trap 'rm -rf -- "$build_dir"' EXIT
# Keep neverallow checking enabled. This is a device-specific compatibility
# check; the resulting combined policy must NOT be shipped as a universal GSI.
diagnostics="${POLICY_DIAGNOSTICS:-$build_dir/diagnostics.txt}"
if ! "${SECILC:-secilc}" -m -M true -G -c 30 "${flags[@]}" "${inputs[@]}" \
    -o "$build_dir/policy" -f "$build_dir/file_contexts" 2> "$diagnostics"; then
    head -n 24 "$diagnostics"
    printf 'Baseline policy check FAILED; neverallow failures: %s\n' "$(grep -c '^neverallow check failed' "$diagnostics" || true)"
    if [[ -n "${POLICY_DIAGNOSTICS:-}" ]]; then printf 'Diagnostics saved: %s\n' "$diagnostics"; fi
    exit 1
fi
if [[ -n "${POLICY_BINARY:-}" ]]; then
    [[ ! -e "$POLICY_BINARY" ]] || { printf 'Refusing to overwrite policy analysis binary\n' >&2; exit 1; }
    cp "$build_dir/policy" "$POLICY_BINARY"
fi
printf 'Combined policy compiled: vendor API %s; structural-only=%s\n' "$version" "${STRUCTURAL_ONLY:-0}"
