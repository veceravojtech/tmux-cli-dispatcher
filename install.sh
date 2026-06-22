#!/usr/bin/env bash
# Deploy the tmux-cli worker dispatcher onto THIS machine.
#
# Installs the dispatcher scripts to $WORKER_HOME (default ~/.tmux-cli-worker),
# the Ed25519 signing key, and a self-heal cron. The dispatcher is
# REGISTRY-DRIVEN: worker-up.sh asks the backend (project_binding registry) which
# projects this host should run, provisions each (clones the repo if missing),
# and runs one lane-scoped consume dispatcher per project. So a machine needs
# this installed once + a registry row per project it should host — no per-host
# script edits.
#
# Env overrides: WORKER_HOME, TMUX_CLI_API_URL, TMUX_KEY (path to private.pem).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKER_HOME="${WORKER_HOME:-$HOME/.tmux-cli-worker}"
API_URL="${TMUX_CLI_API_URL:-https://tmux.vojta.ai}"

echo "==> Installing dispatcher to $WORKER_HOME (host: $(hostname))"
mkdir -p "$WORKER_HOME/keys"
install -m 0755 "$HERE/bin/dispatcher.sh" "$WORKER_HOME/dispatcher.sh"
install -m 0755 "$HERE/bin/worker-up.sh"  "$WORKER_HOME/worker-up.sh"
install -m 0755 "$HERE/bin/vpn-gate.sh"   "$WORKER_HOME/vpn-gate.sh"
install -m 0644 "$HERE/bin/registry.js"   "$WORKER_HOME/registry.js"
install -m 0644 "$HERE/bin/be-queue-count.js" "$WORKER_HOME/be-queue-count.js"
install -m 0644 "$HERE/bin/status-report.js"    "$WORKER_HOME/status-report.js"
install -m 0644 "$HERE/bin/control-listener.js" "$WORKER_HOME/control-listener.js"
install -m 0644 "$HERE/bin/fingerprint.js"      "$WORKER_HOME/fingerprint.js"
echo "    scripts installed"

# --- Signing key (secret): $TMUX_KEY > project keys/private.pem > already present ---
if [ -n "${TMUX_KEY:-}" ] && [ -f "$TMUX_KEY" ]; then
  install -m 0600 "$TMUX_KEY" "$WORKER_HOME/keys/private.pem"
  echo "    key: installed from \$TMUX_KEY"
elif [ -f "$HERE/keys/private.pem" ]; then
  install -m 0600 "$HERE/keys/private.pem" "$WORKER_HOME/keys/private.pem"
  echo "    key: installed from project keys/private.pem"
elif [ -f "$WORKER_HOME/keys/private.pem" ]; then
  echo "    key: already present"
else
  echo "    !! NO SIGNING KEY. Put the Ed25519 private key at $WORKER_HOME/keys/private.pem"
  echo "       (or set TMUX_KEY=/path/to/private.pem and re-run). The dispatcher cannot"
  echo "       query the registry or claim tasks without it."
fi

# --- Prerequisites (warn, don't fail) ---
command -v tmux >/dev/null || echo "    !! tmux not found (sudo apt install tmux)"
command -v node >/dev/null || echo "    !! node not found (the registry/queue helpers need Node)"
if ! command -v tmux-cli >/dev/null 2>&1 && [ ! -x "$HOME/.local/bin/tmux-cli" ]; then
  echo "    !! tmux-cli not installed — install it: curl -fsSL $API_URL/install.sh | bash"
fi

# --- Self-heal cron: @reboot + every minute (flock-guarded), idempotent ---
{
  crontab -l 2>/dev/null | grep -v "worker-up.sh" || true
  echo "@reboot $WORKER_HOME/worker-up.sh >> $WORKER_HOME/worker-up.log 2>&1"
  echo "* * * * * flock -n $WORKER_HOME/.up.lock $WORKER_HOME/worker-up.sh >> $WORKER_HOME/worker-up.log 2>&1"
} | crontab -
echo "    cron installed (@reboot + per-minute self-heal)"

cat <<EOF

==> Done.
    Bring up now:   $WORKER_HOME/worker-up.sh
    Pause all:      touch $WORKER_HOME/PAUSED      (resume: rm it)
    Logs:           $WORKER_HOME/worker-up.log  ·  $WORKER_HOME/dispatcher.log
    Attach a worker: tmux attach -t "\$(tmux ls -F '#{session_name}' | grep -m1 tmux-cli-)"

    This host runs a worker for every enabled project_binding whose hostname is
    "$(hostname)". Manage bindings in the admin: $API_URL/admin (Projekty).
EOF
