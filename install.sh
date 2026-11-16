#!/bin/sh
# Plug&play entry point. Run once as root on the TV:
#   sh install.sh
DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
exec sh "$DIR/ota-killer.sh" install "$@"
