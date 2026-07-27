#!/bin/sh
# Run this ON THE ROUTER, while it's still on GL.iNet's stock firmware -
# scp it over and run it via ssh, or just paste it into an ssh session.
# It packages up the GL frontend files into a tarball you copy off the
# router before flashing this port, then upload back through the
# restore page once it's running the new firmware.
#
#   scp tools/backup-gl-ui.sh root@192.168.8.1:/tmp/
#   ssh root@192.168.8.1 /tmp/backup-gl-ui.sh
#   scp root@192.168.8.1:/tmp/gl-ui-backup.tar.gz .

set -e
OUT="/tmp/gl-ui-backup.tar.gz"

if [ ! -d /www ] || [ ! -d /usr/share/oui/menu.d ]; then
	echo "Expected /www and /usr/share/oui/menu.d - is this a GL.iNet router?" >&2
	exit 1
fi

tar -czf "$OUT" -C / www usr/share/oui/menu.d
echo "Saved $OUT"
echo "Copy it off before flashing:  scp root@<router-ip>:$OUT ."
