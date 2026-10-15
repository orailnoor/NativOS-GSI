"""Pure lock-selection regression; no device/user package storage touched."""
import importlib.util
from pathlib import Path
spec = importlib.util.spec_from_file_location('manager', Path(__file__).with_name('nativos-packages.py'))
manager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(manager)
cases = [('update', [], True), ('tool', ['apt', 'update'], True),
         ('tool', ['apt-get', 'update'], True), ('tool', ['apt-cache', 'policy', 'vim'], True),
         ('run', ['/usr/bin/localsend_app'], True), ('install', ['vim'], False),
         ('tool', ['apt', 'install', 'vim'], False), ('tool', ['apt', 'upgrade'], False),
         ('tool', ['apt', '-o', 'APT::Update::Post-Invoke=foo', 'update'], False),
         ('tool', ['dpkg', '--configure', '-a'], False), ('repair', [], False),
         ('shell', [], False), ('tool', ['apt-cache', 'gencaches'], False)]
for operation, arguments, expected in cases:
    assert bool(manager.shared_transaction(operation, arguments, True)) == expected
    assert not manager.shared_transaction(operation, arguments, False)
print('Transaction lock regression passed:', len(cases) * 2, 'cases')
