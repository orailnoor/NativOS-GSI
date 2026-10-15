#!/system/bin/sh
set -eu
probe=/data/local/tmp/nativos-session-20261004
if [ ! -e "$probe" ] && [ ! -L "$probe" ]; then
    umask 022
    mkdir -m 0755 "$probe" "$probe/v16" "$probe/session" "$probe/display" "$probe/homes"
    mkdir -m 0700 "$probe/homes/10176"
    chown 10176:10176 "$probe/homes/10176"
fi
for path in "$probe" "$probe/v16" "$probe/session" "$probe/display" "$probe/homes"; do
    [ ! -L "$path" ] && [ "$(stat -c %u "$path")" = 0 ] || exit 90
done
mount -t ext4 -o ro,noload /dev/block/mapper/system_a "$probe/v16"
trap 'umount "$probe/v16"' EXIT
set +e
timeout -s TERM 25 /data/local/tmp/nativos-session-probe-arm64 10176
result=$?
set -e
printf '\nSession probe exit: %s\n' "$result"
exit "$result"
