#!/usr/bin/env bash
set -euo pipefail
project="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
lab="${HOST_LAB:?Set HOST_LAB to the prepared disposable ARM64 build lab}"
source="$lab/guest/root/nativos-package-test/proot-v5.5.0"
[[ -f "$lab/host-tool-manifest.txt" && $(stat -c %u "$lab/guest") == 65534 ]]
run() { bash "$project/gsi/packages/run-host-lab.sh" "$lab" "$@"; }
# Only the disposable ARM64 build guest receives these authenticated packages.
# The host and the phone receive no package installs or maintainer scripts.
run /usr/bin/apt-get -o Dir::Etc::parts=/run/nativos-empty-apt-conf -o Dpkg::Use-Pty=0 --no-install-recommends -y install build-essential libtalloc-dev pkg-config
[[ ! -e "$source" && ! -L "$source" ]]
setpriv --reuid=65534 --regid=65534 --clear-groups --bounding-set=-all --no-new-privs \
    git clone --depth 1 --branch v5.5.0 --recurse-submodules https://github.com/proot-me/proot.git "$source"
revision="$(git -c safe.directory="$source" -C "$source" rev-parse HEAD)"
[[ "$revision" == 25dc6a3134891f98a79f57ce1c2c1b23ff15cad1 ]] || { printf 'Unexpected upstream release revision\n' >&2; exit 1; }
run /usr/bin/make -C /root/nativos-package-test/proot-v5.5.0/src -j2 WITHOUT_PYTHON=1
run /root/nativos-package-test/proot-v5.5.0/src/proot --version
printf 'Upstream source revision: %s\n' "$revision"
sha256sum "$source/src/proot"
