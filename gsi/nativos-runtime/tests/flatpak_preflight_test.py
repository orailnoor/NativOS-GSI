#!/usr/bin/python3
import importlib.util
from pathlib import Path

spec = importlib.util.spec_from_file_location("preflight", Path(__file__).with_name("flatpak-preflight.py"))
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)
features = probe.parse_config("CONFIG_SECCOMP=y\n# CONFIG_USER_NS is not set\n# CONFIG_PID_NS is not set\n")
assert features["USER_NS"] is False and features["PID_NS"] is False
assert features["IPC_NS"] is None  # Unknown is not evidence of support or absence.
assert features["SECCOMP"] is True
assert probe.kernel_blockers(features) == ["kernel lacks CONFIG_USER_NS", "kernel lacks CONFIG_PID_NS"]
assert not probe.kernel_blockers(dict.fromkeys(probe.FEATURES, True))
print("Flatpak preflight config parsing passed; missing and unknown features distinguished")
