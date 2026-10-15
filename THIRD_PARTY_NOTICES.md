# Third-party notices and external inputs

The original NativOS project is licensed under GPL-3.0; its license and copyright notice are retained. Components retain their individual terms. This inventory is not a claim that all external binary provenance work is complete.

| Component | Use | Upstream |
| --- | --- | --- |
| Termux:X11 | Modified Android display/input source; external Xlorie native library | https://github.com/termux/termux-x11 (GPL-3.0) |
| PRoot | Writable Linux package execution and legacy app dependency | https://github.com/proot-me/proot and https://github.com/termux/proot (retain release-specific GPL notices) |
| talloc | External PRoot dependency | https://talloc.samba.org/ |
| Android shared memory | External compatibility library/source | https://github.com/termux/android-shmem |
| Ubuntu packages | Linux userspace and desktop dependencies | https://packages.ubuntu.com/ |
| Phosh / Phoc | Desktop shell and compositor | https://gitlab.gnome.org/World/Phosh |
| GNOME / Mesa | Applications, libraries and rendering | https://www.gnome.org/ and https://mesa3d.org/ |
| AOSP / LineageOS | Android base and build tools | https://source.android.com/ and https://lineageos.org/ |
| AndroidX / Kotlin / Material | Android dependencies declared in Gradle | Upstream repositories and dependency metadata |

The native package worker source revision used in development is `25dc6a3134891f98a79f57ce1c2c1b23ff15cad1` (PRoot 5.5.0). Rebuild/redistribute it with the applicable license and corresponding source. The Xlorie cursor patch in Gradle is tied to a specific upstream binary digest; it is not a general patch for arbitrary builds.

Prebuilt shared libraries, APKs, rootfs archives, GPU packages, OEM firmware, system images and private signing material are deliberately excluded from this Git tree. Obtain/build required inputs separately, verify their hashes, retain their licenses and provide corresponding source where required before distributing combined binaries.

For rootfs releases, preserve `/usr/share/doc/*/copyright` and a package/version manifest. Do not copy personal histories, accounts, SSH keys, tokens or application profiles into an image.

The included home wallpaper was supplied by the project owner as Pexels photo `pexels-eva-bronzini-6485505.jpg`, attributed to Eva Bronzini. Review the applicable Pexels asset terms before redistributing artwork separately. Project and third-party names do not imply endorsement.
