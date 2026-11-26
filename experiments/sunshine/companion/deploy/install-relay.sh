#!/bin/sh
set -eu
umask 077
if [ "$(id -u)" = 0 ]; then echo "Use an ordinary service account; UDP 23388 needs no root." >&2; exit 2; fi
case "${1:-1800}" in 1800|8000) cap=${1:-1800};; *) echo "Expected 1800 or 8000" >&2; exit 2;; esac
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
app="$HOME/.local/share/sesame-stream-relay"
unit="$HOME/.config/systemd/user"
mkdir -p "$app" "$unit"
for name in udp_broker.py relay_service.py; do
    install -m 600 "$here/$name" "$app/$name.new"
    mv -- "$app/$name.new" "$app/$name"
done
sed "s/@CAP@/$cap/g" "$here/sesame-stream-relay.service.in" > "$unit/sesame-stream-relay.service.new"
mv -- "$unit/sesame-stream-relay.service.new" "$unit/sesame-stream-relay.service"
echo "Installed files only. No service started, firewall changed or ticket overwritten."
