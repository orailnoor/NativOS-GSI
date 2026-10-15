#!/usr/bin/python3
"""Experimental per-user package environment. Never run as real root."""
import fcntl
import configparser
import hashlib
import json
import os
import re
from pathlib import Path
import shutil
import shlex
import stat
import subprocess
import sys
import tarfile
import tempfile

AREA = Path('/var/lib/nativos-packages')
SEED = Path('/usr/local/share/nativos-packages/seed.tar.gz')
MANIFEST = Path('/usr/local/share/nativos-packages/manifest.json')
PROOT = '/usr/local/libexec/nativos-proot'
PACKAGE_PATH = '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
GUEST_AUDIT_SOURCE = Path('/usr/local/share/nativos-packages/libnativos-guest-audit.so')
GUEST_AUDIT_SHA256 = '0247dcbbb1ad9a97d6fcbb288ea21ec1198dcf40c3c269b1a67150f4d78bc9b8'
GUEST_AUDIT_PATH = '/usr/local/lib/nativos/libnativos-guest-audit.so'


def guest_compat_needed(root):
    if not GUEST_AUDIT_SOURCE.exists():
        return False  # Backwards-compatible with older images lacking the asset.
    if root.is_symlink():
        raise RuntimeError('refusing symlink package root')
    library = root / GUEST_AUDIT_PATH.lstrip('/')
    preload = root / 'etc/ld.so.preload'
    if library.is_symlink() or preload.is_symlink():
        raise RuntimeError('refusing symlink guest compatibility files')
    return (not library.is_file() or hashlib.sha256(library.read_bytes()).hexdigest() != GUEST_AUDIT_SHA256
            or not preload.is_file() or GUEST_AUDIT_PATH not in preload.read_text().split())


def install_guest_compat(root):
    # Caller MUST hold the exclusive transaction lock; never update mapped code
    # while package applications have shared locks. Android audit is untouched.
    if not guest_compat_needed(root):
        return
    payload = GUEST_AUDIT_SOURCE.read_bytes()
    if hashlib.sha256(payload).hexdigest() != GUEST_AUDIT_SHA256:
        raise RuntimeError('immutable guest audit compatibility checksum mismatch')
    folder = root / 'usr/local/lib/nativos'
    folder.mkdir(mode=0o755, exist_ok=True)
    if not folder.resolve().is_relative_to(root.resolve()):
        raise RuntimeError('guest compatibility directory escapes package root')
    library = root / GUEST_AUDIT_PATH.lstrip('/')
    preload = root / 'etc/ld.so.preload'
    if not preload.parent.resolve().is_relative_to(root.resolve()):
        raise RuntimeError('guest loader configuration escapes package root')
    previous_preload = preload.read_text() if preload.exists() else ''
    new_preload = previous_preload if GUEST_AUDIT_PATH in previous_preload.split() else previous_preload + '\n' + GUEST_AUDIT_PATH + '\n'
    for destination, data, mode in (
        (library, payload, 0o755),
        (preload, new_preload.encode(), 0o644)):
        if destination.exists():
            backup_fd, backup_name = tempfile.mkstemp(prefix=destination.name + '.before-nativos-', dir=destination.parent)
            with os.fdopen(backup_fd, 'wb') as backup:
                backup.write(destination.read_bytes())
        descriptor, name = tempfile.mkstemp(prefix='.nativos-compat-', dir=destination.parent)
        with os.fdopen(descriptor, 'wb') as output:
            output.write(data)
            os.fchmod(output.fileno(), mode)
        os.replace(name, destination)

def session_bus_binding(address):
    if not address.startswith('unix:path=/tmp/'):
        return None  # /run/user is already bridged; abstract sockets need no path.
    match = re.fullmatch(r'unix:path=(/tmp/dbus-[A-Za-z0-9_-]+)(?:,guid=[a-fA-F0-9]+)?', address)
    if not match:
        raise RuntimeError('unsupported temporary session-bus address')
    return match.group(1)
def verify_worker():
    manifest = json.loads(Path('/usr/local/share/nativos-packages/worker-manifest.json').read_text())
    if manifest['revision'] != '25dc6a3134891f98a79f57ce1c2c1b23ff15cad1':
        raise RuntimeError('unsupported worker source revision')
    if hashlib.sha256(Path(PROOT).read_bytes()).hexdigest() != manifest['proot_sha256']:
        raise RuntimeError('immutable worker checksum mismatch')


def checked_area():
    info = AREA.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise RuntimeError('package storage must be a private directory owned by this user')
    status = dict(line.split(':', 1) for line in Path('/proc/self/status').read_text().splitlines() if ':' in line)
    if os.geteuid() == 0 or any(int(status[name], 16) for name in ('CapEff', 'CapPrm', 'CapInh', 'CapBnd', 'CapAmb')) or status['NoNewPrivs'].strip() != '1':
        raise RuntimeError('refusing privileged package execution')


def initialize():
    checked_area()
    root = AREA / 'root'
    manifest = json.loads(MANIFEST.read_text())
    if root.exists() or root.is_symlink():
        if root.is_symlink() or not root.is_dir() or root.stat().st_uid != os.getuid():
            raise RuntimeError('invalid package root')
        if (root / '.nativos-package-seed').read_text().strip() != manifest['seed_sha256']:
            raise RuntimeError('package seed changed; migration required, refusing destructive reset')
        return root
    if shutil.disk_usage(AREA).free < 3 * 1024**3:
        raise RuntimeError('at least 3 GiB free storage is required')
    with SEED.open('rb') as source:
        digest = hashlib.file_digest(source, 'sha256').hexdigest()
    if digest != manifest['seed_sha256']:
        raise RuntimeError('immutable seed checksum mismatch')
    stage = Path(tempfile.mkdtemp(prefix='.initializing-', dir=AREA))
    # Seed is build-generated and AVB-covered. Still reject escapes/special files
    # and bound expansion. Failed stages are preserved for diagnosis, not erased.
    with tarfile.open(SEED, 'r:gz') as archive:
        members = archive.getmembers()
        if len(members) > 100000 or sum(member.size for member in members) > 3 * 1024**3:
            raise RuntimeError('seed expansion limit exceeded')
        if any(not (member.isdir() or member.isfile() or member.issym() or member.islnk()) for member in members):
            raise RuntimeError('special file in seed')
        archive.extractall(stage, filter='data')
    for directory, _, files in os.walk(stage, followlinks=False):
        os.chmod(directory, stat.S_IMODE(os.stat(directory).st_mode) | 0o700)
        for name in files:
            item = Path(directory) / name
            if not item.is_symlink():
                os.chmod(item, (stat.S_IMODE(item.stat().st_mode) & ~0o6000) | 0o600)
    (stage / '.nativos-package-seed').write_text(digest + '\n')
    for name in ('home/nativos', 'run/user/' + str(os.getuid()), 'dev/pts', 'dev/shm'):
        (stage / name).mkdir(mode=0o700, parents=True, exist_ok=True)
    for name in ('null', 'zero', 'random', 'urandom', 'ptmx'):
        (stage / 'dev' / name).touch(mode=0o600)
    for filename, identity in (
        ('passwd', f'nativos:x:{os.getuid()}:{os.getgid()}:NativOS:/home/nativos:/bin/bash'),
        ('group', f'nativos:x:{os.getgid()}:')):
        path = stage / 'etc' / filename
        lines = [line for line in path.read_text().splitlines() if line.split(':', 1)[0] != 'nativos']
        path.write_text('\n'.join(lines + [identity]) + '\n')
    os.rename(stage, root)
    print('Writable package environment initialized; immutable desktop untouched.', flush=True)
    return root


def command_arguments(operation, arguments):
    options = ['-o', 'Dpkg::Use-Pty=0', '-o', 'Acquire::Retries=1',
               '-o', 'Acquire::http::Timeout=30', '-o', 'Acquire::https::Timeout=30']
    if operation == 'tool' and arguments and arguments[0] in ('apt', 'apt-get', 'apt-cache', 'dpkg'):
        # Execute package tools only inside the existing private writable guest.
        # No real UID/capability change or host-root filesystem binding.
        return ['/usr/bin/' + arguments[0], *arguments[1:]]
    if operation == 'update' and not arguments:
        return ['/usr/bin/apt-get', *options, 'update']
    if operation in ('install', 'remove') and arguments and all(not arg.startswith('-') for arg in arguments):
        return ['/usr/bin/apt-get', *options, operation, '--', *arguments]
    if operation == 'repair' and not arguments:
        return ['/usr/bin/dpkg', '--configure', '-a']
    if operation == 'shell' and not arguments:
        return ['/bin/bash', '--noprofile', '--norc']
    if operation == 'run' and arguments and arguments[0].startswith('/usr/bin/') and '..' not in arguments[0].split('/'):
        return arguments
    raise ValueError('Usage: nativos-packages init|update|install PACKAGE|install /home/nativos/FILE.deb|remove PACKAGE|repair|shell|run /usr/bin/APP [ARGS]')


def desktop_arguments(text):
    arguments = shlex.split(text)
    if arguments and re.fullmatch(r'[A-Za-z0-9_.+-]+', arguments[0]):
        arguments[0] = '/usr/bin/' + arguments[0]
    if not arguments or not arguments[0].startswith('/usr/bin/') or '..' in arguments[0].split('/'):
        raise ValueError('only absolute /usr/bin application launchers are exported')
    # File/URL placeholders require a future reviewed document hand-off bridge.
    arguments = [arg for arg in arguments if arg not in ('%f', '%F', '%u', '%U')]
    if any('%' in arg or any(character in arg for character in '\r\n\x00') for arg in arguments):
        raise ValueError('unsupported desktop field code or control character')
    return arguments


def exported_icon(root, value):
    """Copy an app's packaged icon into user storage, never a guest-only path."""
    if not value or any(c in value for c in '\r\n\x00'):
        return 'application-x-executable'
    candidates = []
    if value.startswith('/'):
        candidates = [root / value.lstrip('/')]
    elif re.fullmatch(r'[A-Za-z0-9_.+-]+', value):
        for base in (root / 'usr/share/icons/hicolor', root / 'usr/share/pixmaps'):
            if base.is_dir():
                candidates.extend(p for p in base.rglob('*')
                                  if p.name == value or p.stem == value)
        candidates.sort(key=lambda p: ('scalable' not in p.parts, '256x256' not in p.parts,
                                       '128x128' not in p.parts, str(p)))
    for source in candidates:
        try:
            resolved = source.resolve(strict=True)
            if not resolved.is_relative_to(root.resolve()) or resolved.suffix.lower() not in ('.svg', '.png', '.xpm'):
                continue
            if not resolved.is_file() or resolved.stat().st_size > 2 * 1024 * 1024:
                continue
            payload = resolved.read_bytes()
            destination = Path.home() / '.local/share/icons/nativos-packages'
            destination.mkdir(parents=True, exist_ok=True)
            target = destination / (hashlib.sha256(payload).hexdigest() + resolved.suffix.lower())
            descriptor = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
            with os.fdopen(descriptor, 'wb') as output:
                output.write(payload)
            return str(target)
        except OSError:
            continue
    # Core theme can resolve a valid named icon even when the guest has no copy.
    return value if re.fullmatch(r'[A-Za-z0-9_.+-]+', value) else 'application-x-executable'


def export_launchers(root):
    destination = Path.home() / '.local/share/applications'
    destination.mkdir(parents=True, exist_ok=True)
    exported = set()
    for source in (root / 'usr/share/applications').glob('*.desktop'):
        parser = configparser.ConfigParser(interpolation=None, strict=False)
        try:
            parser.read_string(source.read_text())
            entry = parser['Desktop Entry']
            if entry.get('Type') != 'Application' or entry.get('Hidden', '').lower() == 'true' or entry.get('NoDisplay', '').lower() == 'true':
                continue
            arguments = desktop_arguments(entry['Exec'])
            if arguments == ['/usr/bin/localsend_app']:
                arguments = ['/usr/bin/env', 'LIBGL_ALWAYS_SOFTWARE=1', 'GALLIUM_DRIVER=softpipe',
                             'MESA_LOADER_DRIVER_OVERRIDE=swrast', 'XCURSOR_THEME=Adwaita',
                             'XCURSOR_SIZE=24', 'GDK_BACKEND=wayland', *arguments]
            terminal = entry.get('Terminal', 'false').lower()
            if terminal not in ('true', 'false'):
                raise ValueError('invalid Terminal setting')
            name = entry.get('Name', source.stem).replace('\n', ' ').replace('\r', ' ')
            identifier = hashlib.sha256(source.name.encode()).hexdigest()[:24]
            target = destination / ('nativos-pkg-' + identifier + '.desktop')
            # Desktop Exec has double-quote escaping, not shell single-quote syntax.
            quoted = ['"' + argument.replace('\\', '\\\\').replace('"', '\\"').replace('`', '\\`').replace('$', '\\$') + '"' for argument in arguments]
            icon = exported_icon(root, entry.get('Icon', ''))
            content = '[Desktop Entry]\nType=Application\nName=' + name + '\nIcon=' + icon + '\nExec=/usr/local/bin/nativos-packages run ' + ' '.join(quoted) + '\nTerminal=' + terminal + '\nX-NativOS-Package-Source=' + source.name + '\n'
            # Keep the original desktop ID for Wayland app-id/task icon matching.
            # Immutable core apps win; never show a duplicate guest seed launcher.
            core_app = Path('/usr/share/applications') / source.name
            if not core_app.exists():
                alias = destination / source.name
                if alias.is_symlink():
                    raise ValueError('refusing symlink app-ID alias')
                if alias.exists():
                    previous = configparser.ConfigParser(interpolation=None, strict=False)
                    previous.read(alias)
                    if not previous['Desktop Entry'].get('Exec', '').startswith('/usr/local/bin/nativos-packages run '):
                        raise ValueError('preserving unrelated user launcher with this app ID')
                descriptor = os.open(alias, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
                with os.fdopen(descriptor, 'w') as output:
                    output.write(content)
            content += 'Hidden=true\n'
            descriptor = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
            with os.fdopen(descriptor, 'w') as output:
                output.write(content)
            exported.add(target.name)
        except (OSError, ValueError, KeyError, configparser.Error) as error:
            print('Skipped launcher ' + source.name + ': ' + str(error), file=sys.stderr)
    # Do not delete any pre-existing launcher. Removal reconciliation is pending.
    print(str(len(exported)) + ' package launchers exported; absolute /usr/bin paths only.', flush=True)


def shared_transaction(operation, arguments, initialized):
    metadata_update = (operation == 'update' and not arguments) or (
        operation == 'tool' and arguments in (['apt', 'update'], ['apt-get', 'update']))
    cache_query = operation == 'tool' and len(arguments) >= 2 and arguments[0] == 'apt-cache' and arguments[1] in ('policy', 'show', 'search', 'depends', 'rdepends', 'stats', 'pkgnames', 'madison')
    return initialized and (operation == 'run' or metadata_update or cache_query)


def main():
    checked_area()
    operation = sys.argv[1] if len(sys.argv) > 1 else 'shell'
    # O_NOFOLLOW also prevents a user-controlled symlink lock from being opened.
    descriptor = os.open(AREA / '.transaction.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, 'w') as lock:
        package_root = AREA / 'root'
        read_only_launch = shared_transaction(operation, sys.argv[2:], package_root.is_dir()) and not guest_compat_needed(package_root)
        # Refreshing repository lists does not replace installed app files. APT's
        # own lists lock serializes refreshes; installs/upgrades remain exclusive.
        try:
            fcntl.flock(lock, (fcntl.LOCK_SH if read_only_launch else fcntl.LOCK_EX) | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError('Package environment is busy. Close package-installed Linux apps before installing/upgrading; wait for any other package transaction. No lock files were removed.')
        root = initialize()
        if not read_only_launch:
            install_guest_compat(root)
        if operation == 'run' and not read_only_launch:
            fcntl.flock(lock, fcntl.LOCK_SH)
        if operation == 'init' and len(sys.argv) == 2:
            return 0
        if operation == 'export' and len(sys.argv) == 2:
            export_launchers(root)
            return 0
        command = command_arguments(operation, sys.argv[2:])
        cache = AREA / 'trace-tmp'
        verify_worker()
        cache.mkdir(mode=0o700, exist_ok=True)
        if cache.is_symlink() or cache.stat().st_uid != os.getuid():
            raise RuntimeError('invalid tracing temporary directory')
        env = {key: value for key, value in os.environ.items() if key in (
            'LANG', 'TERM', 'WAYLAND_DISPLAY', 'XDG_RUNTIME_DIR', 'DBUS_SESSION_BUS_ADDRESS')}
        env.update(PATH=PACKAGE_PATH, HOME='/home/nativos', USER='nativos', LOGNAME='nativos',
                   PROOT_TMP_DIR=str(cache), GDK_BACKEND='wayland', GSK_RENDERER='cairo')
        env.setdefault('WAYLAND_DISPLAY', 'wayland-0')
        # No Android /dev, /sys, block device, host-rootfs or QEMU exposure.
        identity = ['-i', str(os.getuid()) + ':' + str(os.getgid())] if operation == 'run' else ['-0']
        argv = [PROOT, *identity, '-r', str(root), '-w', '/home/nativos']
        for path in ('/dev/null', '/dev/zero', '/dev/random', '/dev/urandom', '/dev/pts',
                     '/dev/ptmx', '/dev/shm', '/proc', '/run/user/' + str(os.getuid()), '/home/nativos'):
            argv += ['-b', path]
        bus = session_bus_binding(env.get('DBUS_SESSION_BUS_ADDRESS', ''))
        if bus is not None:
            info = os.lstat(bus)
            if not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.getuid():
                raise RuntimeError('session-bus bridge must be this user\'s actual socket')
            # Exact session socket only. Never expose the whole core /tmp tree.
            argv += ['-b', bus]
        # Fake guest UID0 supports dpkg, but actual UID/capabilities never change.
        # These apps share this user's environment/home; this is not per-app isolation.
        result = subprocess.call(argv + command, env=env)
        if result == 0 and (operation in ('install', 'remove') or
                           (operation == 'tool' and command[0] in ('/usr/bin/apt', '/usr/bin/apt-get', '/usr/bin/dpkg'))):
            export_launchers(root)
        return result


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, ValueError) as error:
        print('NativOS packages: ' + str(error), file=sys.stderr)
        raise SystemExit(1)
