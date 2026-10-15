#!/usr/bin/env bash
# Host-only feasibility lab. No Android device commands; no package scripts
# execute as WSL root. Keep the result for inspection, never auto-delete it.
set -euo pipefail
[[ $(id -u) == 0 ]] || { echo 'WSL root is needed only for staging and dropping to nobody' >&2; exit 1; }
source_tree="$(realpath -- "${1:?prepared ARM64 Ubuntu tree required}")"
[[ "$source_tree" == /var/tmp/nativos-linux-* && -f "$source_tree/.nativos-source-sha256" ]]
lab="$(mktemp -d /var/tmp/nativos-apt-lab.XXXXXXXX)"
[[ "$(realpath -- "$lab")" == /var/tmp/nativos-apt-lab.* && ! -L "$lab" ]]
chmod 0755 "$lab"
mkdir "$lab/downloads" "$lab/tools" "$lab/guest"
chown 65534:65534 "$lab/downloads"
chmod 0700 "$lab/downloads"
printf 'Host-only lab: %s\n' "$lab"
# Versions are selected from the host's previously authenticated APT index.
# Record and independently compare its SHA256 before extracting each package.
for package in proot libtalloc2 qemu-user; do
    version="$(apt-cache policy "$package" | awk '/Candidate:/ && !seen++ {print $2}')"
    [[ -n "$version" && "$version" != '(none)' ]]
    expected="$(apt-cache show "$package=$version" | awk '/^SHA256:/ && !seen++ {print $2}')"
    [[ "$expected" =~ ^[0-9a-f]{64}$ ]]
    (cd "$lab/downloads"; setpriv --reuid=65534 --regid=65534 --clear-groups --bounding-set=-all --no-new-privs \
        apt-get download "$package=$version")
    mapfile -t files < <(find "$lab/downloads" -maxdepth 1 -name "${package}_*.deb" -type f)
    [[ ${#files[@]} == 1 ]]
    actual="$(sha256sum -- "${files[0]}" | cut -d' ' -f1)"
    [[ "$actual" == "$expected" ]]
    printf '%s %s %s\n' "$package" "$version" "$actual" >> "$lab/host-tool-manifest.txt"
    # Extract only; dpkg-deb does not run maintainer scripts.
    dpkg-deb -x "${files[0]}" "$lab/tools"
done
[[ -x "$lab/tools/usr/bin/proot" && -x "$lab/tools/usr/bin/qemu-aarch64" ]]
cp -a --reflink=auto "$source_tree/." "$lab/guest/"
# All writable guest content belongs to the unprivileged host test identity.
# -h never follows symlinks outside the validated new lab directory.
chown -hR 65534:65534 "$lab/guest"
find "$lab/guest" -type d -exec chmod u+rwx {} +
find "$lab/guest" -type f -exec chmod u+rw,u-s,g-s {} +
install -o 65534 -g 65534 -m 0644 /etc/resolv.conf "$lab/guest/etc/resolv.conf"
install -d -o 65534 -g 65534 -m 0700 "$lab/guest/root" "$lab/guest/root/nativos-package-test"
install -d -o 65534 -g 65534 -m 0755 "$lab/guest/run/nativos-empty-apt-conf"
printf 'Prepared %s; guest APT has not yet run; no host packages installed\n' "$lab"
