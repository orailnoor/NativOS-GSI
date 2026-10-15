#!/usr/bin/env bash
set -euo pipefail
project="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
fixture="$(mktemp -d /tmp/nativos-config-test.XXXXXX)"
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/root/etc/apt/apt.conf.d" "$fixture/root/etc/apt/sources.list.d" \
  "$fixture/root/etc/ssl/certs" "$fixture/root/etc/ssl/private"
touch "$fixture/root/etc/bash.bashrc" "$fixture/root/etc/resolv.conf" \
  "$fixture/root/etc/apt/apt.conf.d/01autoremove" \
  "$fixture/root/etc/apt/sources.list.d/ubuntu.sources" \
  "$fixture/root/etc/ssl/certs/ca-certificates.crt" \
  "$fixture/root/etc/shadow" "$fixture/root/etc/apt/auth.conf" \
  "$fixture/root/etc/ssl/private/key.pem" "$fixture/outside-secret"
find "$fixture" -type f -exec chmod 0600 {} +
chmod 0700 "$fixture/root/etc" "$fixture/root/etc/apt" "$fixture/root/etc/ssl"
ln -s "$fixture/outside-secret" "$fixture/root/etc/ssl/certs/do-not-follow.pem"
bash "$project/gsi/normalize-linux-public-config.sh" "$fixture/root"
for directory in etc etc/apt etc/ssl; do
  test "$(stat -c %a "$fixture/root/$directory")" = 755
done
for file in etc/bash.bashrc etc/resolv.conf etc/apt/apt.conf.d/01autoremove \
  etc/apt/sources.list.d/ubuntu.sources etc/ssl/certs/ca-certificates.crt; do
  test "$(stat -c %a "$fixture/root/$file")" = 644
done
for file in root/etc/shadow root/etc/apt/auth.conf root/etc/ssl/private/key.pem outside-secret; do
  test "$(stat -c %a "$fixture/$file")" = 600
done
printf 'Public configs readable; secrets and symlink targets unchanged\n'
