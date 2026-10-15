#!/usr/bin/env bash
# Build-copy normalization only. Never recursively make all of /etc public.
set -euo pipefail
linux_root="${1:?supply temporary staged Linux root}"
[[ -d "$linux_root/etc" && ! -L "$linux_root" && ! -L "$linux_root/etc" ]] || exit 1
chmod a+rx "$linux_root/etc"
for relative in apt ssl; do
  parent="$linux_root/etc/$relative"
  [[ -d "$parent" && ! -L "$parent" ]] || continue
  chmod a+rx "$parent"
done
for relative in nsswitch.conf host.conf hosts hostname gai.conf protocols services \
    bash.bashrc profile environment locale.conf timezone resolv.conf \
    apt/sources.list apt/sources.list.d/ubuntu.sources; do
  config="$linux_root/etc/$relative"
  [[ -f "$config" && ! -L "$config" ]] || continue
  chmod 0644 "$config"
done
# These are shipped distribution configs/public certificates, not apt auth,
# private TLS keys, sudo credentials, account databases or user data.
for relative in apt/apt.conf.d apt/sources.list.d apt/trusted.gpg.d apt/keyrings \
    ssl/certs fonts; do
  config_dir="$linux_root/etc/$relative"
  [[ -d "$config_dir" && ! -L "$config_dir" ]] || continue
  find "$config_dir" -type d -exec chmod a+rx {} +
  find "$config_dir" -type f -exec chmod a+r {} +
done
