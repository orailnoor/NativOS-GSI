# Status and known limitations

Evidence recorded through 14 October 2026. This is an experimental development snapshot.

## Image and source distinction

V33 RC2 SHA-256:

```text
cffd9f67d4b26e4d5772335c43cac89d085318933783e97b44081be861bd86d3
```

Its logical system partition target is `5368709120` bytes. It includes the terminal routing/locking changes, launcher/rotation work, append permission correction and Pixel memfd compatibility adapter.

The current source additionally contains the later guest audit compatibility fix. That change was tested live on the Pixel but is not in the saved V33 binary. It needs a new build and clean-install validation.

## Verified observations

- Pixel 6a: V33 Android boot, Phoc/Phosh desktop and Console with SELinux Enforcing.
- Twelve first-run APT checks passed: routing, repository refresh, Vim/tree installation and execution, repeat installation, database audit, app/update coexistence, mutation lock protection and file append.
- A later live compatibility repair passed OpenSSH configuration, Git execution, database audit and unprivileged identity/errno checks.
- A controlled no-wipe reboot preserved fresh home/package markers, Git and configured OpenSSH; Android/NativOS restarted normally.
- An earlier recovery/data-state transition was observed, and the original home report was later absent. Its cause remains unconfirmed. The later controlled persistence pass does not explain that earlier event.
- Moto G71: earlier V30 desktop and live application/package testing. Do not label V33 clean-install tested on Moto yet.

## Not supported or not fully validated

- Universal compatibility or a verified count of supported phones.
- Production security certification: strict baseline/vendor policy checking reproduced 1,699 assertion failures. Separate compiled boundary checks passed; structural linking is not equivalent to strict validation.
- Native Flatpak installation. The visible catalog is web browsing, not an installer.
- VS Code/Code OSS Electron GUI compatibility under the current JIT/sandbox restrictions.
- General GPU acceleration, hardware video decode, external-monitor workflows and full Android hardware bridging.
- Unrestricted `/proc` access; monitoring tools such as htop have encountered restrictions.
- Every VLC/LocalSend workflow, every LibreOffice component, printing, and arbitrary third-party DEBs.
- Complete migration semantics for changed seeds, signing identities, multiple Android users or work profiles.
- Fully automated redistribution/source provenance for every external native dependency.
- Final UI polish, including clock/timezone alignment and status-bar presentation across devices.

## Before a public binary release

1. Build from a documented source revision with recorded tool/input hashes.
2. Include the later audit fix in the image itself and test on fresh userdata.
3. Repeat package install, upgrade, removal, interrupted-transaction recovery and reboot persistence tests.
4. Validate Moto and Pixel separately with exact firmware records.
5. Review policy, UID/capability boundaries, IPC, mounts and lifecycle cleanup.
6. Publish checksum, exact tested device/firmware combinations, recovery instructions, licenses and known failures alongside the image.

Do not describe a source-only commit as a tested downloadable release.
