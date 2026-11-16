#!/bin/sh
# Fully reversible: removes the payload hook, unmounts /etc/hosts, deletes the
# iptables rules it added, removes the deny-version file, and deletes /conf/ota-killer.
DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
exec sh "$DIR/ota-killer.sh" uninstall "$@"
