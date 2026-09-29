#!/bin/sh
# Base-image entrypoint for the node container.
#
# The node container is a base image: Node apps are bind-mounted from /var/www
# and the real command is set per-app in compose.yaml. This entrypoint makes the
# default behaviour safe — it runs /var/www/server.js when one is present, and
# otherwise idles so the container stays up instead of crash-looping on
# `node server.js` with nothing mounted (which previously pegged the host CPU
# via restart: unless-stopped).

set -eu

if [ -f /var/www/server.js ]; then
  echo "==> node: found /var/www/server.js — starting it"
  exec node /var/www/server.js "$@"
fi

echo "==> node: no /var/www/server.js — no app deployed yet, idling"
exec tail -f /dev/null