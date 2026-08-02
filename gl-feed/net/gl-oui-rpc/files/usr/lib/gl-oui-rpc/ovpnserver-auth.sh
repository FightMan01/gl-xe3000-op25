#!/bin/sh
# openvpn auth-user-pass-verify script (via-env): $username/$password come
# from the connecting client. Exit 0 to accept, non-zero to reject.

[ -n "$username" ] && [ -n "$password" ] || exit 1

submitted_hash="$(printf %s "$password" | sha256sum | cut -d' ' -f1)"
matched=1

. /lib/functions.sh

check_user() {
	local section="$1" name hash
	config_get name "$section" username
	[ "$name" = "$username" ] || return 0
	config_get hash "$section" password_hash
	[ "$hash" = "$submitted_hash" ] && matched=0
}

config_load gl_ovpnserver
config_foreach check_user user

exit "$matched"
