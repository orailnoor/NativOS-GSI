#!/usr/bin/python3
"""Host source guards and safe extraction tests; not Android acceptance."""
import importlib.util
from pathlib import Path
import re
import subprocess
import sys
import tarfile
import tempfile

directory = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('packages', directory / 'nativos-packages.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
assert {'/usr/sbin', '/sbin', '/usr/bin', '/bin'} <= set(module.PACKAGE_PATH.split(':'))
assert module.session_bus_binding('unix:path=/tmp/dbus-ABC123,guid=a1b2') == '/tmp/dbus-ABC123'
assert module.session_bus_binding('unix:path=/run/user/10075/bus') is None
for invalid_bus in ('unix:path=/tmp/dbus-../secret', 'unix:path=/tmp/other', 'unix:path=/tmp/dbus-X;host=elsewhere'):
    try:
        module.session_bus_binding(invalid_bus)
        raise AssertionError('invalid session-bus path accepted')
    except RuntimeError:
        pass
assert module.command_arguments('install', ['hello'])[-2:] == ['--', 'hello']
assert module.command_arguments('run', ['/usr/bin/hello']) == ['/usr/bin/hello']
assert module.command_arguments('tool', ['apt', 'update']) == ['/usr/bin/apt', 'update']
assert module.command_arguments('tool', ['apt-get', 'install', '-y', 'hello']) == ['/usr/bin/apt-get', 'install', '-y', 'hello']
assert module.desktop_arguments('/usr/bin/hello "two words" %U') == ['/usr/bin/hello', 'two words']
assert module.desktop_arguments('hello %U') == ['/usr/bin/hello']
try:
    module.desktop_arguments('/bin/sh -c dangerous')
    raise AssertionError('shell launcher accepted')
except ValueError:
    pass
for operation, arguments in [('tool', ['/bin/sh']), ('tool', ['../apt']), ('install', ['--allow-unauthenticated']), ('run', ['/bin/sh']), ('run', ['/usr/bin/../bin/sh']), ('update', ['x'])]:
    try:
        module.command_arguments(operation, arguments)
        raise AssertionError('invalid command accepted')
    except ValueError:
        pass
with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    source = root / 'source'
    (source / 'usr/bin').mkdir(parents=True)
    (source / 'etc').mkdir()
    (source / 'usr/bin/hello').write_text('hello')
    (source / 'etc/internal').symlink_to('/usr/bin/hello')
    archive_path = root / 'seed.tar.gz'
    subprocess.run([sys.executable, str(directory / 'build-seed.py'), str(source), str(archive_path)], check=True)
    with tarfile.open(archive_path) as archive:
        archive.extractall(root / 'extracted', filter='data')
    assert (root / 'extracted/etc/internal').read_text() == 'hello'
policy = (directory / 'packages.cil').read_text()
allows = re.findall(r'\(allow\s+(\S+)\s+(\S+)\s+\((\S+)\s+\(([^)]*)\)\)\)', policy)
assert allows
for subject, target, kind, permissions in allows:
    if subject == 'nativos_package':
        assert kind not in ('capability', 'capability2', 'filesystem')
        assert 'execmem' not in permissions.split()
        if 'ptrace' in permissions.split():
            assert target == 'self' and kind == 'process'
    if kind == 'file' and set(permissions.split()) & {'execute_no_trans', 'entrypoint'}:
        assert subject == 'nativos_package' and target in ('nativos_package_exec', 'nativos_package_file')
assert '(typeattributeset mlstrustedsubject (nativos_package))' not in policy
build = (directory.parent / 'build-nativos-gsi.sh').read_text()
assert "Package integration is not accepted" in build
assert build.index('Package integration is not accepted') < build.index('TMP="$(mktemp')
with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    baseline = '(type existing_app)\n(allow appdomain self (process (execmem)))\n' + \
        '(typeattributeset sources (and (domain ) (not (appdomain overlay_remounter ))))\n' + \
        '(typeattributeset targets (and (data_file_type ) (not (system_data_file apk_data_file dalvikcache_data_file apex_art_data_file ))))\n' + \
        '(neverallow sources targets (file (execute execute_no_trans)))\n' + \
        '(typeattributeset sources2 (and (domain ) (not (appdomain app_zygote mediaextractor mediaswcodec shell su webview_zygote zygote overlay_remounter system_server_startup ))))\n' + \
        '(typeattributeset targets2 (and (file_type ) (not (exec_type system_file_type vendor_file_type system_lib_file system_bootstrap_lib_file system_linker_exec postinstall_file ))))\n' + \
        '(neverallow sources2 targets2 (file (execute)))\n'
    (root / 'base').write_text(baseline)
    subprocess.run([sys.executable, str(directory / 'merge-package-policy.py'), str(root / 'base'), str(directory / 'packages.cil'), str(root / 'result')], check=True)
    result = (root / 'result').read_text()
    assert result.startswith('(type existing_app)\n(allow appdomain self (process (execmem)))')
    assert '(neverallow nativos_other_data_executor targets (file (execute execute_no_trans)))' in result
    assert '(neverallow nativos_package nativos_other_executable_data (file (execute execute_no_trans)))' in result
    # Evaluate the GENERATED CIL assertions, not a copy of the intended formula.
    tokens = iter(re.findall(r'[()]|[^\s()]+', re.sub(r';[^\n]*', '', result)))
    def expression():
        values = []
        for token in tokens:
            if token == ')':
                return values
            values.append(expression() if token == '(' else token)
        raise AssertionError('unclosed CIL')
    rules = []
    for token in tokens:
        assert token == '('
        rules.append(expression())
    universe = {'nativos_session', 'nativos_package', 'other_parent', 'other_app', 'nativos_package_file', 'nativos_runtime_file', 'system_data_file', 'app_data_file'}
    groups = {'domain': {'nativos_session', 'nativos_package', 'other_parent', 'other_app'}, 'appdomain': {'other_app'}, 'data_file_type': {'nativos_package_file', 'nativos_runtime_file', 'system_data_file', 'app_data_file'}}
    groups['file_type'] = groups['data_file_type']
    definitions = {rule[1]: rule[2] for rule in rules if rule[0] == 'typeattributeset'}
    def evaluate(value):
        if isinstance(value, str):
            if value in groups:
                return groups[value]
            return evaluate(definitions[value]) if value in definitions else {value}
        if value[0] == 'and':
            return set.intersection(*(evaluate(part) for part in value[1:]))
        if value[0] == 'not':
            return universe - set.union(*(evaluate(part) for part in value[1:]))
        return set.union(*(evaluate(part) for part in value))
    assertions = [rule for rule in rules if rule[0] == 'neverallow']
    for parent in universe:
        for target in universe:
            for permission in ('execute', 'execute_no_trans'):
                original = (parent in evaluate('sources') and target in evaluate('targets')) or (permission == 'execute' and parent in evaluate('sources2') and target in evaluate('targets2'))
                actual = any(parent in evaluate(rule[1]) and target in evaluate(rule[2]) and permission in rule[3][1] for rule in assertions)
                expected = original and (parent, target) != ('nativos_package', 'nativos_package_file')
                assert actual == expected, (parent, target, permission)
    assert 'nativos_package' not in groups['appdomain']
print('Package source guards passed: command arguments, safe seed symlink, scoped tracing/execution, no root/mount/JIT grants')
