# NativOS-GSI

An experimental Linux-first Android Generic System Image combining an Ubuntu ARM64 / Phosh desktop with Android applications and device hardware support.

NativOS boots Android and starts an integrated Linux desktop through a custom HOME application. The device's Android kernel, vendor firmware, hardware abstraction layers, and framework remain essential. This is not a standalone Linux kernel port, and it does not require Magisk for the integrated startup path.

## Experimental status

This is development source, not a production-certified operating system. Do not use it on a primary phone or on a device without a tested stock-firmware recovery procedure.

- Flashing and unlocking can erase all device data.
- Keep the bootloader unlocked while custom images or verification-disabled metadata are installed.
- A/B partitioning alone does not establish compatibility.
- Firmware, vendor policy, kernel features, architecture, and partition capacity must be checked for each device.
- The current image targets a **5 GiB system partition**: `5368709120` bytes.
- Linux application compatibility is incomplete. Installing a package is not proof that its graphical interface or hardware-dependent features work.
- Strict production SELinux policy validation has not passed. SELinux Enforcing on a running phone is not a substitute for that validation.

Read [installation and recovery](docs/INSTALLATION.md), [known limitations](docs/STATUS.md), and [security boundaries](SECURITY.md) before proceeding.

## Implementation

- Custom Android launcher with an embedded Termux:X11 display server.
- Android init-managed native setup service with authenticated, fixed lifecycle requests.
- Private mount namespace and native chroot for the read-only Ubuntu desktop.
- Privilege drop to the launcher UID, cleared capabilities, and no-new-privileges before ordinary Linux desktop execution.
- Phoc/Phosh using a nested display path and software rendering.
- Per-user writable Linux package environment using a native ARM64 PRoot worker.
- APT command routing, package transaction locking, and exported application launchers.
- Dock, wallpaper, Android application shortcuts, drawer gestures, and rotation handling.

The core desktop uses native chroot; the writable package layer uses PRoot. Neither chroot nor PRoot alone provides a security sandbox. See [architecture](docs/ARCHITECTURE.md).

## Device evidence

| Device | Verified evidence | Qualification |
| --- | --- | --- |
| Google Pixel 6a (`bluejay`) | V33 RC2 clean boot, Linux desktop, 12 APT checks; later controlled storage/package persistence | Tested vendor firmware: Android 16 `CP1A.260405.005`. The later OpenSSH audit compatibility repair was applied live and is newer than V33. |
| Motorola Moto G71 5G (`corfur`) | Earlier V30 baseline desktop and subsequent live package/UI testing | V33 clean-install testing on stock Moto firmware has not been completed. |
| Other phones | Not accepted as supported | ARM64/Treble eligibility is only a starting point. |

There is no verified claim that this image runs on most A/B phones.

## Source and image versions

The source at the tip of this repository includes a guest audit compatibility fix discovered after V33 RC2 was built. The saved V33 image does **not** contain that later fix. A new image and fresh device validation are required before describing the fix as available out of the box.

Image binaries, APKs, rootfs archives, OEM firmware, private signing keys, user data, and prebuilt native dependencies are not committed here. A source push does not publish a downloadable release image. Do not assume an artifact exists until it is explicitly attached to a release with its checksum and tested firmware information.

## Package usage

In the ordinary NativOS Linux terminal:

```sh
apt update
apt install vim tree
tree --version
```

No `sudo` is needed for the private package environment. This does not grant Android root. Close package-installed Linux applications before installs, upgrades, removals, or repair operations. Exact repository refresh and selected cache queries may run alongside package applications after initialization.

## Repository layout

```text
android/                 Android launcher, display integration, and app sources
gsi/build-nativos-gsi.sh Ext4 / AVB image assembly
gsi/nativos-runtime/     Native service, session runner, policy, and tests
gsi/packages/            Package manager, guest compatibility, and source tests
scripts/                 Rootfs packaging and guarded device-specific utilities
docs/                    Build prerequisites, installation, architecture, and status
```

See [build documentation](docs/BUILDING.md). This checkout is not yet a self-contained, one-command reproducible image build; external prepared rootfs, native dependencies, policy snapshots, and signing inputs are required.

## Development checks

```sh
python3 gsi/packages/tests.py
python3 gsi/packages/test-transaction-locks.py
python3 gsi/nativos-runtime/tests/client_policy_test.py
bash gsi/nativos-runtime/tests/public-config-test.sh
```

The complete host suite additionally needs the reviewed ARM64 guest compatibility library. Namespace and privilege tests require an appropriately isolated Linux/WSL root environment. Host tests do not replace physical-device testing.

## Contributing

Include the device model, firmware/vendor build, exact image version, reproduction steps, and sanitized logs in bug reports. Remove serial numbers, tokens, account details, and personal files. Do not submit private keys, stock firmware archives, or phone backups.

Changes to SELinux, mount setup, UID handling, package execution, or flashing must include boundary/regression tests. Do not weaken security controls merely to make one application launch.

## License and acknowledgements

NativOS source retains the project's GPL-3.0 license. Third-party components retain their own licenses and notices. See [LICENSE](LICENSE), [NOTICE](NOTICE.md), and [third-party notices](THIRD_PARTY_NOTICES.md).

NativOS is independent of LineageOS, Termux, GNOME, Canonical, Google, Motorola, and other upstream projects or device manufacturers.
