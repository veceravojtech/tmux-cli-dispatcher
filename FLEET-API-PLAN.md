# Dispatcher fleet API: live status + near-instant on/off control

## Context

Workers run across hosts via this `dispatcher` project (registry-driven:
`worker-up.sh` reads `project_binding` for its hostname and runs a lane-scoped
consume loop per project). Today there is **no way to see what's running** or to
**turn a worker off/on** without SSHing in and touching files — and the cron
self-heal loop is ~60s, too slow for interactive control.

Goal: a **backend API** that (1) shows the live fleet — every host×project worker:
running/idle/consuming, current goal, lane NEW count, last heartbeat — and (2)
controls it **near-instantly** (pause/resume/stop per worker, per host, or global).
Per the user: **build the API now**; the **web control-center UI is future**
(separate work in tmux-web's frontend).

Near-instant rules out the per-minute cron. The mechanism: hosts hold a **long-poll
command channel** open to the backend; setting a worker's desired state returns the
held request immediately, so the host enacts it in ~1s (no websocket/Mercure infra,
no polling spam — one held HTTP request per host).

## Design — model + the API contract

**Where state lives:** extend `ProjectBinding` (each row already = one host×project
worker) rather than a new entity.
- **Desired (control):** `desiredState` enum `running|paused|stopped` (default `running`);
  `controlVersion` int (bumped on every change — the long-poll change token).
  (`enabled` stays the "registered at all" flag; desiredState is runtime control.)
- **Reported (status):** `lastHeartbeatAt` datetime, `runtimeState` enum
  `down|idle|consuming|paused`, `activity` string (current goal/task), `laneNew` int.

Semantics: `paused` = stop consuming (keep the tmux session warm); `stopped` = paused
+ kill the worker session; `running` = ensure session + dispatcher up, unpaused.
A host is `down` for a worker when `lastHeartbeatAt` is stale (> ~90s).

---

## Part A — Backend API (`web/`, deploy now)

All under the machine HMAC firewall (extend `security.yaml` `task_api` pattern to
`^/api/v1/(tasks|project-bindings|dispatchers)`).

- **`POST /api/v1/dispatchers/heartbeat`** — body `{hostname, workers:[{project,
  runtimeState, activity, laneNew}]}`. Upserts status onto the matching bindings +
  stamps `lastHeartbeatAt`. Returns each worker's `{desiredState, controlVersion}`
  (heartbeat doubles as a desired-state read).
- **`GET /api/v1/dispatchers`** — full fleet: every binding + status + desiredState +
  derived `down` staleness. The future UI and monitoring read this. (Optional
  `?hostname=`/`?project=` filters.)
- **`PATCH /api/v1/dispatchers/{id}/state`** — set `desiredState`
  (`running|paused|stopped`) for a worker; bump `controlVersion`. The "off/on" control.
  Also a thin convenience: `POST /api/v1/dispatchers/state` with
  `{hostname?, project?, desiredState}` to set many at once (per-host / global pause).
- **`GET /api/v1/dispatchers/commands?hostname=X&since=<v>`** — **long-poll**: return
  immediately if any of host X's bindings has `controlVersion > since`, else hold up
  to ~25s (re-checking ~1s) then return current. Body `{workers:[{project,
  desiredState, controlVersion}], version}`. The near-instant channel.

New: `src/Controller/Api/DispatcherController.php`; extend `ProjectBinding` (+ migration);
`ProjectBindingRepository` finders by hostname; reuse the `HmacAuthenticator` firewall.
Tests in `web/tests/` (phpunit, signed-request pattern from `TaskControllerTest`):
heartbeat upsert, fleet read, state PATCH bumps version, long-poll returns on a
version change vs times out.

## Part B — Dispatcher host-side (`dispatcher/`, deploy now)

Makes status real + enacts control near-instantly. New `bin/` scripts + `worker-up.sh`
wiring; the existing global `PAUSED` generalizes to per-project `PAUSED-<project>`.

- **`status-report.js`** — gather per-project local state (tmux session up, dispatcher
  `pgrep`, `taskvisor-active` ⇒ consuming/idle, current goal from `goals.yaml`,
  `be-queue-count` lane NEW) and `POST /heartbeat`. Run on a light loop (~15–20s) + each
  `worker-up` tick.
- **`control-listener.sh`** — a small daemon that long-polls `/commands` for this host;
  on a `desiredState` change it enacts instantly: `paused` → `touch PAUSED-<project>`
  (dispatcher stops next loop); `running` → `rm PAUSED-<project>` + ensure up; `stopped`
  → also kill the worker session. Managed (kept alive) by `worker-up.sh` like the
  dispatchers; reconciles full state on (re)start.
- **`dispatcher.sh`** — check `PAUSED` (global) **and** `PAUSED-$LANE` at loop top.
- **`worker-up.sh`** — ensure `control-listener` + `status-report` are running; on each
  tick also reconcile desiredState from the registry (fallback if the listener is down).
- `install.sh` installs the two new scripts.

## Future (NOT now) — web control-center UI

A page in tmux-web's frontend rendering `GET /api/v1/dispatchers` (auto-refresh) with
on/off/pause buttons calling `PATCH …/state` + a global kill-switch. The API above is
the contract it builds on. (Per the user, deferred to the web project.)

## Verification

1. **Backend**: phpunit green; against the deployed API, a signed `PATCH …/state`
   bumps `controlVersion` and a concurrently-held `GET /commands` returns within ~1s.
2. **Host E2E**: on remote.vojta.ai, `PATCH` the cli worker to `paused` → within ~1–2s
   the control-listener touches `PAUSED-cli`, the dispatcher stops dispatching, and the
   next heartbeat shows `runtimeState=paused`; `PATCH running` → it resumes. `stopped`
   tears the session down; heartbeat → `down` after it stops reporting.
3. **Fleet read**: `GET /api/v1/dispatchers` lists both workers with live state +
   current activity.

## Risks / notes

- **Long-poll holds one FrankenPHP worker per host** for ≤25s. Fine for a small fleet;
  if it grows, switch the channel to SSE/Mercure (the API contract stays the same).
- **Near-instant is best-effort ~1–2s** (long-poll re-check interval); the per-minute
  cron remains the safety net that reconciles desired state if the listener dies.
- Additive + backward compatible: new columns default `running`; a host without the new
  scripts simply doesn't report/enact (shows `down`), exactly as today.
