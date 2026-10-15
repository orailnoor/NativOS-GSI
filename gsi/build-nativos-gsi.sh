#!/usr/bin/env bash
set -Eeuo pipefail

# Build a modified ext4 GSI without overwriting an existing AVB footer.
# Run inside WSL2 as:
#   sudo -v
#   TARGET_PARTITION_SIZE_BYTES=5368709120 bash build-nativos-gsi.sh
#
# TARGET_PARTITION_SIZE_BYTES must exactly match the logical system partition
# size you will create/use in fastbootd. It must be a multiple of 4096.

BASE_IMG="${BASE_IMG:?Set BASE_IMG to the verified base GSI}"
APK="${APK:?Set APK to the signed launcher APK}"
ROOTFS="${ROOTFS:?Set ROOTFS to the verified source rootfs archive}"
OUT_DIR="${OUT_DIR:?Set OUT_DIR to a new build output directory}"
OUT_IMG="${OUT_IMG:-$OUT_DIR/NativOS-linux-first-arm64-ab.img}"
TARGET_PARTITION_SIZE_BYTES="${TARGET_PARTITION_SIZE_BYTES:-}"

# The path is relative to Android's /system. Change this only if NativOS.apk
# expects the tarball somewhere else.
ROOTFS_REL="${ROOTFS_REL:-etc/nativos/rootfs/nativos-rootfs-arm64.tgz}"
ROOTFS_TREE="${ROOTFS_TREE:-}"
SKIP_LEGACY_ROOTFS_ARCHIVE="${SKIP_LEGACY_ROOTFS_ARCHIVE:-0}"
RUNTIME_DIR="${RUNTIME_DIR:-}"
APKSIGNER="${APKSIGNER:-apksigner}"

# Optional inputs. If PRIV_XML is unset, a conservative allowlist is generated
# from the APK's requested android.permission.* permissions. If INIT_RC is
# unset, the rc file below is generated.
PRIV_XML="${PRIV_XML:-}"
INIT_RC="${INIT_RC:-}"
SKIP_ANDROID_ONBOARDING="${SKIP_ANDROID_ONBOARDING:-1}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
[[ "$SKIP_ANDROID_ONBOARDING" == 0 || "$SKIP_ANDROID_ONBOARDING" == 1 ]] || { printf 'Invalid SKIP_ANDROID_ONBOARDING\n' >&2; exit 1; }

# Signing modes:
#   AVB_KEY unset: make a correct but unsigned (algorithm NONE) footer. The
#                  phone's vbmeta verification MUST be disabled when flashing.
#   AVB_KEY set:   sign with this PEM key. The script refuses it unless its
#                  public key verifies the original base image.
AVB_KEY="${AVB_KEY:-}"

# FEC is error correction, not authentication. Set GENERATE_FEC=1 only when an
# AOSP-compatible host 'fec' binary is in PATH. The hashtree remains present
# and cryptographically checksummed when FEC is disabled.
GENERATE_FEC="${GENERATE_FEC:-0}"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }
if [[ -n "$ROOTFS_TREE" && -e "$ROOTFS_TREE/usr/local/libexec/nativos-proot" ]]; then
  python3 "$SCRIPT_DIR/packages/validate-build-preflight.py" || die 'Package integration is not accepted: compiled policy preflight missing or stale'
  python3 "$SCRIPT_DIR/packages/tests.py" || die 'Package source boundary guards failed'
fi
repair_fs() {
  local status=0
  e2fsck "$@" || status=$?
  (( status <= 1 )) || die "e2fsck failed with status $status"
}

[[ -n "$TARGET_PARTITION_SIZE_BYTES" ]] || die "set TARGET_PARTITION_SIZE_BYTES to the exact target logical system partition size"
[[ "$TARGET_PARTITION_SIZE_BYTES" =~ ^[0-9]+$ ]] || die "TARGET_PARTITION_SIZE_BYTES must be decimal bytes"
(( TARGET_PARTITION_SIZE_BYTES % 4096 == 0 )) || die "TARGET_PARTITION_SIZE_BYTES must be 4096-byte aligned"
[[ -f "$BASE_IMG" ]] || die "base image not found: $BASE_IMG"
[[ -f "$APK" ]] || die "APK not found: $APK"
[[ -f "$ROOTFS" ]] || die "rootfs not found: $ROOTFS"
[[ "$SKIP_LEGACY_ROOTFS_ARCHIVE" == 0 || "$SKIP_LEGACY_ROOTFS_ARCHIVE" == 1 ]] || die 'invalid legacy archive switch'
if [[ "$SKIP_LEGACY_ROOTFS_ARCHIVE" == 1 ]]; then
  [[ -n "$ROOTFS_TREE" && -n "$RUNTIME_DIR" ]] || die 'archive omission requires the integrated runtime and prepared tree'
fi

for c in avbtool simg2img img2simg e2fsck resize2fs tune2fs blkid mount umount setfattr getfattr aapt sha256sum tar; do
  need "$c"
done
if [[ "$GENERATE_FEC" == 1 ]]; then need fec; fi

mkdir -p "$OUT_DIR"
TMP="$(mktemp -d "${BUILD_TMP_DIR:-/var/tmp}/nativos-gsi.XXXXXX")"
RAW="$TMP/system.img"
MNT="$TMP/mnt"
INFO="$OUT_DIR/base-avb-info.txt"
REPORT="$OUT_DIR/NativOS-build-report.txt"
mkdir -p "$MNT"

mounted=0
source_mounted=0
cleanup() {
  if (( mounted )); then
    if ! sudo umount "$MNT"; then
      printf 'Unmount failed; preserving build directory %s\n' "$TMP" >&2
      return
    fi
  fi
  if (( source_mounted )); then
    if ! sudo umount "$TMP/source-mount"; then
      printf 'Source unmount failed; preserving %s\n' "$TMP" >&2
      return
    fi
  fi
  rm -rf -- "$TMP"
}
trap cleanup EXIT INT TERM

printf '[1/9] Detecting image format and converting to raw ext4...\n'
magic="$(od -An -tx4 -N4 "$BASE_IMG" | tr -d '[:space:]')"
if [[ "$magic" == ed26ff3a ]]; then
  simg2img "$BASE_IMG" "$RAW"
else
  cp --reflink=auto --sparse=always "$BASE_IMG" "$RAW"
fi

[[ "$(blkid -p -s TYPE -o value "$RAW" || true)" == ext4 ]] || die "decoded base is not a plain ext4 filesystem image"
avbtool info_image --image "$RAW" | tee "$INFO" >/dev/null || die "base image has no readable AVB footer"
avbtool verify_image --image "$RAW" >/dev/null || die "base AVB signature/hashtree does not verify before modification"

partition_name="$(awk -F': *' '/Partition Name:/{print $2; exit}' "$INFO")"
hash_algorithm="$(awk -F': *' '/Hash Algorithm:/{print $2; exit}' "$INFO")"
data_block_size="$(awk -F': *' '/Data Block Size:/{print $2; exit}' "$INFO")"
fec_roots="$(awk -F': *' '/FEC num roots:/{print $2; exit}' "$INFO")"
avb_algorithm="$(awk -F': *' '/^[[:space:]]*Algorithm:/{print $2; exit}' "$INFO")"
rollback_index="$(awk -F': *' '/^[[:space:]]*Rollback Index:/{print $2; exit}' "$INFO")"
vbmeta_flags="$(awk -F': *' '/^[[:space:]]*Flags:/{print $2; exit}' "$INFO")"
hashtree_flags="$(awk -F': *' '/Hashtree descriptor:/{inside=1; next} inside && /Flags:/{print $2; exit}' "$INFO")"
salt="$(awk -F': *' '/Salt:/{print $2; exit}' "$INFO")"

[[ -n "$partition_name" ]] || partition_name=system
[[ -n "$hash_algorithm" ]] || hash_algorithm=sha256
[[ "$data_block_size" =~ ^[0-9]+$ ]] || data_block_size=4096
[[ "$rollback_index" =~ ^[0-9]+$ ]] || rollback_index=0
[[ "$vbmeta_flags" =~ ^[0-9]+$ ]] || vbmeta_flags=0
[[ "$hashtree_flags" =~ ^[0-9]+$ ]] || hashtree_flags=0

sign_args=(--algorithm NONE --rollback_index "$rollback_index" --flags "$vbmeta_flags")
verify_key_args=()
if [[ -n "$AVB_KEY" ]]; then
  [[ -f "$AVB_KEY" ]] || die "AVB_KEY not found: $AVB_KEY"
  [[ "$avb_algorithm" != NONE && -n "$avb_algorithm" ]] || die "cannot infer a signed algorithm from the base footer"
  avbtool extract_public_key --key "$AVB_KEY" --output "$TMP/candidate.avbpubkey"
  avbtool verify_image --image "$RAW" --key "$AVB_KEY" >/dev/null || \
    die "AVB_KEY does not match the public key in the original image"
  sign_args=(--algorithm "$avb_algorithm" --key "$AVB_KEY" --rollback_index "$rollback_index" --flags "$vbmeta_flags")
  verify_key_args=(--key "$AVB_KEY")
fi

fec_args=(--do_not_generate_fec)
if [[ "$GENERATE_FEC" == 1 ]]; then
  fec_args=()
  if [[ "$fec_roots" =~ ^[0-9]+$ ]] && (( fec_roots > 0 )); then
    fec_args+=(--fec_num_roots "$fec_roots")
  fi
fi

common_avb_args=(
  --partition_name "$partition_name"
  --partition_size "$TARGET_PARTITION_SIZE_BYTES"
  --hash_algorithm "$hash_algorithm"
  --block_size "$data_block_size"
)
[[ -n "$salt" ]] && common_avb_args+=(--salt "$salt")
(( hashtree_flags & 1 )) && common_avb_args+=(--do_not_use_ab)

# Preserve property descriptors (for example the system security-patch level)
# while deliberately replacing the stale hashtree descriptor.
while IFS= read -r avb_prop; do
  [[ -n "$avb_prop" ]] && common_avb_args+=(--prop "$avb_prop")
done < <(sed -n "s/^[[:space:]]*Prop: \([^ ]*\) -> '\(.*\)'$/\1:\2/p" "$INFO")

printf '[2/9] Removing old hashtree/FEC/vbmeta/footer with avbtool...\n'
avbtool erase_footer --image "$RAW"

max_fs_bytes="$(avbtool add_hashtree_footer "${common_avb_args[@]}" "${sign_args[@]}" "${fec_args[@]}" --calc_max_image_size)"
[[ "$max_fs_bytes" =~ ^[0-9]+$ ]] || die "avbtool did not return a usable maximum filesystem size"

fs_block_size="$(tune2fs -l "$RAW" 2>/dev/null | awk -F': *' '/Block size:/{print $2; exit}')"
[[ "$fs_block_size" =~ ^[0-9]+$ ]] || die "could not read ext4 block size"
max_fs_blocks=$(( max_fs_bytes / fs_block_size ))
current_fs_bytes=$(( $(tune2fs -l "$RAW" 2>/dev/null | awk -F': *' '/Block count:/{print $2; exit}') * fs_block_size ))
(( max_fs_bytes > current_fs_bytes )) || die "target partition leaves no room to grow the filesystem"

printf '[3/9] Growing ext4 inside the AVB data-area budget...\n'
repair_fs -fy "$RAW"
if [[ -n "$ROOTFS_TREE" ]]; then
  # Android's base filesystem has too few inodes for a complete Linux tree.
  # Recreate only the temporary image, retaining UUID, feature set and metadata.
  fs_uuid="$(tune2fs -l "$RAW" | awk -F': *' '/Filesystem UUID:/{print $2}')"
  fs_features="$(tune2fs -l "$RAW" | awk -F': *' '/Filesystem features:/{print $2}' | tr ' ' ',')"
  fs_features="${fs_features//shared_blocks,/}"
  mv -- "$RAW" "$TMP/source.img"
  mkdir "$TMP/source-mount"
  sudo mount -o loop,ro "$TMP/source.img" "$TMP/source-mount"
  source_mounted=1
  mke2fs -q -F -t ext4 -b 4096 -I 256 -N 131072 -m 0 -L / -U "$fs_uuid" \
    -O "none,$fs_features" -E lazy_itable_init=0,nodiscard "$RAW" "$max_fs_blocks"
  sudo mount -o loop,rw "$RAW" "$MNT"
  mounted=1
  # Do not use cp/reflink/copy_file_range between two loop-mounted ext4 images.
  # Some WSL kernels have produced invalid cross-loop extents through that path.
  # A tar stream performs ordinary reads/writes while preserving Android labels,
  # capabilities, ACLs, hard links and other xattrs.
  sudo tar -C "$TMP/source-mount" --xattrs --xattrs-include='*' --acls --selinux -cpf - . \
    | sudo tar -C "$MNT" --xattrs --xattrs-include='*' --acls --selinux -xpf -
  sudo umount "$TMP/source-mount"
  source_mounted=0
  sudo umount "$MNT"
  mounted=0
  # Never let e2fsck repair a damaged recreation and silently remove Android
  # files. Abort this build unless the newly copied filesystem is already clean.
  repair_fs -fn "$RAW"
else
resize2fs "$RAW" "$max_fs_blocks"
fi
# Android images may use RO_COMPAT_SHARED_BLOCKS. Remove sharing before RW mount.
repair_fs -fy -E unshare_blocks "$RAW"

printf '[4/9] Mounting and injecting files...\n'
sudo mount -o loop,rw "$RAW" "$MNT"
mounted=1
if [[ -d "$MNT/system/etc" ]]; then SYSROOT="$MNT/system"; else SYSROOT="$MNT"; fi

if [[ "$SKIP_ANDROID_ONBOARDING" == 1 ]]; then
  [[ -f "$SCRIPT_DIR/nativos-firstboot.sh" ]] || die 'missing nativos-firstboot.sh'
  # Only alter the temporary build copy. Match package identities, never broad
  # directory names; retain ManagedProvisioning, SystemUI and both launchers.
  mkdir -p "$TMP/disabled-onboarding"
  removed=0
  while IFS= read -r -d '' candidate; do
    candidate_pkg="$(aapt dump badging "$candidate" 2>/dev/null | sed -n "s/^package: name='\([^']*\)'.*/\1/p" | head -n1 || true)"
    if [[ "$candidate_pkg" == org.lineageos.setupwizard ]]; then
      sudo mv -- "$candidate" "$TMP/disabled-onboarding/setupwizard-$removed.apk"
      removed=$((removed + 1))
    fi
  done < <(find "$SYSROOT" -type f -name '*.apk' -print0)
  (( removed > 0 )) || die 'expected Lineage SetupWizard not found; refusing unverified onboarding modification'
  sudo install -m 0644 "$SCRIPT_DIR/nativos-firstboot.sh" "$SYSROOT/etc/nativos-firstboot.sh"
  printf '%s\n' 'on property:sys.boot_completed=1' \
    '    exec_background u:r:shell:s0 shell shell -- /system/bin/sh /system/etc/nativos-firstboot.sh' \
    > "$TMP/nativos-firstboot.rc"
  sudo install -m 0644 "$TMP/nativos-firstboot.rc" "$SYSROOT/etc/init/nativos-firstboot.rc"
  for firstboot_file in "$SYSROOT/etc/nativos-firstboot.sh" "$SYSROOT/etc/init/nativos-firstboot.rc"; do
    sudo setfattr -n security.selinux -v 'u:object_r:system_file:s0' "$firstboot_file"
  done
  printf 'Omitted %s Lineage onboarding APK(s) from build copy; original base untouched.\n' "$removed"
fi

pkg="$(aapt dump badging "$APK" | sed -n "s/^package: name='\([^']*\)'.*/\1/p" | head -n1)"
[[ -n "$pkg" ]] || die "could not read APK package name with aapt"

sudo install -d -m 0755 "$SYSROOT/priv-app/NativOS"
sudo install -m 0644 "$APK" "$SYSROOT/priv-app/NativOS/NativOS.apk"
command -v unzip >/dev/null || die 'unzip is required for system APK native libraries'
mkdir "$TMP/apk-native"
unzip -j -q "$APK" 'lib/arm64-v8a/*.so' -d "$TMP/apk-native"
sudo install -d -m 0755 "$SYSROOT/priv-app/NativOS/lib/arm64"
sudo install -m 0755 "$TMP/apk-native/"*.so "$SYSROOT/priv-app/NativOS/lib/arm64/"
for native in libproot.so libproot-loader.so libXlorie.so libtalloc.so; do
  [[ -s "$SYSROOT/priv-app/NativOS/lib/arm64/$native" ]] || die "missing native executable: $native"
done
sudo install -d -m 0755 "$(dirname "$SYSROOT/$ROOTFS_REL")"
if [[ "$SKIP_LEGACY_ROOTFS_ARCHIVE" == 0 ]]; then
  sudo install -m 0644 "$ROOTFS" "$SYSROOT/$ROOTFS_REL"
fi
if [[ -n "$ROOTFS_TREE" ]]; then
  [[ -d "$ROOTFS_TREE" && ! -L "$ROOTFS_TREE" ]] || die 'invalid prepared rootfs tree'
  expected_rootfs="$(sha256sum "$ROOTFS" | awk '{print $1}')"
  [[ "$(cat "$ROOTFS_TREE/.nativos-source-sha256")" == "$expected_rootfs" ]] || die 'prepared rootfs archive digest mismatch'
  [[ ! -e "$SYSROOT/etc/nativos/linux" ]] || die 'refusing to merge with an existing Linux tree'
  sudo cp -a -- "$ROOTFS_TREE" "$SYSROOT/etc/nativos/linux"
  # New users see every app, not an adaptive/mobile-only subset. Compile the
  # override into the build copy only; preserve the supplied rootfs tree.
  drawer_override="$SCRIPT_DIR/packages/99-nativos-app-drawer.gschema.override"
  [[ -f "$drawer_override" ]] || die 'Missing all-apps drawer default'
  command -v glib-compile-schemas >/dev/null || die 'Install libglib2.0-bin for schema compilation'
  schema_dir="$SYSROOT/etc/nativos/linux/usr/share/glib-2.0/schemas"
  [[ -d "$schema_dir" && ! -L "$schema_dir" ]] || die 'Missing Linux GSettings schemas'
  sudo install -m 0644 "$drawer_override" "$schema_dir/99-nativos-app-drawer.gschema.override"
  sudo glib-compile-schemas --strict "$schema_dir"
  # Do not advertise an installer backed by unavailable Flatpak/PackageKit
  # services. The tested browser catalog is explicitly browse-only; APT is
  # the supported installation path in this experimental release.
  sudo install -m 0644 "$SCRIPT_DIR/packages/nativos-app-catalog.desktop" "$SYSROOT/etc/nativos/linux/usr/share/applications/org.gnome.Software.desktop"
  for backend in packagekit flatpak snap fwupd; do
    entry="$SYSROOT/etc/nativos/linux/usr/share/applications/gnome-software-local-file-$backend.desktop"
    if [[ -f "$entry" && ! -L "$entry" ]]; then
      printf '\nHidden=true\n' | sudo tee -a "$entry" >/dev/null
    fi
  done
  # Public ELF libraries must remain readable after the runner drops root.
  # The supplied tree contains shared objects accidentally staged as mode 0600.
  # Change only regular shared-library files; preserve executables and secrets.
  linux_usr="$SYSROOT/etc/nativos/linux/usr"
  if [[ -x "$linux_usr/local/libexec/nativos-proot" ]]; then
    sudo install -m 0755 "$SCRIPT_DIR/packages/nativos-packages.py" "$linux_usr/local/bin/nativos-packages"
    [[ -f "$SCRIPT_DIR/packages/libnativos-guest-audit.so" ]] || die 'Build the reviewed ARM64 guest audit compatibility library first'
    [[ "$(sha256sum "$SCRIPT_DIR/packages/libnativos-guest-audit.so" | awk '{print $1}')" == 0247dcbbb1ad9a97d6fcbb288ea21ec1198dcf40c3c269b1a67150f4d78bc9b8 ]] || die 'Unexpected guest audit compatibility binary'
    sudo install -m 0644 "$SCRIPT_DIR/packages/libnativos-guest-audit.so" "$linux_usr/local/share/nativos-packages/libnativos-guest-audit.so"
    for package_tool in apt apt-get apt-cache dpkg; do
      sudo install -m 0755 "$SCRIPT_DIR/packages/package-tool-router.sh" "$linux_usr/local/bin/$package_tool"
    done
    sudo install -m 0644 "$SCRIPT_DIR/packages/terminal-package-routing.bash" "$SYSROOT/etc/nativos/linux/etc/nativos-package-routing.bash"
    if ! sudo grep -Fq '/etc/nativos-package-routing.bash' "$SYSROOT/etc/nativos/linux/etc/bash.bashrc"; then
      printf '\n. /etc/nativos-package-routing.bash\n' | sudo tee -a "$SYSROOT/etc/nativos/linux/etc/bash.bashrc" >/dev/null
    fi
  fi
  # Public distribution programs/data were also staged with a restrictive
  # umask. Mirror the owner's read/execute bits for these public trees only.
  # Do not recursively change /etc, /root, /home, /var or application data.
  for public_tree in bin sbin lib libexec share; do
    public_path="$linux_usr/$public_tree"
    [[ -d "$public_path" && ! -L "$public_path" ]] || continue
    sudo find "$public_path" -type d -exec chmod a+rx {} +
    sudo find "$public_path" -type f -perm -400 -exec chmod a+r {} +
    sudo find "$public_path" -type f -perm -100 -exec chmod a+x {} +
  done
  linux_lib="$linux_usr/lib"
  sudo find "$linux_lib" -type f -name '*.so*' -exec chmod a+r {} +
  unreadable_lib="$(sudo find "$linux_lib" -type f -name '*.so*' ! -perm -004 -print -quit)"
  [[ -z "$unreadable_lib" ]] || die "Linux library unreadable after privilege drop: $unreadable_lib"
  # The source archive also has public NSS configuration at mode 0600.
  # Correct only this explicit public configuration list, never shadow/keys.
  linux_etc="$SYSROOT/etc/nativos/linux/etc"
  [[ -f "$SCRIPT_DIR/normalize-linux-public-config.sh" ]] || die 'Missing public-config normalization script'
  sudo bash "$SCRIPT_DIR/normalize-linux-public-config.sh" "$SYSROOT/etc/nativos/linux"
  [[ -f "$SCRIPT_DIR/nativos-runtime/tests/linux-session-smoke.py" ]] || die 'Missing session functional tests'
  sudo install -m 0755 "$SCRIPT_DIR/nativos-runtime/tests/linux-session-smoke.py" "$SYSROOT/etc/nativos/linux/usr/local/bin/nativos-session-smoke"
  [[ -f "$linux_etc/nsswitch.conf" && ! -L "$linux_etc/nsswitch.conf" ]] || die 'Missing regular Linux NSS configuration'
fi
sudo install -d -m 0755 "$SYSROOT/etc/permissions" "$SYSROOT/etc/init"

if [[ -n "$PRIV_XML" ]]; then
  [[ -f "$PRIV_XML" ]] || die "PRIV_XML not found: $PRIV_XML"
  sudo install -m 0644 "$PRIV_XML" "$SYSROOT/etc/permissions/privapp-permissions-nativos.xml"
else
  xml="$TMP/privapp-permissions-nativos.xml"
  {
    printf '%s\n' '<?xml version="1.0" encoding="utf-8"?>' '<permissions>'
    printf '    <privapp-permissions package="%s">\n' "$pkg"
    aapt dump permissions "$APK" \
      | sed -n "s/.*uses-permission: name='\(android\.permission\.[^']*\)'.*/\1/p" \
      | sort -u \
      | while IFS= read -r permission; do
          printf '        <permission name="%s" />\n' "$permission"
        done
    printf '%s\n' '    </privapp-permissions>' '</permissions>'
  } > "$xml"
  sudo install -m 0644 "$xml" "$SYSROOT/etc/permissions/privapp-permissions-nativos.xml"
fi

if [[ -n "$INIT_RC" ]]; then
  [[ -f "$INIT_RC" ]] || die "INIT_RC not found: $INIT_RC"
  sudo install -m 0644 "$INIT_RC" "$SYSROOT/etc/init/nativos.rc"
else
  rc="$TMP/nativos.rc"
  printf '%s\n' \
    'on property:sys.boot_completed=1' \
    '    exec_background u:r:shell:s0 shell shell -- /system/bin/settings put global window_animation_scale 0' \
    '    exec_background u:r:shell:s0 shell shell -- /system/bin/settings put global transition_animation_scale 0' \
    '    exec_background u:r:shell:s0 shell shell -- /system/bin/settings put global animator_duration_scale 0' \
    '    exec_background u:r:shell:s0 shell shell -- /system/bin/settings put global background_process_limit 1' \
    > "$rc"
  sudo install -m 0644 "$rc" "$SYSROOT/etc/init/nativos.rc"
fi

# Label every newly-created node exactly as requested. Existing filesystem
if [[ -n "$RUNTIME_DIR" ]]; then
  [[ -n "$ROOTFS_TREE" ]] || die 'integrated runtime requires a prepared rootfs'
  for asset in nativosd-arm64 nativos-session-runner-arm64 nativosd.rc nativos.cil file_contexts seapp_contexts merge-app-certificate.py xkbcomp; do
    [[ -f "$RUNTIME_DIR/$asset" ]] || die "missing runtime asset: $asset"
  done
  sudo install -m 0755 "$RUNTIME_DIR/nativosd-arm64" "$SYSROOT/bin/nativosd"
  sudo install -m 0755 "$RUNTIME_DIR/nativos-session-runner-arm64" "$SYSROOT/bin/nativos-session-runner"
  sudo install -m 0644 "$RUNTIME_DIR/nativosd.rc" "$SYSROOT/etc/init/nativosd.rc"
  sudo install -d -m 0755 "$SYSROOT/etc/nativos/x11/bin" "$SYSROOT/etc/nativos/x11/share"
  sudo install -m 0755 "$RUNTIME_DIR/xkbcomp" "$SYSROOT/etc/nativos/x11/bin/xkbcomp"
  sudo ln -s ../../linux/usr/share/X11 "$SYSROOT/etc/nativos/x11/share/X11"
  policy_dir="$SYSROOT/etc/selinux"
  declare -A original_policy_labels
  policy_files=(plat_mac_permissions.xml plat_sepolicy.cil plat_file_contexts plat_seapp_contexts plat_sepolicy_and_mapping.sha256)
  for policy_file in "${policy_files[@]}"; do
    original_policy_labels[$policy_file]="$(sudo getfattr --only-values -n security.selinux "$policy_dir/$policy_file" 2>/dev/null | tr -d '\000')"
    [[ "${original_policy_labels[$policy_file]}" == u:object_r:*:s0 && "${original_policy_labels[$policy_file]}" != *:unlabeled:* ]] || die "missing original policy label: $policy_file"
  done
  [[ -f "$policy_dir/plat_mac_permissions.xml" && ! -L "$policy_dir/plat_mac_permissions.xml" ]] || die 'unexpected platform signer policy layout'
  sudo python3 "$RUNTIME_DIR/merge-app-certificate.py" "$APKSIGNER" "$APK" "$policy_dir/plat_mac_permissions.xml" "$TMP/merged-mac.xml"
  sudo install -m 0644 "$TMP/merged-mac.xml" "$policy_dir/plat_mac_permissions.xml"
  for pair in 'nativos.cil:plat_sepolicy.cil' 'file_contexts:plat_file_contexts' 'seapp_contexts:plat_seapp_contexts'; do
    input="${pair%%:*}"
    output="${pair#*:}"
    [[ -f "$policy_dir/$output" && ! -L "$policy_dir/$output" ]] || die "unexpected policy layout: $output"
    { sudo cat "$policy_dir/$output"; printf '\n'; cat "$RUNTIME_DIR/$input"; } > "$TMP/$output"
    sudo install -m 0644 "$TMP/$output" "$policy_dir/$output"
  done
    if [[ -x "$SYSROOT/etc/nativos/linux/usr/local/libexec/nativos-proot" ]]; then
      [[ -f "$SCRIPT_DIR/packages/packages.cil" && -f "$SCRIPT_DIR/packages/file_contexts" ]] || die 'missing package policy'
      for pair in 'packages.cil:plat_sepolicy.cil' 'file_contexts:plat_file_contexts'; do
        input="${pair%%:*}"; output="${pair#*:}"
        if [[ "$input" == packages.cil ]]; then
          sudo python3 "$SCRIPT_DIR/packages/merge-package-policy.py" "$policy_dir/$output" "$SCRIPT_DIR/packages/$input" "$TMP/package-$output"
        else
          { sudo cat "$policy_dir/$output"; printf '\n'; cat "$SCRIPT_DIR/packages/$input"; } > "$TMP/package-$output"
        fi
        sudo install -m 0644 "$TMP/package-$output" "$policy_dir/$output"
        cp "$TMP/package-$output" "$TMP/$output"
      done
    fi
  if [[ -n "${MEMFD_COMPAT_REFERENCE:-}" ]]; then
    sudo python3 "$SCRIPT_DIR/packages/add-memfd-compat.py" "$policy_dir/plat_sepolicy.cil" "$MEMFD_COMPAT_REFERENCE" "$TMP/memfd-plat.cil" "$OUT_DIR/memfd-adapter-report.json"
    sudo install -m 0644 "$TMP/memfd-plat.cil" "$policy_dir/plat_sepolicy.cil"
    cp "$TMP/memfd-plat.cil" "$TMP/plat_sepolicy.cil"
  fi
  # Invalidate the vendor's cached policy fingerprint so init compiles these
  # modified platform inputs with each device's own vendor policy.
  sha256sum "$TMP/plat_sepolicy.cil" | awk '{print $1}' > "$TMP/plat-policy.sha256"
  sudo install -m 0644 "$TMP/plat-policy.sha256" "$policy_dir/plat_sepolicy_and_mapping.sha256"
  for policy_file in "${policy_files[@]}"; do
    sudo setfattr -n security.selinux -v "${original_policy_labels[$policy_file]}" "$policy_dir/$policy_file"
    actual_label="$(sudo getfattr --only-values -n security.selinux "$policy_dir/$policy_file" 2>/dev/null | tr -d '\000')"
    [[ "$actual_label" == "${original_policy_labels[$policy_file]}" ]] || die "policy label verification failed: $policy_file"
    printf 'Verified policy label: %s %s\n' "$policy_file" "$actual_label"
  done
  sudo setfattr -n security.selinux -v 'u:object_r:nativosd_exec:s0' "$SYSROOT/bin/nativosd" "$SYSROOT/bin/nativos-session-runner"
  sudo setfattr -n security.selinux -v 'u:object_r:system_file:s0' "$SYSROOT/etc/init/nativosd.rc"
fi

# Label every newly-created passive asset exactly as requested.
# metadata and labels remain untouched because this is an in-place ext4 edit.
for p in \
  "$SYSROOT/priv-app/NativOS" \
  "$SYSROOT/priv-app/NativOS/NativOS.apk" \
  "$SYSROOT/etc/nativos" \
  "$SYSROOT/etc/permissions/privapp-permissions-nativos.xml" \
  "$SYSROOT/etc/init/nativos.rc"; do
  [[ -e "$p" ]] && sudo setfattr -n security.selinux -v 'u:object_r:system_file:s0' "$p"
done
find "$SYSROOT/etc/nativos" -print0 | sudo xargs -0 -r -n 256 setfattr -h -n security.selinux -v 'u:object_r:system_file:s0'
find "$SYSROOT/priv-app/NativOS/lib" -print0 | sudo xargs -0 -r -n 256 setfattr -h -n security.selinux -v 'u:object_r:system_file:s0'
if [[ -n "$RUNTIME_DIR" && -n "$ROOTFS_TREE" && -d "$SYSROOT/etc/nativos/linux/usr/lib/firefox" ]]; then
  # Apply executable exceptions AFTER the passive asset labeling above.
  # Only immutable Firefox launchers enter the approved browser JIT domain.
  for browser_exec in firefox firefox-bin; do
    browser_path="$SYSROOT/etc/nativos/linux/usr/lib/firefox/$browser_exec"
    [[ -f "$browser_path" && ! -L "$browser_path" ]] || die 'invalid browser entrypoint'
    sudo setfattr -n security.selinux -v 'u:object_r:nativos_browser_exec:s0' "$browser_path"
    browser_label="$(sudo getfattr --only-values -n security.selinux "$browser_path" 2>/dev/null | tr -d '\000')"
    [[ "$browser_label" == 'u:object_r:nativos_browser_exec:s0' ]] || die 'browser label mismatch'
  done
fi

if [[ -n "$RUNTIME_DIR" && -x "$SYSROOT/etc/nativos/linux/usr/local/libexec/nativos-proot" ]]; then
  sudo setfattr -n security.selinux -v 'u:object_r:nativos_package_exec:s0' "$SYSROOT/etc/nativos/linux/usr/local/libexec/nativos-proot"
  [[ "$(sudo getfattr --only-values -n security.selinux "$SYSROOT/etc/nativos/linux/usr/local/libexec/nativos-proot" 2>/dev/null | tr -d '\000')" == 'u:object_r:nativos_package_exec:s0' ]] || die 'package entrypoint label mismatch'
fi

for p in \
  "$SYSROOT/priv-app/NativOS/NativOS.apk" \
  "$SYSROOT/etc/permissions/privapp-permissions-nativos.xml" \
  "$SYSROOT/etc/init/nativos.rc"; do
  label="$(sudo getfattr --only-values -n security.selinux "$p" 2>/dev/null | tr -d '\000')"
  [[ "$label" == 'u:object_r:system_file:s0' ]] || die "wrong SELinux label on $p: $label"
done

if [[ "$SKIP_LEGACY_ROOTFS_ARCHIVE" == 0 ]]; then
  label="$(sudo getfattr --only-values -n security.selinux "$SYSROOT/$ROOTFS_REL" 2>/dev/null | tr -d '\000')"
  [[ "$label" == 'u:object_r:system_file:s0' ]] || die 'wrong legacy rootfs label'
fi

free_bytes="$(df -B1 --output=avail "$MNT" | tail -n1 | tr -d ' ')"
(( free_bytes >= 268435456 )) || die "less than 256 MiB free remains in the filesystem; use a larger target partition"
sync
sudo umount "$MNT"
mounted=0

printf '[5/9] Checking modified ext4...\n'
repair_fs -fy "$RAW"
e2fsck -fn "$RAW"

printf '[6/9] Creating a fresh AVB hashtree%s and footer...\n' "$([[ "$GENERATE_FEC" == 1 ]] && printf '/FEC' || true)"
avbtool add_hashtree_footer \
  --image "$RAW" \
  "${common_avb_args[@]}" \
  "${sign_args[@]}" \
  "${fec_args[@]}"

printf '[7/9] Verifying the rebuilt AVB image...\n'
avbtool info_image --image "$RAW" > "$OUT_DIR/NativOS-avb-info.txt"
avbtool verify_image --image "$RAW" "${verify_key_args[@]}"
[[ "$(stat -c %s "$RAW")" == "$TARGET_PARTITION_SIZE_BYTES" ]] || die "final raw image size does not equal target partition size"

printf '[8/9] Converting final image to Android sparse format...\n'
tmp_out="$OUT_IMG.partial"
rm -f -- "$tmp_out"
img2simg "$RAW" "$tmp_out"
mkdir -p "$TMP/sparse-verify"
ln -s "$tmp_out" "$TMP/sparse-verify/system.img"
avbtool verify_image --image "$TMP/sparse-verify/system.img" "${verify_key_args[@]}"
mv -f -- "$tmp_out" "$OUT_IMG"

printf '[9/9] Writing checksums and report...\n'
sha256sum "$OUT_IMG" > "$OUT_IMG.sha256"
{
  printf 'Output: %s\n' "$OUT_IMG"
  printf 'APK package: %s\n' "$pkg"
  printf 'AVB partition name: %s\n' "$partition_name"
  printf 'Logical partition size: %s bytes\n' "$TARGET_PARTITION_SIZE_BYTES"
  printf 'Legacy rootfs archive omitted: %s\n' "$SKIP_LEGACY_ROOTFS_ARCHIVE"
  printf 'Footer algorithm: %s\n' "$([[ -n "$AVB_KEY" ]] && printf '%s' "$avb_algorithm" || printf NONE)"
  printf 'Hashtree: enabled\n'
  printf 'FEC: %s\n' "$([[ "$GENERATE_FEC" == 1 ]] && printf enabled || printf disabled)"
  printf 'SELinux label: u:object_r:system_file:s0\n'
  printf 'SHA-256: '
  cut -d' ' -f1 "$OUT_IMG.sha256"
} | tee "$REPORT"

printf '\nSUCCESS: %s\n' "$OUT_IMG"
if [[ -z "$AVB_KEY" ]]; then
  printf '%s\n' 'IMPORTANT: this footer uses algorithm NONE; flash the matching stock vbmeta with verification and verity disabled.'
fi
