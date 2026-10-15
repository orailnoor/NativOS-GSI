#!/usr/bin/python3
"""Test real seed extraction under an unprivileged host identity."""
import importlib.util
from pathlib import Path
import os
import sys
import tempfile

directory = Path(__file__).resolve().parent
candidate = Path(sys.argv[1]).resolve(strict=True)
assert str(candidate).startswith('/var/tmp/nativos-linux-packages.')
spec = importlib.util.spec_from_file_location('packages', directory / 'nativos-packages.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
module.AREA = Path(tempfile.mkdtemp(prefix='nativos-seed-test-'))
module.SEED = candidate / 'usr/local/share/nativos-packages/seed.tar.gz'
module.MANIFEST = candidate / 'usr/local/share/nativos-packages/manifest.json'
root = module.initialize()
assert root == module.initialize(), 'repeat initialization changed root'
assert (root / 'usr/bin/apt-get').is_file()
assert (root / 'var/lib/dpkg/status').is_file()
assert (root / 'bin/sh').is_file(), 'usrmerge links lost'
assert not (root / 'usr/lib/firefox').exists()
for directory, _, files in os.walk(root, followlinks=False):
    assert Path(directory).stat().st_uid == os.getuid()
    for name in files:
        item = Path(directory) / name
        if not item.is_symlink():
            assert item.stat().st_uid == os.getuid()
            assert not item.stat().st_mode & 0o6000
print('Seed extraction passed as real UID', os.getuid(), 'at', module.AREA,
      '; repeat initialization, usrmerge, APT DB, no privileged modes; retained for inspection')
