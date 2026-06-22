#!/usr/bin/env bash
# Registry-driven, idempotent self-heal for ALL workers on THIS machine. Run by
# cron every minute + @reboot. Reads the project-binding registry for this
# hostname, then for each binding: provisions the repo (clone if missing) and
# ensures the worker session + lane-scoped dispatcher are alive. Adding a project
# = add a registry row (no script edit). Pause: touch ~/.tmux-cli-worker/PAUSED.
set -uo pipefail
export PATH="$HOME/.local/bin:$HOME/.local/go/bin:$PATH"
WORKER_HOME="$HOME/.tmux-cli-worker"
TMUXCLI="$HOME/.local/bin/tmux-cli"
LOG="$WORKER_HOME/worker-up.log"
log(){ echo "$(date -u +%FT%TZ) $*" >> "$LOG"; }

[ -f "$WORKER_HOME/PAUSED" ] && exit 0

HN=$(hostname)
BINDINGS=$(node "$WORKER_HOME/registry.js" "$HN" 2>>"$LOG")
if [ -z "$BINDINGS" ]; then
  log "no registry bindings for host=$HN (or fetch failed) — leaving existing workers untouched"
  exit 0
fi

find_worker_session() {  # $1 = project path
  local sid path
  for sid in $(tmux list-sessions -F '#{session_name}' 2>/dev/null); do
    path=$(tmux show-environment -t "$sid" TMUX_CLI_PROJECT_PATH 2>/dev/null | sed 's/^TMUX_CLI_PROJECT_PATH=//')
    [ "$path" = "$1" ] && { echo "$sid"; return 0; }
  done
  return 1
}

dispatcher_running() {  # $1 = project path
  local line
  while IFS= read -r line; do
    [[ "$line" == *"dispatcher.sh $1" ]] && return 0
  done < <(pgrep -af 'dispatcher\.sh' 2>/dev/null)
  return 1
}

# Materialise (or remove) a lane's pre-dispatch gate file from the registry's gateUrl. dispatcher.sh
# re-reads $WORKER_HOME/gate-<lane>.sh on every dispatch, so an admin edit on the fleet dashboard
# takes effect on the next worker-up tick (~60s) with no dispatcher restart. Empty gateUrl => no gate.
reconcile_gate() {
  local lane="$1" url="$2"
  # Separate statement: a single `local a=$1 g=...$a...` expands $a against the OUTER scope (empty)
  # before the assignment lands, which would yield gate-.sh. Assign gate only after lane is set.
  local gate="$WORKER_HOME/gate-$lane.sh"
  if [ -z "$url" ]; then
    [ -f "$gate" ] && { rm -f "$gate"; log "[$lane] gate cleared (no gateUrl in registry)"; }
    return
  fi
  local want="#!/usr/bin/env bash
# Auto-generated from the registry gateUrl for lane '$lane'. Do not edit by hand.
exec \"\$HOME/.tmux-cli-worker/vpn-gate.sh\" '$url'"
  if [ ! -f "$gate" ] || [ "$(cat "$gate")" != "$want" ]; then
    printf '%s\n' "$want" > "$gate"; chmod 0755 "$gate"; log "[$lane] gate set -> $url"
  fi
}

while IFS=$'\t' read -r name path repo branch gate_url; do
  [ -z "$name" ] || [ -z "$path" ] && continue
  reconcile_gate "$name" "$gate_url"
  # 1) provision: clone the repo into path if it isn't there yet
  if [ ! -d "$path/.git" ]; then
    log "[$name] provisioning: git clone $repo -> $path (branch=${branch:-default})"
    mkdir -p "$(dirname "$path")"
    if [ -n "$branch" ]; then
      git clone --branch "$branch" "$repo" "$path" >>"$LOG" 2>&1 || { log "[$name] clone FAILED (deploy key/alias?)"; continue; }
    else
      git clone "$repo" "$path" >>"$LOG" 2>&1 || { log "[$name] clone FAILED (deploy key/alias?)"; continue; }
    fi
  fi
  # 2) worker session (supervisor + taskvisor daemon)
  if ! find_worker_session "$path" >/dev/null; then
    log "[$name] worker session missing — starting"
    ( cd "$path" && TERM=xterm "$TMUXCLI" start >>"$LOG" 2>&1 ); sleep 12
  fi
  # 3) lane-scoped dispatcher (PROJECT_DIR arg => one per project)
  if ! dispatcher_running "$path"; then
    log "[$name] dispatcher down — (re)starting"
    tmux kill-session -t "worker-ctl-$name" 2>/dev/null
    tmux new-session -d -s "worker-ctl-$name" -n dispatcher "bash $WORKER_HOME/dispatcher.sh '$path'"
  fi
done <<< "$BINDINGS"

# Host-level fleet daemons (one each, covering ALL of this host's projects):
#   status-report   — POSTs per-project heartbeats to the backend
#   control-listener — long-polls for near-instant pause/resume/stop
# Kept alive here like the dispatchers. Both no-op gracefully until the web fleet
# API is deployed (they log a 404 and retry), so they're safe to run now.
proc_running() { pgrep -af "$1" >/dev/null 2>&1; }
if ! proc_running 'status-report\.js'; then
  log "[fleet] status-report down — (re)starting"
  tmux kill-session -t worker-status 2>/dev/null
  tmux new-session -d -s worker-status "node '$WORKER_HOME/status-report.js' --loop >> '$WORKER_HOME/status-report.log' 2>&1"
fi
if ! proc_running 'control-listener\.js'; then
  log "[fleet] control-listener down — (re)starting"
  tmux kill-session -t worker-control 2>/dev/null
  tmux new-session -d -s worker-control "node '$WORKER_HOME/control-listener.js' >> '$WORKER_HOME/control-listener.log' 2>&1"
fi
