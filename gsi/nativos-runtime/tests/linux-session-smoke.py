#!/usr/bin/python3
"""Run inside the unprivileged Linux session, never as Android host root.

Checks real operations rather than counting running processes. Each failure is
reported independently. Temporary files are restricted to this user's home.
"""
import fcntl
import ctypes
import errno
import json
import mmap
import os
import pty
import select
import socket
import ssl
import struct
import tempfile
import termios
import tty
import urllib.request
from pathlib import Path


def run():
    if os.geteuid() == 0:
        raise SystemExit("Refusing root: test in the ordinary NativOS terminal")
    results = {}

    def check(name, action):
        try:
            results[name] = {"passed": True, "detail": action()}
        except Exception as error:
            results[name] = {"passed": False, "detail": str(error)}

    def privileges():
        status = Path("/proc/self/status").read_text()
        fields = dict(line.split(":", 1) for line in status.splitlines() if ":" in line)
        assert int(fields["CapEff"].strip(), 16) == 0, "effective capabilities present"
        assert fields["NoNewPrivs"].strip() == "1", "NoNewPrivs missing"
        return {"uid": os.getuid(), "capabilities": 0, "no_new_privileges": True}

    def files():
        # Explicit cleanup reports the actual rmdir error instead of shutil's
        # permission-retry recursion masking it as a recursion-depth failure.
        directory = Path(tempfile.mkdtemp(prefix=".nativos-smoke-", dir=Path.home()))
        first = directory / "first"
        second = directory / "second"
        parent = directory / "parent"
        child = directory / "child"
        renamed_child = directory / "renamed-child"
        moved_child = parent / "moved-child"
        link = directory / "link"
        renamed_link = directory / "renamed-link"
        try:
            first.write_text("atomic rename test\n")
            first.replace(second)
            assert second.read_text() == "atomic rename test\n"
            child.mkdir()
            child.rename(renamed_child)
            parent.mkdir()
            renamed_child.rename(moved_child)
            assert moved_child.is_dir(), "directory move failed"
            link.symlink_to("second")
            link.rename(renamed_link)
            assert renamed_link.read_text() == "atomic rename test\n"
            renamed_link.unlink()
            moved_child.rmdir()
            parent.rmdir()
            second.unlink()
        finally:
            link.unlink(missing_ok=True)
            renamed_link.unlink(missing_ok=True)
            first.unlink(missing_ok=True)
            second.unlink(missing_ok=True)
            for temporary in (moved_child, renamed_child, child, parent):
                if temporary.is_dir():
                    temporary.rmdir()
            directory.rmdir()
        return "files, folder rename/move, symlink rename, deletion"

    def no_session_jit():
        # Probe permission only: no machine code is written or executed.
        context = Path("/proc/self/attr/current").read_text().rstrip("\x00\n")
        assert ":nativos_session:" in context, f"run in ordinary session, got {context}"
        libc = ctypes.CDLL(None, use_errno=True)
        libc.mprotect.argtypes = (ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int)
        libc.mprotect.restype = ctypes.c_int
        memory = mmap.mmap(-1, mmap.PAGESIZE, flags=mmap.MAP_PRIVATE | mmap.MAP_ANONYMOUS,
                           prot=mmap.PROT_READ | mmap.PROT_WRITE)
        try:
            address = ctypes.addressof(ctypes.c_char.from_buffer(memory))
            result = libc.mprotect(address, mmap.PAGESIZE, mmap.PROT_READ | mmap.PROT_EXEC)
            error = ctypes.get_errno()
            if result == 0:
                libc.mprotect(address, mmap.PAGESIZE, mmap.PROT_READ | mmap.PROT_WRITE)
            assert result == -1 and error in (errno.EACCES, errno.EPERM), "ordinary session gained JIT permission"
        finally:
            memory.close()
        return "anonymous executable memory denied outside browser domain"

    def terminals():
        master, slave = pty.openpty()
        try:
            tty.setraw(slave)
            fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 100, 0, 0))
            os.write(slave, b"nativos-pty-ok")
            assert select.select([master], [], [], 2)[0], "PTY read timeout"
            assert os.read(master, 128) == b"nativos-pty-ok"
            return "allocate, termios, resize, read/write"
        finally:
            os.close(master)
            os.close(slave)

    def configs():
        required = ["/etc/bash.bashrc", "/etc/resolv.conf", "/etc/apt/sources.list.d/ubuntu.sources"]
        required.extend(str(path) for path in Path("/etc/apt/apt.conf.d").glob("*") if path.is_file())
        for name in required:
            with open(name, "rb") as config:
                config.read(1)
        return f"{len(required)} public configuration files readable"

    def tls():
        context = ssl.create_default_context()
        assert context.cert_store_stats()["x509_ca"] > 0, "no trusted CA certificates"
        assert context.check_hostname and context.verify_mode == ssl.CERT_REQUIRED
        return context.cert_store_stats()

    def dns():
        addresses = socket.getaddrinfo("archive.ubuntu.com", 443, type=socket.SOCK_STREAM)
        assert addresses, "no DNS answers"
        return "archive.ubuntu.com resolved"

    def https():
        with urllib.request.urlopen("https://archive.ubuntu.com/ubuntu/", timeout=10,
                                    context=ssl.create_default_context()) as response:
            assert response.status == 200, response.status
            response.read(128)
        return "HTTPS certificate and hostname verification passed"

    check("non_root_isolation", privileges)
    check("session_jit_boundary", no_session_jit)
    check("home_file_operations", files)
    check("terminal_operations", terminals)
    check("public_configuration", configs)
    check("tls_trust_store", tls)
    check("dns", dns)
    check("https", https)
    print(json.dumps(results, indent=2))
    return 0 if all(result["passed"] for result in results.values()) else 1


if __name__ == "__main__":
    raise SystemExit(run())
