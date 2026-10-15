#!/usr/bin/env bash
# Extract authenticated host tools only: no host installation/maintainer scripts.
set -euo pipefail
directory="$(mktemp -d /var/tmp/nativos-policy-tools.XXXXXXXX)"
chmod 0755 "$directory"
install -d -o 65534 -g 65534 -m 0700 "$directory/downloads"
mkdir "$directory/tools"
for package in python3-setools python3-networkx python3-setuptools; do
  version="$(apt-cache policy "$package" | awk '/Candidate:/ && !seen++ {print $2}')"
  expected="$(apt-cache show "$package=$version" | awk '/^SHA256:/ && !seen++ {print $2}')"
  [[ "$expected" =~ ^[0-9a-f]{64}$ ]]
  (cd "$directory/downloads"; setpriv --reuid=65534 --regid=65534 --clear-groups --bounding-set=-all --no-new-privs apt-get download "$package=$version")
  mapfile -t files < <(find "$directory/downloads" -maxdepth 1 -name "${package}_*.deb" -type f)
  [[ ${#files[@]} == 1 && "$(sha256sum "${files[0]}" | cut -d' ' -f1)" == "$expected" ]]
  dpkg-deb -x "${files[0]}" "$directory/tools"
  printf '%s %s %s\n' "$package" "$version" "$expected" >> "$directory/manifest.txt"
done
printf 'POLICY_TOOLS=%s\n' "$directory/tools/usr/lib/python3/dist-packages"
