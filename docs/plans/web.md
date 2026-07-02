# Plan — web (tmux-web, Symfony 7.4 / EasyAdmin / FrankenPHP)

Lane: `web`. Deploy: `dep deploy production` (see memory `tmux-web-prod-deploy`). All API additions
stay under the existing firewalls; tests are phpunit using the signed-request helper.

## Done (release 31, commit 2c57c4d)
- [x] `ProjectBinding`: `desiredState` / `controlVersion` / `lastHeartbeatAt` / `runtimeState` / `activity` / `laneNew` + `DesiredState`/`RuntimeState` enums + migration.
- [x] `POST /api/v1/dispatchers/heartbeat`, `GET /api/v1/dispatchers`, `PATCH /api/v1/dispatchers/{id}/state`, `POST /api/v1/dispatchers/state`, `GET /api/v1/dispatchers/commands` (long-poll).
- [x] `ProjectBindingCrudController` shows the new fields read-only.

## Remaining

### W-UI-READ — read-only fleet dashboard *(can start now; GET /dispatchers is live)*
- [ ] Add an admin page (EasyAdmin custom dashboard route, or a Stimulus/Turbo controller) that renders `GET /api/v1/dispatchers`: project, host, desiredState, runtimeState, laneNew, lastHeartbeatAt, `down` badge.
- [ ] Auto-refresh every ~5s (Turbo frame or `fetch` poll).
- **Accept:** logged-in admin sees all bindings with live state; stale (`down`) rows visibly flagged. phpunit/functional test for the page route + a smoke render.
- **needs:** none.

### W-UI-CONTROL — control buttons + global kill-switch
- [ ] Per-row **pause / resume / stop** buttons → `PATCH /api/v1/dispatchers/{id}/state`; a **global kill-switch** → `POST /api/v1/dispatchers/state` (bulk).
- [ ] Optimistic UI + reflect returned `controlVersion`.
- **Accept:** clicking pause flips desiredState and the row reflects it; the remote worker enacts within ~1–2s (manually verifiable). 
- **needs:** W-UI-READ; **SEC-2** (these are mutations — gate behind admin-JWT before prod).

### W-PROVISION-STATE — accept provisioning status from heartbeat
- [ ] Allow `runtimeState=provisioning` end-to-end (already in the enum) and surface a free-text `activity`/error (e.g. "clone failed: deploy key") in the fleet read + UI.
- **Accept:** a heartbeat with `runtimeState=provisioning, activity="cloning…"` shows in `GET /dispatchers`; an error string renders in the UI. phpunit covers the round-trip.
- **needs:** none (additive). Consumed by dispatcher `D-PROVISION-ON-COMMAND`.

### W-DEPLOY-FORM — create a binding from the web (dynamic deploy entry point)
- [ ] "Deploy project" form: host picker (from registered `TmuxInstance`s), repo URL, branch, absolute path, lane name → creates a `ProjectBinding` (`desiredState=running`).
- [ ] Validate inputs; reject duplicate (hostname, projectName).
- [ ] Surface the chosen host's **git deploy public key** so the user can add it to the repo before deploying (key provided by dispatcher `D-DEPLOYKEY-SURFACE`).
- **Accept:** submitting the form creates an enabled binding; the host provisions it (see dispatcher `D-PROVISION-ON-COMMAND`) and the dashboard shows it go `provisioning → idle`. Functional test for binding creation + validation.
- **needs:** **SEC-1 + SEC-2** (this is the RCE-shaped capability — do not ship to prod before security); pairs with dispatcher `D-PROVISION-ON-COMMAND` + `D-DEPLOYKEY-SURFACE`.

### W-SSE — (optional, only if the fleet grows) replace long-poll with SSE/Mercure
- [ ] Move `GET /dispatchers/commands` from a held request to SSE/Mercure to stop holding one FrankenPHP worker per host (~25s each). Keep the `{workers, version}` contract identical so the dispatcher client barely changes.
- **needs:** none; revisit when held-worker count is a concern.
