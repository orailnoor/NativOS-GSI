#!/usr/bin/python3
"""Non-mutating Flatpak prerequisite check, not a sandbox certification.

Run in the ordinary Linux session. Offline --kernel-config permits host-side
inspection of a captured /proc/config.gz without executing target binaries.
Never invoke a PATH-shadowing bwrap helper or retry with root/setuid.
"""
import argparse
import gzip
import json
import os
from pathlib import Path
import shutil
import subprocess


FEATURES = ("USER_NS", "PID_NS", "IPC_NS", "NET_NS", "UTS_NS",
            "SECCOMP", "SECCOMP_FILTER", "FUSE_FS")


def parse_config(text):
    lines = set(text.splitlines())
    return {name: (True if f"CONFIG_{name}=y" in lines else
                   False if f"# CONFIG_{name} is not set" in lines else None)
            for name in FEATURES}


def kernel_blockers(features):
    # This is the NativOS rootless support contract, not a statement that
    # upstream's legacy setuid mode requires USER_NS.
    return [f"kernel lacks CONFIG_{name}" for name in
            ("USER_NS", "PID_NS", "IPC_NS", "NET_NS", "SECCOMP", "SECCOMP_FILTER")
            if features.get(name) is False]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kernel-config", type=Path)
    args = parser.parse_args()
    report = {"production_ready": False, "mode": "offline" if args.kernel_config else "session",
              "blockers": [], "limitations": ["Passing prerequisites is not Flatpak launch/portal/security acceptance"]}
    if args.kernel_config:
        path = args.kernel_config
        text = gzip.open(path, "rt").read() if path.suffix == ".gz" else path.read_text()
        features = parse_config(text)
        report["kernel_features"] = features
        report["blockers"].extend(kernel_blockers(features))
        report["runtime_tested"] = False
    else:
        if os.geteuid() == 0:
            raise SystemExit("Refusing root: run in the ordinary NativOS Linux session")
        report["uid"] = os.geteuid()
        report["namespace_entries"] = sorted(path.name for path in Path("/proc/self/ns").iterdir())
        for name in ("user", "pid", "ipc"):
            if name not in report["namespace_entries"]:
                report["blockers"].append(f"{name} namespace entry absent")
        report["binaries"] = {name: shutil.which(name) for name in ("flatpak", "bwrap", "unshare")}
        if report["binaries"]["bwrap"] != "/usr/bin/bwrap":
            report["blockers"].append("bwrap is absent or shadowed; review helper provenance before use")
        if not report["binaries"]["flatpak"]:
            report["blockers"].append("Flatpak client absent")
        unshare = Path("/usr/bin/unshare")
        if unshare.is_file():
            try:
                result = subprocess.run([str(unshare), "-Ur", "/usr/bin/true"],
                                        capture_output=True, text=True, timeout=5)
                report["userns_probe"] = {"passed": result.returncode == 0,
                                           "returncode": result.returncode,
                                           "detail": result.stderr.strip()[:1024]}
                if result.returncode:
                    report["blockers"].append("ordinary-user namespace creation failed")
            except (OSError, subprocess.TimeoutExpired) as error:
                report["blockers"].append(f"user namespace probe unavailable: {error}")
        else:
            report["blockers"].append("user namespace probe tool absent")
        report["runtime_tested"] = True
    report["status"] = "blocked" if report["blockers"] else "needs_integration_acceptance"
    print(json.dumps(report, indent=2))
    return 2 if report["blockers"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
