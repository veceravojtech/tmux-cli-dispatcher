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

while IFS=$'\t' read -r name path repo branch; do
  [ -z "$name" ] || [ -z "$path" ] && continue
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
  if ! pgrep -f "dispatcher.sh $path" >/dev/null 2>&1; then
    log "[$name] dispatcher down — (re)starting"
    tmux kill-session -t "worker-ctl-$name" 2>/dev/null
    tmux new-session -d -s "worker-ctl-$name" -n dispatcher "bash $WORKER_HOME/dispatcher.sh '$path'"
  fi
done <<< "$BINDINGS"
