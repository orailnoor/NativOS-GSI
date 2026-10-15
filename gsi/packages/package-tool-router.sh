#!/bin/sh
# Ordinary app UID only; route the named package tool into the private guest.
tool="${0##*/}"
case "$tool" in apt|apt-get|apt-cache|dpkg) ;; *) exit 2 ;; esac
exec /usr/local/bin/nativos-packages tool "$tool" "$@"
