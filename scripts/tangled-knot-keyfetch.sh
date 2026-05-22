#!/bin/sh
# AuthorizedKeysCommand for the knot's git user. Asks the running knot
# which SSH keys may authenticate as whoever is connecting. Installed to
# /etc/ssh/tangled-knot-keyfetch (mode 0555). From the upstream NixOS
# knot module. See infrastructure#280.
exec /opt/tangled-knot/current/bin/knot keys \
  -output authorized-keys \
  -internal-api "http://127.0.0.1:5444" \
  -git-dir "/var/lib/tangled-knot/repos" \
  -log-path /tmp/knotguard.log
