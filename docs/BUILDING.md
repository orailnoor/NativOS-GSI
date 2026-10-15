# Building and external inputs

The published tree contains development source, not all of the large/prebuilt inputs used for the local V33 build. A clean checkout cannot yet regenerate that image without preparing those inputs. Do not substitute arbitrary libraries or claim bit-for-bit reproducibility.

## Host prerequisites

Use Linux or Ubuntu under WSL2 with loop mounts, ext4/xattr support and sufficient disk space. Use the Linux filesystem for prepared rootfs trees to preserve ownership, links and xattrs. Image assembly needs setup privileges on the build host; Linux applications on the phone must not receive Android root.

Required tools include Python 3.12+, C/C++ build tools, GNU tar, e2fsprogs, attr utilities, AOSP `avbtool`, Android sparse-image tools, `aapt`, `apksigner`, `secilc`, Java 17, Android SDK and Android NDK. The audited guest shim was built with the LLVM tools from NDK r28c targeting glibc ARM64, not Android bionic.

## Android application

The Gradle wrapper and application source are under `android/`. Supply the external native libraries at the paths expected by Gradle, and a reviewed rootfs archive/checksum under `android/app/src/main/assets/rootfs/`. Shared libraries, GPU DEBs and the rootfs are not committed.

The Xlorie cursor patch checks the exact upstream SHA-256 before changing instructions. A different native build requires a reviewed patch, not disabling the checksum check.

For a release APK, create your own keystore and local `android/signing/keystore.properties` with `storeFile`, `storePassword`, `keyAlias` and `keyPassword`. These files are ignored by Git. Never reuse or publish a maintainer's private key. Signing identity changes also affect certificate-bound runtime policy and upgrade compatibility.

```sh
cd android
./gradlew assembleRelease
```

An unsigned APK from missing signing configuration is not a validated release artifact. Record the APK digest and signer certificate.

## Rootfs and native runtime

`scripts/build-rootfs-asset.sh` packages an already prepared ARM64 rootfs; it does not provision the desktop from scratch. Review the rootfs for personal data and retain package/version and license manifests. `gsi/nativos-runtime/prepare-rootfs.py` stages a pinned archive without executing archive content.

Build `nativosd` and the runner using `gsi/nativos-runtime/build-android.ps1 -NdkRoot <windows-ndk-root>` or equivalent reviewed Linux NDK commands. Provide a trusted ARM64 `xkbcomp` in the runtime directory. Do not substitute host x86 executables.

The PRoot worker must match the revision and binary digest in the immutable worker manifest. Host-lab scripts require an explicitly prepared disposable ARM64 guest and do not establish device acceptance.

Build the guest audit compatibility library with the reviewed compiler:

```sh
CLANG=/path/to/ndk/toolchains/llvm/prebuilt/linux-x86_64/bin/clang \
  bash gsi/packages/build-guest-audit-compat.sh
python3 gsi/packages/test-guest-compat.py
```

The binary digest is pinned in the source/build guards. If a toolchain change alters it, review the result and update the pin through a reviewed change. Do not bypass the guard.

## Policy checks

Supply the base and device policy snapshots expected under `work/policy-snapshot/` and a matching policy compiler/query tool. Those snapshots are external build inputs and are not committed. Generate the compiled boundary report from the actual candidate policy; do not copy old hashes into a new report.

The current strict baseline/vendor assertion failures are a release blocker. `STRUCTURAL_ONLY=1` is diagnostic linking, not a production security pass. The memfd adapter is tied to its pinned Pixel stock-platform reference; it is not a universal vendor-policy repair.

## Image assembly

Use a new output directory and preserve working images. The following is a template, not a substitute for preparing the inputs above:

```sh
export BASE_IMG=/path/to/verified-lineage-base.img
export APK=/path/to/signed-app-release.apk
export ROOTFS=/path/to/nativos-rootfs-arm64.tgz
export ROOTFS_TREE=/var/tmp/nativos-linux-packages.prepared
export RUNTIME_DIR="$PWD/gsi/nativos-runtime"
export OUT_DIR=/path/to/new-build-directory
export OUT_IMG="$OUT_DIR/NativOS-integrated-arm64-ab.img"
export TARGET_PARTITION_SIZE_BYTES=5368709120
export SKIP_LEGACY_ROOTFS_ARCHIVE=1
export SKIP_ANDROID_ONBOARDING=1
export APKSIGNER=/path/to/android-sdk/build-tools/34.0.0/apksigner
# Set AVB_KEY only to an appropriate local development key accepted by the
# builder's base-image key check. No private keys are supplied in Git.
bash gsi/build-nativos-gsi.sh
```

When using the Pixel compatibility adapter, also provide the pinned `MEMFD_COMPAT_REFERENCE`. Never replace the original base image, enlarge a footer-bearing image with appended zeros, or reuse an old hash tree after filesystem changes.

Successful ext4, AVB and source tests do not establish boot or application compatibility. Test the exact resulting image on fresh userdata, then verify reboot persistence, ordinary package operations, real UID/capabilities, SELinux enforcement, input and graphics.
