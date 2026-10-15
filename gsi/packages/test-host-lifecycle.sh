#!/usr/bin/env bash
set -euo pipefail
project="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
lab="${1:?prepared lab required}"
run() { timeout 300 bash "$project/gsi/packages/run-host-lab.sh" "$lab" "$@"; }
# The fake guest identity must not be mistaken for actual host privileges.
run /bin/sh -c 'id; grep -E "^(Uid|CapEff|CapBnd|NoNewPrivs):" /proc/self/status; dpkg --print-architecture'
run /usr/bin/python3 -c 'from pathlib import Path; s=dict(line.split(":",1) for line in Path("/proc/self/status").read_text().splitlines() if ":" in line); assert s["Uid"].split()==["65534"]*4; assert int(s["CapEff"],16)==int(s["CapBnd"],16)==0; assert s["NoNewPrivs"].strip()=="1"; print("Real unprivileged host identity verified")'
apt_options=(-o Dir::Etc::parts=/run/nativos-empty-apt-conf -o APT::Update::Error-Mode=any \
    -o Acquire::Retries=1 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 -o Dpkg::Use-Pty=0)
run /usr/bin/apt-get "${apt_options[@]}" update
run /usr/bin/apt-get "${apt_options[@]}" --no-install-recommends -y install hello
run /usr/bin/hello
run /usr/bin/apt-get "${apt_options[@]}" --no-install-recommends -y install --reinstall hello
run /bin/sh -c 'cd /root/nativos-package-test && apt-get download hello'
run /usr/bin/apt-get "${apt_options[@]}" -y remove hello
# The local .deb was obtained through authenticated APT, not an arbitrary site.
run /bin/sh -c 'set -- /root/nativos-package-test/hello_*_arm64.deb; test "$#" -eq 1 && apt-get -o Dir::Etc::parts=/run/nativos-empty-apt-conf -o Dpkg::Use-Pty=0 --no-install-recommends -y install "$1"'
run /usr/bin/hello
run /usr/bin/apt-get "${apt_options[@]}" -y purge hello
run /bin/sh -c 'test ! -e /usr/bin/hello && dpkg --audit'
printf 'ARM64 guest package lifecycle passed; host-only, no Android SELinux acceptance\n'
