# Architecture

## Boot and display

Android boots on the device's existing kernel and vendor stack. The NativOS HOME application supplies an embedded X server and requests a fixed Linux session from `nativosd`, which is managed by Android init.

The runner prepares a private mount namespace, a read-only Ubuntu base and selected device/socket bindings. It uses a PID namespace where supported, with a tested supervisor fallback where it is unavailable. It then drops to the authenticated application UID/GID, clears capability sets and enables `PR_SET_NO_NEW_PRIVS` before starting the desktop.

Phoc runs nested through the Android X server and hosts the Phosh Wayland desktop. Software rendering is the validated baseline. This is not direct ownership of the phone's DRM/KMS display hardware, and no general GPU acceleration claim is made. SystemUI remains enabled because disabling it previously broke touch input. Launcher3 remains available for stability and fallback.

## Storage

| Android storage | Linux view | Purpose |
| --- | --- | --- |
| `/system/etc/nativos/linux` | `/` | Read-only desktop base |
| `/data/misc/nativos/homes/<uid>` | `/home/nativos` | Persistent user files and settings |
| `/data/misc/nativos/packages/<uid>` | `/var/lib/nativos-packages` | Private writable package tree |
| Checked per-user display directory | `/tmp/.X11-unix` | Embedded display socket |

A userdata wipe removes Linux home and installed packages. UID/signing changes require migration review. The prepared base must never be built from an unreviewed personal rootfs.

## Writable packages

The immutable desktop cannot safely be made globally writable just to run APT. A native ARM64 PRoot worker instead executes packages from a per-user guest tree. APT receives simulated UID 0 for package bookkeeping, while the real Android identity remains unprivileged.

APT/dpkg routers are installed in `/usr/local/bin`. Interactive shell fallback can launch installed `/usr/bin` tools from the package tree. This is command routing, not a complete overlay filesystem; an existing immutable base executable can take precedence over a newer guest executable.

Package apps hold shared transaction locks. Installs/upgrades/removals require an exclusive lock. Exact metadata updates and selected cache queries can coexist with apps. APT's own metadata lock serializes updates. Lock files must not be deleted to bypass active transactions.

The newer guest audit compatibility library addresses account-maintenance tools that otherwise abort when Android denies kernel audit access. Migration is restricted to an exclusive package transaction and preserves existing preload configuration.

## AVB and image assembly

The builder verifies the input, removes existing AVB footer metadata before filesystem changes, preserves labels/metadata while rebuilding ext4, checks the filesystem, and generates a fresh hashtree/footer. Raw and sparse outputs are verified separately.

A valid development signature is not an OEM-trusted signature. Firmware-specific verification handling on an unlocked bootloader remains necessary. Never append bytes or resize ext4 while treating an old footer as still valid.

## Legacy code

The app source still contains legacy RootShell/chroot-related code. Its presence does not mean the integrated daemon provides arbitrary root commands or that every legacy feature is supported. New work should use the fixed authenticated service path and preserve the unprivileged desktop boundary.
