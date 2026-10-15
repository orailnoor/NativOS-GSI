"""Host-only fail-closed checks; not a substitute for Android SELinux tests."""
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import time


binary = str(Path(sys.argv[1]).resolve())
base_env = dict(os.environ)
base_env.pop("ANDROID_SOCKET_nativos_runtime", None)

for invalid in ("", "-1", "2", "1048577", "3junk", "999999"):
    env = dict(base_env, ANDROID_SOCKET_nativos_runtime=invalid)
    result = subprocess.run([binary], env=env, timeout=3, check=False)
    assert result.returncode == 1, (invalid, result.returncode)

with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as wrong:
    env = dict(base_env, ANDROID_SOCKET_nativos_runtime=str(wrong.fileno()))
    result = subprocess.run([binary], env=env, pass_fds=(wrong.fileno(),),
                            timeout=3, check=False)
    assert result.returncode == 1, result.returncode

with tempfile.TemporaryDirectory(prefix="nativos-socket-test-") as directory:
    path = os.path.join(directory, "runtime")
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
        listener.bind(path)
        listener.listen(8)
        env = dict(base_env, ANDROID_SOCKET_nativos_runtime=str(listener.fileno()))
        process = subprocess.Popen([binary], env=env, pass_fds=(listener.fileno(),))
        try:
            # No input is needed for rejection. Authentication must precede parsing.
            # This host peer is intentionally not an authorized Android app.
            for _ in range(16):
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                    client.settimeout(3)
                    client.connect(path)
                    reply = b""
                    while not reply.endswith(b"\n"):
                        chunk = client.recv(64)
                        assert chunk, reply
                        reply += chunk
                        assert len(reply) <= 64, reply
                    assert reply == b"ERR UNAUTHORIZED\n", reply
                    assert client.recv(1) == b""
            assert process.poll() is None, process.returncode
            start = time.monotonic()
            process.send_signal(signal.SIGTERM)
            assert process.wait(timeout=3) == 0
            assert time.monotonic() - start < 3
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=3)

print("Socket tests passed: invalid descriptors, wrong socket type, unauthorized peers, shutdown")
