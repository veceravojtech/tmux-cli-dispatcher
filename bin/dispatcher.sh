#!/usr/bin/env bash
# Remote tmux-cli worker dispatcher. Sends `/clear` + `/tmux:task-list consume N`
# into the worker's supervisor window ONLY when it is provably idle, and only
# when this worker's LANE has NEW tasks. Lane = the working-folder path (matches
# across machines). Stop: touch ~/.tmux-cli-worker/PAUSED ; resume: rm it.
set -uo pipefail
export PATH="$HOME/.local/bin:$HOME/.local/go/bin:$PATH"

WORKER_HOME="$HOME/.tmux-cli-worker"
PROJECT_DIR="${1:?usage: dispatcher.sh <project-path>}"
TMUXCLI="$HOME/.local/bin/tmux-cli"
NODE_HELPER="$WORKER_HOME/be-queue-count.js"
LOG="$WORKER_HOME/dispatcher.log"
LOCK="$PROJECT_DIR/.tmux-cli/worker-dispatch.lock"
PAUSED="$WORKER_HOME/PAUSED"
# This worker's lane (path), resolved authoritatively from tmux-cli so the
# NEW-count check is scoped to exactly the tasks this worker would claim.
resolve_lane() { (cd "$PROJECT_DIR" 2>/dev/null && "$TMUXCLI" api-project 2>/dev/null); }
LANE="$(resolve_lane)"

CONSUME_N="${CONSUME_N:-10}"; POLL="${POLL:-20}"; POLL_IDLE="${POLL_IDLE:-60}"
GRACE="${GRACE:-600}"; HEARTBEAT="${HEARTBEAT:-300}"
# Optional pre-dispatch gate: a command that must exit 0 immediately before a consume
# is sent, so a lane that can't work offline (e.g. needs the Previo VPN up + the git
# host reachable) holds its queue instead of dispatching into a broken environment.
# Resolution is RE-EVALUATED on every dispatch (not cached at startup): $DISPATCH_GATE
# env (explicit) else $WORKER_HOME/gate-<lane>.sh if executable. The gate file itself is
# materialised by worker-up.sh from the registry's gateUrl, so an admin edit on the fleet
# dashboard takes effect here within one worker-up tick — no dispatcher restart needed.
# Unset/absent => no gate (default; github lanes like cli/web dispatch unconditionally).
# A failing gate keeps the session warm and skips the consume, exactly like a per-lane
# pause — so the lane resumes on its own the moment the gate passes (VPN comes back).
dispatch_gate_ok() {
  local gate="${DISPATCH_GATE:-}"
  [ -z "$gate" ] && [ -n "$LANE" ] && [ -x "$WORKER_HOME/gate-$LANE.sh" ] && gate="$WORKER_HOME/gate-$LANE.sh"
  [ -z "$gate" ] && return 0
  bash -c "$gate" >>"$LOG" 2>&1
}
# Self-update of the tmux-cli binary from source (built with `make install`),
# performed only at the idle dispatch gate. CLI_SRC is the local tmux-cli git
# checkout; on hosts without it the whole feature is a silent no-op.
CLI_SRC="${CLI_SRC:-$HOME/PhpstormProjects/tmux-package/cli}"
UPDATE_CHECK_INTERVAL="${UPDATE_CHECK_INTERVAL:-300}"
BUILD_LOCK="$WORKER_HOME/.cli-build.lock"

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

# Track the remote tmux-cli branch and (re)build via `make install` when the
# installed binary is behind. Throttled (UPDATE_CHECK_INTERVAL) and serialized
# across all per-project dispatchers on this host (flock). NON-DESTRUCTIVE: an
# ff-merge is attempted only when the checkout is clean and has an upstream; a
# dirty/diverged checkout is left untouched (it still builds whatever HEAD is).
# `install: build` means a failed compile never overwrites the live binary.
maybe_build_cli() {
  [ -d "$CLI_SRC/.git" ] || return 0
  local now; now=$(date +%s)
  [ $(( now - last_build_check )) -lt "$UPDATE_CHECK_INTERVAL" ] && return 0
  last_build_check=$now
  (
    flock -n 9 || exit 0   # another dispatcher is already building → skip this pass
    git -C "$CLI_SRC" fetch --quiet 2>>"$LOG" || exit 0
    local clean=0
    git -C "$CLI_SRC" diff --quiet 2>/dev/null && git -C "$CLI_SRC" diff --cached --quiet 2>/dev/null && clean=1
    if [ "$clean" = 1 ] && git -C "$CLI_SRC" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
      git -C "$CLI_SRC" merge --ff-only --quiet '@{u}' 2>>"$LOG" \
        || log "cli: ff-merge skipped (branch diverged from upstream)"
    else
      log "cli: ff-merge skipped (no upstream or local changes) — building current HEAD"
    fi
    # Key the rebuild on commit identity, not the "-dirty" suffix: `make build`
    # runs gofmt, so a checkout whose committed code isn't gofmt-clean always
    # yields a -dirty binary. Comparing without -dirty avoids a perpetual
    # rebuild+recycle loop when the tree simply can't build clean.
    local want have
    want=$(git -C "$CLI_SRC" describe --tags --match 'v*' --always 2>/dev/null)
    have=$("$TMUXCLI" --version 2>/dev/null | awk '{print $3}'); have=${have%-dirty}
    [ -n "$want" ] && [ "$want" != "$have" ] || exit 0
    log "cli: building ${have:-unknown} -> $want (make -C $CLI_SRC install)"
    if make -C "$CLI_SRC" install >>"$LOG" 2>&1 && "$TMUXCLI" --version >/dev/null 2>&1; then
      # gofmt may have reformatted committed files; if we started clean, restore
      # them so a build-dirtied tree never blocks future ff-merges.
      if [ "$clean" = 1 ] && { ! git -C "$CLI_SRC" diff --quiet || ! git -C "$CLI_SRC" diff --cached --quiet; }; then
        git -C "$CLI_SRC" checkout -- . 2>>"$LOG" && log "cli: reverted build-induced gofmt changes"
      fi
      log "cli: installed $want"
    else
      log "cli: build FAILED — keeping ${have:-existing} binary"
    fi
  ) 9>"$BUILD_LOCK"
}
# True when the session was created before the on-disk tmux-cli binary: its Claude
# MCP server + taskvisor daemon hold the old inode, so a recreate is required to
# adopt the new build. Undeterminable timestamps → not stale (never churn blindly).
session_stale() {
  local created bmtime
  created=$(tmux display-message -p -t "$1" '#{session_created}' 2>/dev/null)
  bmtime=$(stat -c %Y "$TMUXCLI" 2>/dev/null)
  [[ "$created" =~ ^[0-9]+$ ]] && [[ "$bmtime" =~ ^[0-9]+$ ]] || return 1
  [ "$created" -lt "$bmtime" ]
}

log "dispatcher started (lane=$LANE consume_n=$CONSUME_N cli_src=$CLI_SRC)"
last_hb=0; idle_streak=0; last_build_check=0
while true; do
  [ -f "$PAUSED" ] && { log "PAUSED flag present — exiting (cron will not revive while flag exists)"; exit 0; }
  ensure_session
  S=$(find_session) || { log "session unavailable; retry ${POLL_IDLE}s"; sleep "$POLL_IDLE"; continue; }
  # Per-lane pause (set near-instantly by control-listener on a 'paused'/'stopped'
  # desiredState): keep the session warm but stop consuming. Global PAUSED (above)
  # exits; this one just idles the lane.
  if [ -n "$LANE" ] && [ -f "$WORKER_HOME/PAUSED-$LANE" ]; then
    idle_streak=0; rm -f "$LOCK"; now=$(date +%s)
    [ $(( now - last_hb )) -ge "$HEARTBEAT" ] && { log "lane PAUSED ($LANE) — session warm, not consuming"; last_hb=$now; }
    sleep "$POLL_IDLE"; continue
  fi
  if taskvisor_active;       then idle_streak=0; sleep "$POLL"; continue; fi
  if goal_windows_open "$S"; then idle_streak=0; sleep "$POLL"; continue; fi
  if ! window0_idle "$S";    then idle_streak=0; sleep "$POLL"; continue; fi
  idle_streak=$((idle_streak+1)); [ "$idle_streak" -lt 2 ] && { sleep "$POLL"; continue; }
  if dispatch_inflight;      then sleep "$POLL"; continue; fi
  if [ -z "$LANE" ]; then
    LANE="$(resolve_lane)"
    if [ -z "$LANE" ]; then
      log "lane unresolved (tmux-cli api-project empty) — skipping dispatch to avoid unscoped NEW count"
      idle_streak=0; sleep "$POLL"; continue
    fi
    log "lane resolved late: $LANE"
  fi
  N=$(count_new)
  if [ "$N" -gt 0 ]; then
    # Precondition gate (e.g. VPN up): when set and failing, hold the queue rather than
    # dispatch into an unworkable environment. Keep the session warm; retry next tick.
    if ! dispatch_gate_ok; then
      idle_streak=0; rm -f "$LOCK"; now=$(date +%s)
      [ $(( now - last_hb )) -ge "$HEARTBEAT" ] && { log "lane $LANE: dispatch gate failing — holding NEW=$N (session warm)"; last_hb=$now; }
      sleep "$POLL_IDLE"; continue
    fi
    # Idle + work present = the safe moment to adopt a new tmux-cli build. Build
    # if behind, then recreate the session so the consume runs on the new binary
    # (ensure_session at the top of the next tick respawns it on the new code).
    maybe_build_cli
    if session_stale "$S"; then
      log "session $S predates tmux-cli binary → recreating to adopt new build"
      tmux kill-session -t "$S" 2>/dev/null
      idle_streak=0; sleep "$POLL"; continue
    fi
    log "lane NEW=$N, window-0 idle (stable) → dispatch consume $CONSUME_N"
    send_consume "$S"; idle_streak=0; sleep "$POLL"
  else
    # Idle with an empty queue: still keep tmux-cli current (self-throttled), so a
    # released build is adopted without waiting for the next task. Recycle stays
    # deferred — session_stale picks up the new binary at the next consume.
    maybe_build_cli
    rm -f "$LOCK"; now=$(date +%s)
    [ $(( now - last_hb )) -ge "$HEARTBEAT" ] && { log "idle — lane queue empty (NEW=0)"; last_hb=$now; }
    sleep "$POLL_IDLE"
  fi
done
