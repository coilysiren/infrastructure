#!/bin/sh
# AuthorizedKeysCommand for the knot's git user: asks the running knot which keys may
# authenticate. Installed to /etc/ssh/tangled-knot-keyfetch 0555. See infrastructure#280.
exec /opt/tangled-knot/current/bin/knot keys \
  -output authorized-keys \
  -internal-api "http://127.0.0.1:5444" \
  -git-dir "/var/lib/tangled-knot/repos" \
  -log-path /tmp/knotguard.log
