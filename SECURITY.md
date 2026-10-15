# Security and reporting

NativOS is experimental. No production security certification, complete audit, or broad device acceptance is claimed.

The Android setup service needs privilege for fixed namespace/mount preparation. Ordinary Linux desktop and package applications must remain real unprivileged Android processes, with capabilities cleared and no-new-privileges set. The package guest's simulated root identity is not Android root.

The daemon authenticates kernel-supplied peer UID and SELinux context and accepts fixed lifecycle requests, not arbitrary shell commands. A package name or world-accessible socket mode alone is not authentication.

The Linux environment shares one user's home and package environment. It is not per-application isolation. Downloaded package scripts and applications can modify files available to that user. PRoot is a compatibility mechanism, not a security boundary.

The guest audit compatibility library reports kernel auditing unavailable inside the package guest. It does not disable Android audit/SELinux, grant audit capabilities, or create a privileged execution path.

Known release blockers include strict baseline/vendor policy assertion failures, incomplete MLS/DAC and bridge review, remaining application compatibility issues, and insufficient device coverage. Do not report structural policy linking or SELinux Enforcing alone as a full security pass.

Never publish credentials, private signing keys, raw user homes, account databases from a personal system, or unsanitized phone backups. Report sensitive vulnerabilities privately to the maintainer before posting exploit details or private data in public issues. No response-time guarantee is currently offered.
