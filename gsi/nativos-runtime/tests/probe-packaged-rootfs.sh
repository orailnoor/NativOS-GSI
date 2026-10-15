#!/system/bin/sh
# Run with probe_mount_namespace; inspect inactive system_a read-only.
# Executes ELF dependency listing only; does not launch desktop programs.
set -eu
probe=/data/local/tmp/nativos-packaged-probe-20261003
[ ! -e "$probe" ] && [ ! -L "$probe" ] || exit 90
umask 077
mkdir "$probe"
chmod 0755 "$probe"
mounted=0
tmp_mounted=0
socket_mounted=0
cleanup() {
    if [ "$socket_mounted" = 1 ]; then umount "$root/tmp/.X11-unix" || return; fi
    if [ "$tmp_mounted" = 1 ]; then umount "$root/tmp" || return; fi
    if [ "$mounted" = 1 ]; then umount "$probe" || return; fi
    rmdir "$probe"
}
trap cleanup EXIT
mount -t ext4 -o ro,noload /dev/block/mapper/system_a "$probe"
mounted=1
root="$probe/system/etc/nativos/linux"
[ -d "$root" ] || exit 91
loader=/usr/lib/aarch64-linux-gnu/ld-linux-aarch64.so.1
for program in /usr/bin/dbus-run-session /usr/bin/phoc /usr/libexec/phosh; do
    printf '\nChecking packaged ELF dependencies as app UID: %s\n' "$program"
    chroot "$root" /usr/bin/setpriv --reuid=10176 --regid=10176 \
        --clear-groups --no-new-privs "$loader" --list "$program"
done
mount -t tmpfs -o mode=1777,size=8m tmpfs "$root/tmp"
tmp_mounted=1
mkdir "$root/tmp/.X11-unix"
mount -o bind /data/user/0/com.nativOS/files/tmp/.X11-unix "$root/tmp/.X11-unix"
socket_mounted=1
printf '\nChecking X11 handshake from packaged Python as app UID\n'
chroot "$root" /usr/bin/setpriv --reuid=10176 --regid=10176 \
    --clear-groups --no-new-privs /usr/bin/python3 -c '
import socket, struct, os
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(3)
s.connect("/tmp/.X11-unix/X0")
s.sendall(struct.pack("<BBHHHHH", 108, 0, 11, 0, 0, 0, 0))
reply = b""
while len(reply) < 8:
    part = s.recv(8-len(reply))
    if not part:
        raise RuntimeError("X11 server closed setup connection")
    reply += part
assert reply[0] == 1, ("X11 setup rejected", reply)
print("X11 protocol 11 handshake succeeded; uid=", os.getuid())
s.close()
'
