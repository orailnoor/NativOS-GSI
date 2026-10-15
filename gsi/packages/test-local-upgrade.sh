#!/usr/bin/env bash
set -euo pipefail
project="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
lab="$(realpath -- "${1:?prepared lab required}")"
[[ "$lab" == /var/tmp/nativos-apt-lab.* && -f "$lab/host-tool-manifest.txt" ]]
[[ $(stat -c %u "$lab/guest") == 65534 ]]
destination="$lab/guest/root/nativos-package-test/local-upgrade-candidate2"
[[ ! -e "$destination" && ! -L "$destination" ]]
setpriv --reuid=65534 --regid=65534 --clear-groups --bounding-set=-all --no-new-privs \
    cp -a "$project/gsi/packages/fixtures" "$destination"
# Windows-backed source files have permissive synthetic modes; normalize only
# the new copied fixtures, never the immutable source or installed user apps.
find "$destination" -type d -exec chmod 0755 {} +
find "$destination" -type f -exec chmod 0644 {} +
for version in v1 v2; do
    setpriv --reuid=65534 --regid=65534 --clear-groups --bounding-set=-all --no-new-privs \
        chmod 0755 "$destination/$version/usr/bin/nativos-package-fixture"
done
run() { timeout 180 bash "$project/gsi/packages/run-host-lab.sh" "$lab" "$@"; }
for version in v1 v2; do
    run /usr/bin/dpkg-deb --build "/root/nativos-package-test/local-upgrade-candidate2/$version" "/root/nativos-package-test/fixture-$version.deb"
done
options=(-o Dir::Etc::parts=/run/nativos-empty-apt-conf -o Dpkg::Use-Pty=0 --no-install-recommends -y)
run /usr/bin/apt-get "${options[@]}" install /root/nativos-package-test/fixture-v1.deb
[[ "$(run /usr/bin/nativos-package-fixture)" == 'NativOS package fixture 1.0' ]]
run /usr/bin/apt-get "${options[@]}" install /root/nativos-package-test/fixture-v2.deb
[[ "$(run /usr/bin/nativos-package-fixture)" == 'NativOS package fixture 1.1' ]]
run /usr/bin/apt-get "${options[@]}" purge nativos-package-fixture hello
run /bin/sh -c 'test ! -e /usr/bin/nativos-package-fixture && test ! -e /usr/bin/hello && dpkg --audit'
printf 'Local .deb dependency resolution, actual version upgrade1.0->1.1 and removal passed (host only)\n'
