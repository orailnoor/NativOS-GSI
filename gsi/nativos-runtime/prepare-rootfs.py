"""Build-host rootfs preparation. Never executes anything from the archive.

Run as WSL root, with archive, pinned SHA256, and a NEW output directory.
Uses tarfile's data extraction filter and converts container-absolute symlinks
to equivalent within-tree relative links. A failed output must not be shipped.
"""
import hashlib
import os
from pathlib import Path, PurePosixPath
import posixpath
import sys
import tarfile


def digest(stream):
    stream.seek(0)
    result = hashlib.file_digest(stream, "sha256").hexdigest()
    stream.seek(0)
    return result


def container_filter(member, destination):
    path = PurePosixPath(member.name)
    if path.is_absolute() or ".." in path.parts:
        raise ValueError(f"Invalid archive path: {member.name}")
    if member.issym() and member.linkname.startswith("/"):
        member = member.replace(linkname=posixpath.relpath(
            member.linkname.lstrip("/") or ".", str(path.parent)), deep=True)
    return tarfile.data_filter(member, destination)


def main():
    archive, expected, output = sys.argv[1:]
    if os.geteuid() != 0:
        raise SystemExit("Run as WSL root to create root-owned system assets")
    if len(expected) != 64 or any(c not in "0123456789abcdef" for c in expected):
        raise SystemExit("Expected SHA256 must be 64 lowercase hex digits")
    root = Path(output)
    if root.exists() or root.is_symlink():
        raise SystemExit("Output must not already exist")
    with open(archive, "rb") as source:
        if digest(source) != expected:
            raise SystemExit("Rootfs checksum mismatch")
        root.mkdir(mode=0o755)
        with tarfile.open(fileobj=source, mode="r:gz") as bundle:
            members = bundle.getmembers()
            if sum(m.size for m in members) > 4 * 1024**3:
                raise SystemExit("Rootfs exceeds the 4 GiB build limit")
            bundle.extractall(root, members=members, filter=container_filter)
        if digest(source) != expected:
            raise SystemExit("Archive changed during extraction")
    for executable in ("usr/bin/phoc", "usr/libexec/phosh", "usr/bin/dbus-run-session"):
        path = root / executable
        if not path.is_file() or not os.access(path, os.X_OK):
            raise SystemExit(f"Missing desktop executable: {executable}")
    for name in ("proc", "dev", "run", "tmp", "home"):
        path = root / name
        if path.is_symlink():
            raise SystemExit(f"Mount target cannot be a symlink: {name}")
        path.mkdir(mode=0o755, exist_ok=True)
        path.chmod(0o755)
    # The build must require this final marker; partial extraction has none.
    (root / ".nativos-source-sha256").write_text(expected + "\n", encoding="ascii")
    print(f"Prepared root-owned Linux tree: {root}")


if __name__ == "__main__":
    main()
