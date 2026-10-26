#!/bin/sh
# Runs uci-defaults checks inside a stock OpenWrt rootfs (docker, no network).
#
#   tests/sandbox-uci-defaults.sh <openwrt-25.12.x-x86-64-rootfs.tar.gz>
#
# The rootfs comes from downloads.openwrt.org (check its sha256sums). Each
# case starts from a fresh container, so nothing leaks between them.
# FEED=<dir> runs the cases against another checkout's gl-feed/net (e.g. an
# older commit, to see that a case fails without its fix).
set -eu

ROOTFS="$1"
HERE="$(cd "$(dirname "$0")" && pwd)"
FEED="${FEED:-$(dirname "$HERE")/gl-feed/net}"
IMAGE=gl-uci-defaults-test:$(shasum -a 256 "$ROOTFS" | cut -c1-12)

docker image inspect "$IMAGE" >/dev/null 2>&1 ||
	docker import --platform linux/amd64 "$ROOTFS" "$IMAGE" >/dev/null

run() {	# run <case script>: prints its output, fails on a non-zero exit
	docker run --rm --platform linux/amd64 --network none \
		-v "$FEED:/feed:ro" -v "$HERE/sandbox:/cases:ro" \
		"$IMAGE" /bin/sh -c "mkdir -p /var/lock /tmp/run; $1"
}

fail=0
for c in "$HERE"/sandbox/*.sh; do
	name="$(basename "$c")"
	if out="$(run "sh /cases/$name" 2>&1)"; then
		echo "ok   $name"
	else
		echo "FAIL $name"
		echo "$out" | sed 's/^/     /'
		fail=1
	fi
done
exit "$fail"
