import hashlib, importlib.util, tempfile
from pathlib import Path
directory = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('manager', directory / 'nativos-packages.py')
manager = importlib.util.module_from_spec(spec); spec.loader.exec_module(manager)
manager.GUEST_AUDIT_SOURCE = directory / 'libnativos-guest-audit.so'
assert hashlib.sha256(manager.GUEST_AUDIT_SOURCE.read_bytes()).hexdigest() == manager.GUEST_AUDIT_SHA256
with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary); (root / 'etc').mkdir(); (root / 'usr/local/lib').mkdir(parents=True)
    assert manager.guest_compat_needed(root)
    manager.install_guest_compat(root)
    assert not manager.guest_compat_needed(root)
    before = (root / 'etc/ld.so.preload').read_bytes()
    manager.install_guest_compat(root)
    assert (root / 'etc/ld.so.preload').read_bytes() == before
    (root / 'etc/ld.so.preload').unlink(); (root / 'etc/ld.so.preload').symlink_to('/etc/passwd')
    try: manager.guest_compat_needed(root)
    except RuntimeError: pass
    else: raise AssertionError('symlink preload accepted')
print('Guest compatibility tests passed: pinned ARM64 asset, setup, idempotence, symlink rejection')
