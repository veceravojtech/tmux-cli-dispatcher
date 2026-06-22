#!/usr/bin/env bash
# Reusable pre-dispatch gate: exit 0 only when this host can actually reach the
# resource a lane needs to do its work. Used by dispatcher.sh's per-lane gate
# (`$WORKER_HOME/gate-<lane>.sh`) for projects that live behind the Previo VPN —
# so the dispatcher holds the queue while the tunnel is down instead of consuming
# tasks it cannot build/test/push.
#
# We probe REACHABILITY of the git host (the truest "can I work" signal), not just
# whether a tun interface exists — a VPN can be "up" yet routing broken. A cheap,
# fast HTTPS HEAD that returns any HTTP status proves the route is live.
#
#   gate-previo.sh:  exec "$WORKER_HOME/vpn-gate.sh" https://gitlab.previo.info/
#
# Usage: vpn-gate.sh <url> [timeout-seconds]
set -uo pipefail
URL="${1:?usage: vpn-gate.sh <url> [timeout]}"
TIMEOUT="${2:-8}"
# --fail makes 4xx/5xx a curl error too, but for a reachability gate ANY HTTP
# response means the route is up — so we accept a real status code and only fail
# on transport errors (timeout / no route / connection refused).
code=$(curl -sS -o /dev/null -m "$TIMEOUT" -w '%{http_code}' "$URL" 2>/dev/null)
[ -n "$code" ] && [ "$code" != "000" ]
