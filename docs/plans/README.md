# Fleet control — completion roadmap

Plan to finish the **fleet status + control + dynamic-deploy** plane across the three
repos. Split by lane: [web](web.md) · [cli](cli.md) · [dispatcher](dispatcher.md) ·
[security (cross-cutting)](security.md).

Each item is sized to be dispatched as one backend task (one task → one goal). Cross-lane
edges are noted as `needs:` — the backend gates claiming on `depends_on`, so a dependent
task stays `ready=false` until its prerequisite resolves.

## Status snapshot (2026-06-17)

| Area | Done | Where |
|------|------|-------|
| tmux-cli self-update at idle gate | ✅ | dispatcher `b22ea30` |
| ProjectBinding state + heartbeat + fleet-read + state PATCH/bulk + long-poll commands | ✅ | web `2c57c4d`, **prod release 31** |
| `tmux-cli status --json` | ✅ | cli task 213 |
| Host-side glue: status-report + control-listener + per-lane PAUSED + worker-up supervision | ✅ | dispatcher `c656cd8` |
| Live verified: heartbeat, fleet read, near-instant pause/resume | ✅ | — |
| Planner collision fix: serialize goals that edit the same files | ✅ | cli task 215 (`EnforceFileOverlapDeps`) — multi-goal dispatch now reliable |

**Remaining:** Phase 3 dynamic deploy · Phase 4 web UI · Phase 5 security (gates 3). cli planner-collision fix (task 215) ✅ landed.

**Dispatched 2026-06-17 (web lane, host `ubuntu-8gb-nbg1-2`):**

| Task | Item | Severity | `depends_on` | Notes |
|------|------|----------|--------------|-------|
| **218** | W-UI-READ | warning | — | read-only dashboard; can start now |
| **219** | SEC-1 | critical | — | allowlist model (shared key + admin-enabled fingerprint check) — chosen over per-host keys |
| **220** | W-PROVISION-STATE | warning | 218 | extends 218's dashboard (serialized) |
| **221** | SEC-2 | critical | 219 | split machine-HMAC vs admin-JWT |
| **222** | SEC-4 | warning | 221 | audit trail; actor comes from 221's JWT |
| **223** | W-UI-CONTROL | warning | 218, 221 | mutations; gated on SEC-2 |
| **224** | W-DEPLOY-FORM | warning | 219, 221 | web slice only; gated on SEC-1+SEC-2 |

Edges 220→218 and 222→221 added beyond the per-lane `needs:` to serialize same-file goals (principle 6). Not dispatched (human-built on a branch + PR, adopted via `install.sh`): dispatcher `D-PROVISION-ON-COMMAND`, `D-DEPLOYKEY-SURFACE`, `D-PER-HOST-KEY`, `D-HARDEN`. W-DEPLOY-FORM (224) builds only the web slice; end-to-end provisioning needs the dispatcher D-items + a host redeploy.

**Incident + recurrence prevention (2026-06-17 night):** the host's web checkout was on a stale master lacking origin's release-31 fleet-control commit (`2c57c4d`); goals built on the wrong base — a zombie `goal-002` head-of-line-blocked the queue ~50 min, and SEC-1 (219) was built in isolation from the dispatcher endpoints (its rebase onto the real base produced 12 failing `DispatcherControllerTest`s = a near-miss prod fleet-lockout). Remediated by resetting the checkout to the green prod base (`2c57c4d`) and re-dispatching 218/219 so they rebuild correctly. Prevention dispatched to **cli**: **225** (daemon/consume must git-fetch + fast-forward, refuse a diverged base before any dispatch/claim — critical) and **226** (`/tmux:task-list` preflight: auto-reconcile stale/zombie goals + the 225 git check; depends on 225). NB: `tmux-web` auto-deploys master→prod on push; taskvisor commits locally only, so prod deploy is an explicit-push decision.

## Principles (carry these into every task)

1. **Runtime control = the command channel, NOT tasks.** Pause/deploy are push-to-host and
   lane-independent (a new lane has no worker to claim a task). Only the *build* work is dispatched as tasks.
2. **Frozen contract first.** Pin the exact endpoint/payload/enum shape in the task description so
   web + dispatcher build to the same shape in parallel.
3. **Additive-only on the web API.** The live workers report task status through the same backend —
   never break `task`/`project-binding`/`dispatchers` response contracts.
4. **`SEC` gates dynamic deploy.** Deploy = "clone arbitrary repo + run code on a host" = RCE-by-registry
   under today's single shared key. Land [security.md](security.md) SEC-1/SEC-2 before Phase 3 ships to prod.
5. **Human-adopt the dispatcher runner.** A worker that edits `dispatcher.sh`/`worker-up.sh` (the scripts
   running it) lands changes on a branch + PR; a human runs `install.sh`/redeploy. Don't auto-deploy the runner.
6. **Serialize goals that touch the same files** — see cli task 215; the web branch already cascade-failed
   once because two goals edited `ProjectBinding.php` in parallel worktrees.

## Suggested order

```
cli:215 (planner collision)  ──┐ (unblocks reliable multi-goal dispatch)
security: SEC-1, SEC-2 ────────┼─→ web: W-PROVISION-STATE, W-DEPLOY-FORM ─→ dispatcher: D-PROVISION-ON-COMMAND
web: W-UI (read-only first) ───┘                                            (Phase 3 dynamic deploy)
web: W-UI controls ──────────────────────────────────────────────────────→ (Phase 4)
```
Phase 4 read-only UI can start now (the GET /dispatchers endpoint is live). Phase 3 must wait for SEC.
