# Installation and recovery

## Warnings

This is experimental software. Unlocking, flashing and factory reset can permanently erase apps, accounts, photos and internal-storage files. Back up data outside the phone first. Keep a complete matching stock-firmware package and a tested recovery procedure available.

Keep the bootloader unlocked while NativOS or modified vbmeta is installed. Do not relock to remove the boot warning. Do not flash a GSI over an unknown firmware/vendor combination, interrupt a flash, or copy another model's vbmeta/boot/vendor images.

There is no universal sequence for all A/B phones. The GSI does not replace the kernel/vendor stack. Dynamic partition resizing/deletion is device-specific and can make the existing stock system unbootable.

Official background: [Android GSI guidance](https://source.android.com/docs/core/tests/vts/gsi), [Pixel factory images](https://developers.google.com/android/images), and [SDK Platform-Tools](https://developer.android.com/tools/releases/platform-tools).

## Before flashing

1. Obtain an explicitly published image, its SHA-256, release notes and matching device/firmware instructions. This source repository does not itself supply an image.
2. Confirm the exact model, ARM64 ABI, Treble support, bootloader unlock state, active slot, vendor build, snapshot state and partition capacity.
3. Use current Android Platform-Tools, a reliable cable and adequate battery power. Target the exact device serial on every command.
4. Back up data and verify stock recovery files. Stock recovery may not provide an ADB shell or readable logs.
5. Verify the image checksum locally. Do not use a partial download.

```sh
adb devices -l
adb -s SERIAL shell getprop ro.product.device
adb -s SERIAL shell getprop ro.product.cpu.abi
adb -s SERIAL shell getprop ro.treble.enabled
adb -s SERIAL shell getprop ro.vendor.build.fingerprint
adb -s SERIAL reboot bootloader
fastboot -s SERIAL getvar product
fastboot -s SERIAL getvar unlocked
fastboot -s SERIAL getvar current-slot
```

If the bootloader is locked, stop and follow the device manufacturer's unlock procedure. Unlocking needs on-device confirmation and typically erases data. Carrier variants may not support unlocking.

## Pixel 6a: tested configuration only

The validated vendor baseline is `google/bluejay/bluejay:16/CP1A.260405.005/15001963:user/release-keys`, with slot `a`, no active snapshot update, and a `5368709120`-byte `system_a` logical partition. Do not use this procedure on Android Canary/newer incompatible vendor firmware, another Pixel model, or the Moto.

Enter userspace fastboot for logical partitions:

```sh
fastboot -s SERIAL reboot fastboot
fastboot -s SERIAL getvar is-userspace
fastboot -s SERIAL getvar vendor-fingerprint
fastboot -s SERIAL getvar snapshot-update-status
fastboot -s SERIAL getvar partition-size:system_a
```

Expected values include `is-userspace: yes`, `snapshot-update-status: none`, and `partition-size:system_a: 0x140000000`. The image's sparse file size is not its logical partition requirement.

### AVB metadata

Use only vbmeta extracted from the matching official Pixel firmware. `scripts/prepare-pixel-vbmeta.py` accepts the pinned original metadata used in this project and creates a separate development copy with verification/verity-disable flags. It refuses other inputs and never overwrites the original. This weakens verified-boot guarantees and is only for an unlocked development device.

```sh
python3 scripts/prepare-pixel-vbmeta.py vbmeta.img vbmeta-disabled.img
```

### Fresh stock layout

Stock product/system_ext partitions can prevent a 5 GiB system image from fitting. The earlier tested Pixel conversion reclaimed **only active-slot** `product_a` and `system_ext_a`, then resized `system_a`. These operations remove parts of the stock OS. Do not run them if the model, firmware, slot, group capacity or snapshot state differs; do not delete vendor/vendor_dlkm or inactive-slot partitions.

For that exact Pixel configuration, after independently verifying capacity and accepting stock-system/data loss:

```sh
fastboot -s SERIAL delete-logical-partition product_a
fastboot -s SERIAL delete-logical-partition system_ext_a
fastboot -s SERIAL resize-logical-partition system_a 5368709120
fastboot -s SERIAL getvar partition-size:system_a
```

If already prepared at 5 GiB, do not repeat deletion/resizing. Stop on any failed command.

### Flash and clean test

After all prerequisites match and the image checksum has been verified:

```sh
fastboot -s SERIAL flash vbmeta_a vbmeta-disabled.img
fastboot -s SERIAL flash system_a NativOS-integrated-arm64-ab.img
# Destructive: erases userdata and metadata.
fastboot -s SERIAL -w
fastboot -s SERIAL reboot
```

Fastboot may erase but report that it cannot automatically format raw userdata. If stock recovery explicitly requests the initial factory reset, confirm it once, then reboot. Do not repeatedly reset a bootloop without diagnosing it. If recovery appears after an already working installation, capture its message before resetting; additional wipes destroy Linux home and installed packages.

## Moto G71 and other devices

Earlier Moto builds booted, but no general fresh-stock V33 installation recipe is accepted here. Do not reuse Pixel vbmeta or partition commands. V33-on-Moto clean testing and wider-device acceptance remain pending. Use a device-specific procedure with matching stock assets; otherwise stop.

## First boot and validation

Select NativOS as HOME if prompted. Connect Wi-Fi. For development testing, enable USB debugging and explicitly authorize the PC again after a wipe. This is separate from fastbootd and does not require Magisk.

From Linux Console, test `apt update`, installation and execution of a small package, and reboot persistence. Close package-installed applications before package mutations. The later source audit fix is not in V33; consult the exact release's limitations rather than assuming source-tip fixes are present.

## Recovery

Preserve the failing screen/logs where possible. Return to the bootloader with the device's hardware procedure if Android is inaccessible. Restore the complete matching stock firmware using the manufacturer's supported procedure when recovery is necessary. A system-only reflash may not restore modified metadata or dynamic partition layout.

Never write arbitrary recovery images into `boot`, erase broad sets of partitions, downgrade protected bootloader firmware, or relock with custom images installed. Recovery actions can cause further data loss; stop if the exact model/firmware/slot is uncertain.
