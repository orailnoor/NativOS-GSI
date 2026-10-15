#!/usr/bin/python3
"""Fail-closed TE boundary checks using Android's matching policy reader.

The binary was linked structurally despite existing base/vendor neverallow
failures. This test does NOT turn that into a production security pass.
"""
from pathlib import Path
import hashlib
import json
import subprocess
import sys

directory = Path(__file__).resolve().parent
binary = Path(sys.argv[1]).resolve(strict=True)


def permissions(source, target, kind):
    result = subprocess.run([str(directory / 'policy-query'), str(binary), source, target, kind],
                            check=True, text=True, capture_output=True)
    return set(permission for line in result.stdout.splitlines() for permission in line.split('\t')[3].split())


checks = []
def deny(source, target, kind, denied):
    actual = permissions(source, target, kind)
    assert not actual & set(denied), (source, target, kind, actual & set(denied))
    checks.append(f'{source} -> {target} {kind}: denied ' + ','.join(denied))

for capability in ('capability', 'capability2'):
    assert not permissions('nativos_package', '*', capability), 'worker acquired kernel capability permission'
    checks.append('worker has no ' + capability + ' grants')
deny('nativos_package', '*', 'process', ['execmem', 'execstack', 'execheap', 'dyntransition'])
for target in ('nativos_session', 'nativos_browser', 'nativos_app', 'nativosd', 'shell', 'init', 'system_server'):
    deny('nativos_package', target, 'process', ['ptrace', 'transition', 'dyntransition'])
deny('nativos_package', '*', 'filesystem', ['mount', 'remount', 'unmount', 'relabelto', 'relabelfrom'])
deny('nativos_package', 'nativosd', 'unix_stream_socket', ['connectto'])
deny('nativos_package', 'nativos_socket', 'sock_file', ['write'])
for target in ('nativos_runtime_file', 'tmpfs', 'app_data_file', 'privapp_data_file'):
    deny('nativos_package', target, 'file', ['execute', 'execute_no_trans', 'entrypoint', 'execmod'])
for source in ('nativos_session', 'nativos_browser', 'nativos_app'):
    deny(source, 'nativos_package_file', 'file', ['execute', 'execute_no_trans', 'entrypoint', 'execmod'])
assert {'execute', 'execute_no_trans', 'map', 'read', 'write', 'append', 'link'} <= permissions('nativos_package', 'nativos_package_file', 'file')
assert 'ptrace' in permissions('nativos_package', 'nativos_package', 'process')
assert {'create', 'setattr', 'add_name', 'search'} <= permissions('nativos_session', 'nativos_package_file', 'dir')
assert {'read', 'write'} <= permissions('nativos_package', 'nativos_session', 'fifo_file')
assert {'create', 'setattr', 'link'} <= permissions('nativos_package', 'nativos_package_file', 'lnk_file')
assert {'create', 'read', 'write'} <= permissions('nativos_package', 'nativos_package_file', 'fifo_file')
assert 'transition' in permissions('nativos_session', 'nativos_package', 'process')
assert {'nnp_transition', 'nosuid_transition'} <= permissions('nativos_session', 'nativos_package', 'process2')
checks.append('positive checks: private code execution, own tracees, fixed transition with NNP/nosuid')
def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()
sources = [directory / 'packages.cil', directory / 'merge-package-policy.py',
           directory.parent / 'nativos-runtime/nativos.cil', directory / 'check-compiled-policy.py']
report = {
    'experimental_build_preflight_passed': True,
    'production_security_passed': False,
    'basis': 'compiled unconditional plus conservative conditional TE permissions; generated-CIL matrix test separately required',
    'policy_sha256': digest(binary),
    'source_sha256': {str(path.relative_to(directory.parent)): digest(path) for path in sources},
    'checks': checks,
    'limits': 'Not a complete MLS/DAC or crash_dump inheritance review, not device runtime acceptance, not a full strict neverallow pass. Existing baseline/vendor conflicts remain.',
}
destination = directory / 'compiled-boundaries.json'
destination.write_text(json.dumps(report, indent=2) + '\n')
print('Compiled TE boundary checks passed:', len(checks), '; production security gate remains unpassed')
