#!/usr/bin/env python3
"""Source-level drift guards, not a substitute for compiled release-policy checks."""
import re
from pathlib import Path

root = Path(__file__).resolve().parents[1]
source = root.joinpath("nativos.cil").read_text()
tokens = iter(re.findall(r"[()]|[^\s()]+", re.sub(r";[^\n]*", "", source)))

def expression():
    result = []
    for token in tokens:
        if token == ")":
            return result
        result.append(expression() if token == "(" else token)
    raise AssertionError("unclosed CIL expression")

rules = []
for token in tokens:
    assert token == "("
    rules.append(expression())

assert ["typeattributeset", "nativos_linux_client", ["nativos_session", "nativos_browser"]] in rules
assert ["typetransition", "nativos_session", "nativos_browser_exec", "process", "nativos_browser"] in rules
jit_rules = []
for rule in rules:
    if rule[0] != "allow":
        continue
    _, subject, target, access = rule
    kind, permissions = access
    if kind == "process" and "execmem" in permissions:
        jit_rules.append(rule)
        assert subject == "nativos_browser" and target == "self"
    if subject in ("nativos_linux_client", "nativos_browser"):
        assert kind not in ("capability", "capability2"), rule
        assert not (kind == "filesystem" and set(permissions) & {"mount", "remount", "unmount"}), rule
        assert not (kind == "process" and "ptrace" in permissions), rule
    if target in ("nativos_runtime_file", "tmpfs") and kind == "file":
        assert not set(permissions) & {"execute", "execute_no_trans", "entrypoint", "execmod"}, rule
assert len(jit_rules) == 1
assert ["typeattributeset", "mlstrustedsubject", ["nativos_browser"]] not in rules
contexts = root.joinpath("file_contexts").read_text()
assert "/usr/lib/firefox/firefox(-bin)? u:object_r:nativos_browser_exec:s0" in contexts
build = root.parents[1].joinpath("gsi/build-nativos-gsi.sh").read_text()
assert build.index("# Apply executable exceptions AFTER") > build.index('find "$SYSROOT/etc/nativos" -print0')
print("Client policy drift guards passed: Firefox-only JIT, no client root/mount/ptrace, no writable-file execution")
