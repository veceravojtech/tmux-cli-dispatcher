# Plan — security (cross-cutting)

**This gates Phase 3 (dynamic deploy).** Today every machine shares one embedded Ed25519 key and the
fingerprint is self-asserted — anyone holding that key can sign as any fingerprint. With only task-filing
that's low-stakes; once the control plane can **pause workers and clone+run arbitrary repos on hosts**, the
same key becomes remote-code-execution-by-registry. Land SEC-1 + SEC-2 before `W-DEPLOY-FORM` /
`D-PROVISION-ON-COMMAND` reach a prod host.

Touches both **web** (auth/firewall/entities) and **dispatcher** (key provisioning). Sequence these before
the Phase-3 items in [web.md](web.md) / [dispatcher.md](dispatcher.md).

### SEC-1 — authorized identity (per-host keys or fingerprint allowlist)  · lane: web (+ dispatcher)
- [ ] Decide the model: **(a)** per-host Ed25519 keys (each host its own keypair; backend holds the set of authorized public keys), or **(b)** keep the shared key for signing but enforce an **allowlist** — a heartbeat/command/deploy is only honored for a fingerprint that maps to an admin-`enabled` `TmuxInstance`/`ProjectBinding`.
- [ ] Web: enforce it in `HmacAuthenticator` (verify against the authorized key set) and/or in the dispatcher controllers (reject unknown/disabled fingerprints with 403).
- [ ] Dispatcher: `D-PER-HOST-KEY` provisions the host key (only if model (a)).
- **Accept:** a request signed by an unauthorized/disabled identity is rejected; existing authorized hosts keep working. phpunit covers authorized-vs-rejected.

### SEC-2 — split human control from machine reporting  · lane: web
- [ ] Keep `POST /heartbeat` and `GET /commands` on the **machine HMAC** firewall (hosts).
- [ ] Move the **mutations** — `PATCH /dispatchers/{id}/state`, `POST /dispatchers/state`, and the deploy/binding-create form — behind **admin JWT** (humans), not the shared machine key. (Today they sit under the machine firewall with a `// TODO` marker.)
- **Accept:** a machine-signed request can heartbeat + read commands but cannot flip desiredState or create a binding; an admin JWT can. phpunit covers both firewalls.

### SEC-3 — per-host deploy-key management for private repos  · lane: dispatcher (+ web display)
- [ ] Standardize how each host gets a git deploy key for cloning private repos (generated on `install.sh`, public half surfaced via `D-DEPLOYKEY-SURFACE`). Document rotation.
- **Accept:** a private repo can be deployed to a host after its public deploy key is added, with a documented rotation path.

### SEC-4 — audit trail for control actions  · lane: web
- [ ] Record who paused/resumed/stopped/deployed (actor + old/new desiredState) — mirror the existing `TaskEvent` audit pattern on `ProjectBinding` state changes.
- **Accept:** every desiredState change and binding-create is attributable in the admin.
