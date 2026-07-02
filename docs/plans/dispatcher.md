# Plan — dispatcher (host-side control plane)

Repo: `tmux-cli-dispatcher`. Installed to `~/.tmux-cli-worker/` on each fleet host via `install.sh`.
**Not dispatched as tasks** (no `dispatcher` lane consumer) — these are edited here, landed on a branch/PR,
and adopted by re-running `install.sh` + restart on the host. Test via `bash -n` / `node --check` + a live
smoke on `remote.vojta.ai`.

## Done (commit c656cd8)
- [x] `status-report.js --loop` — signed `POST /api/v1/dispatchers/heartbeat` per project on this host.
- [x] `control-listener.js` — long-polls `GET /api/v1/dispatchers/commands`, enacts `paused`→touch `PAUSED-<lane>`, `running`→clear, `stopped`→clear+kill session; reconciles on start.
- [x] `dispatcher.sh` honors per-lane `$WORKER_HOME/PAUSED-<lane>` (warm session, no consume) alongside global `PAUSED` (exit).
- [x] `worker-up.sh` keeps both daemons alive; `install.sh` installs them.
- [x] tmux-cli self-update at the idle gate (build-on-idle + recycle-when-stale).

## Remaining

### D-PROVISION-ON-COMMAND — provision a NEW binding on demand (Phase 3 core)
- [ ] When the control-listener/worker-up sees a binding for this host with `desiredState=running` but **no local checkout/session yet**, run the provisioning path (`git clone` the repo to `path`, then `tmux-cli start`) — the clone+start logic already exists in `worker-up.sh`; trigger it near-instantly from the command channel rather than waiting for the per-minute cron.
- [ ] Report progress through the heartbeat: `runtimeState=provisioning` while cloning, `idle` when up, and on failure set `activity="clone failed: <reason>"` (e.g. missing deploy key) instead of silently retrying.
- **Accept:** creating a binding via web `W-DEPLOY-FORM` results in the host cloning + starting the worker within ~1–2s of the command, and the dashboard shows `provisioning → idle` (or a clear error). Smoke on `remote.vojta.ai` with a throwaway repo.
- **needs:** web `W-PROVISION-STATE`; **SEC-1/SEC-2** before enabling on a prod host.

### D-DEPLOYKEY-SURFACE — expose the host's git deploy public key
- [ ] Provide the host's git deploy **public** key to the web deploy form (so the user can authorize a private repo before deploying). Options: include it in the heartbeat payload (a `deployKey` field, web stores/displays it) or a tiny read endpoint. Prefer heartbeat field — reuses the signed channel.
- **Accept:** the web deploy form can display "add this key to the repo's deploy keys" for the chosen host. 
- **needs:** small web change to accept/store the field (fold into `W-DEPLOY-FORM`).

### D-PER-HOST-KEY — per-host signing identity (Phase 5)
- [ ] Stop relying on the single shared embedded Ed25519 key. `install.sh` provisions/uses a per-host key; the fingerprint maps to an admin-authorized binding. Update `registry.js`/`be-queue-count.js`/`status-report.js`/`control-listener.js` to read the host key path.
- **Accept:** each host signs with its own key; an un-authorized fingerprint is rejected by the backend (see `SEC-1`).
- **needs:** **SEC-1** (backend must accept per-host keys / enforce the allowlist first).

### D-HARDEN — robustness polish (low priority)
- [ ] Jittered backoff in `control-listener.js` on repeated non-200 (avoid synchronized retries across hosts).
- [ ] `status-report.js`: cap `currentGoal` parsing cost on large `goals.yaml`; consider sourcing state from `tmux-cli status --json` (213) instead of re-deriving, once it's universally deployed.
- [ ] If web adopts `W-SSE`, switch `control-listener.js` from long-poll to the SSE stream (same `{workers,version}` contract).
