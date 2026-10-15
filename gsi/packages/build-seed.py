#!/usr/bin/python3
"""Build an extraction-safe distribution seed, retaining internal symlinks."""
import os
from pathlib import Path
import sys
import tarfile

source = Path(sys.argv[1]).resolve(strict=True)
destination = Path(sys.argv[2])
if destination.exists():
    raise SystemExit('Refusing to overwrite seed')


def prepare(member):
    name = member.name.removeprefix('./').strip('/')
    if any(name.startswith(area + '/') for area in ('dev', 'proc', 'run', 'tmp', 'root', 'home')):
        return None
    if name == 'usr/lib/firefox' or name.startswith('usr/lib/firefox/'):
        return None
    if name in ('usr/local/bin/firefox', 'usr/share/applications/org.mozilla.firefox.desktop'):
        return None
    if name.startswith('var/cache/apt/archives/') and name.endswith('.deb'):
        return None
    if not (member.isdir() or member.isfile() or member.issym() or member.islnk()):
        return None
    member.uid = member.gid = 0
    member.uname = member.gname = ''
    member.mode &= ~0o6000
    if member.issym() and member.linkname.startswith('/'):
        member.linkname = os.path.relpath(member.linkname.lstrip('/'), os.path.dirname(name) or '.')
    return member


with tarfile.open(destination, 'x:gz') as archive:
    archive.add(source, arcname='.', filter=prepare)
