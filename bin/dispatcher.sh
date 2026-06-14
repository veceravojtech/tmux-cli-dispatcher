#!/usr/bin/env bash
# Remote tmux-cli worker dispatcher. Sends `/clear` + `/tmux:task-list consume N`
# into the worker's supervisor window ONLY when it is provably idle, and only
# when this worker's LANE has NEW tasks. Lane = the working-folder path (matches
# across machines). Stop: touch ~/.tmux-cli-worker/PAUSED ; resume: rm it.
set -uo pipefail
export PATH="$HOME/.local/bin:$HOME/.local/go/bin:$PATH"

WORKER_HOME="$HOME/.tmux-cli-worker"
PROJECT_DIR="${1:-$HOME/PhpstormProjects/tmux-package/cli}"
TMUXCLI="$HOME/.local/bin/tmux-cli"
NODE_HELPER="$WORKER_HOME/be-queue-count.js"
LOG="$WORKER_HOME/dispatcher.log"
LOCK="$PROJECT_DIR/.tmux-cli/worker-dispatch.lock"
PAUSED="$WORKER_HOME/PAUSED"
# This worker's lane (path), resolved authoritatively from tmux-cli so the
# NEW-count check is scoped to exactly the tasks this worker would claim.
LANE="$(cd "$PROJECT_DIR" 2>/dev/null && "$TMUXCLI" api-project 2>/dev/null)"

CONSUME_N="${CONSUME_N:-10}"; POLL="${POLL:-20}"; POLL_IDLE="${POLL_IDLE:-60}"
GRACE="${GRACE:-600}"; HEARTBEAT="${HEARTBEAT:-300}"

log() { local m="$(date -u +%FT%TZ) $*"; echo "$m"; echo "$m" >> "$LOG"; }

find_session() {
  local sid path
  for sid in $(tmux list-sessions -F '#{session_name}' 2>/dev/null); do
    path=$(tmux show-environment -t "$sid" TMUX_CLI_PROJECT_PATH 2>/dev/null | sed 's/^TMUX_CLI_PROJECT_PATH=//')
    [ "$path" = "$PROJECT_DIR" ] && { echo "$sid"; return 0; }
  done
  return 1
}
ensure_session() {
  if ! find_session >/dev/null; then
    log "no worker session — creating via 'tmux-cli start'"
    ( cd "$PROJECT_DIR" && TERM=xterm "$TMUXCLI" start >>"$LOG" 2>&1 ); sleep 12
  fi
}
taskvisor_active() { [ -f "$PROJECT_DIR/.tmux-cli/taskvisor-active" ]; }
goal_windows_open() { tmux list-windows -t "$1" -F '#{window_name}' 2>/dev/null | grep -qE '^(execute|supervisor-|validator|investigator)'; }
window0_idle() {
  local p; p=$(tmux capture-pane -t "$1:0" -p 2>/dev/null)
  echo "$p" | grep -q "esc to interrupt" && return 1
  echo "$p" | grep -qiE "How is Claude doing|trust this folder|Do you want|Dismiss|❯ 1\." && return 1
  echo "$p" | grep -q "for agents" || return 1
  return 0
}
dispatch_inflight() {
  [ -f "$LOCK" ] || return 1
  local age=$(( $(date +%s) - $(stat -c %Y "$LOCK" 2>/dev/null || echo 0) ))
  [ "$age" -lt "$GRACE" ]
}
count_new() { local n; n=$(node "$NODE_HELPER" new "$LANE" 2>>"$LOG"); [[ "$n" =~ ^[0-9]+$ ]] || n=0; echo "$n"; }
clear_input() { local s="$1" i; tmux send-keys -t "$s:0" Escape; sleep 0.4; for i in $(seq 60); do tmux send-keys -t "$s:0" BSpace; done; sleep 0.4; }
send_consume() {
  local s="$1"
  clear_input "$s"
  tmux send-keys -t "$s:0" -l "/clear"; sleep 1; tmux send-keys -t "$s:0" Enter; sleep 2
  tmux send-keys -t "$s:0" -l "/tmux:task-list consume $CONSUME_N"; sleep 1; tmux send-keys -t "$s:0" Enter
  touch "$LOCK"
}

log "dispatcher started (lane=$LANE consume_n=$CONSUME_N)"
last_hb=0; idle_streak=0
while true; do
  [ -f "$PAUSED" ] && { log "PAUSED flag present — exiting (cron will not revive while flag exists)"; exit 0; }
  ensure_session
  S=$(find_session) || { log "session unavailable; retry ${POLL_IDLE}s"; sleep "$POLL_IDLE"; continue; }
  if taskvisor_active;       then idle_streak=0; sleep "$POLL"; continue; fi
  if goal_windows_open "$S"; then idle_streak=0; sleep "$POLL"; continue; fi
  if ! window0_idle "$S";    then idle_streak=0; sleep "$POLL"; continue; fi
  idle_streak=$((idle_streak+1)); [ "$idle_streak" -lt 2 ] && { sleep "$POLL"; continue; }
  if dispatch_inflight;      then sleep "$POLL"; continue; fi
  N=$(count_new)
  if [ "$N" -gt 0 ]; then
    log "lane NEW=$N, window-0 idle (stable) → dispatch consume $CONSUME_N"
    send_consume "$S"; idle_streak=0; sleep "$POLL"
  else
    rm -f "$LOCK"; now=$(date +%s)
    [ $(( now - last_hb )) -ge "$HEARTBEAT" ] && { log "idle — lane queue empty (NEW=0)"; last_hb=$now; }
    sleep "$POLL_IDLE"
  fi
done
