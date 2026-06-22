# AGENTS.md

Operational notes for agents working on the tmux-cli worker dispatcher.

## Fleet SSH access & deploy topology

- **Worker host (reachable):** `ssh console@remote.vojta.ai` → `ubuntu-8gb-nbg1-2`
  (168.119.224.216). This is where the dispatcher/worker glue runs
  (`~/.tmux-cli-worker/`), and where the `cli`, `web`, `previo`, `previo2` lanes
  execute. Deploy dispatcher changes here: pull the checkout at
  `~/PhpstormProjects/tmux-package/dispatcher` + run `install.sh`.
- **Web prod / backend API (NOT directly SSH-reachable):** `tmux.vojta.ai`
  (178.105.96.42) serves the backend + admin (`/admin/fleet`). `console@` is denied
  by publickey from both the dev box and the worker host, and it is not reachable as
  a hop through `remote.vojta.ai`. Web deploys (git pull + Doctrine migrate + asset
  build + cache clear) must be run by the operator, or via access we don't currently
  hold.
- **Backend auth:** machine endpoints use the shared Ed25519 key (signed
  `X-Signature`/`X-Timestamp`/`X-Fingerprint`); admin/fleet write endpoints need an
  admin **Bearer JWT** from `POST /api/v1/login`.

## Deploy order (gate feature)

The dispatcher's per-lane gate is registry-driven: `worker-up.sh` materialises
`gate-<lane>.sh` from each binding's `gateUrl`. **Deploy the web side first** — if the
dispatcher changes land while the DB has no `gateUrl`, `worker-up` clears existing
gate files and a VPN-gated lane (previo/previo2) starts dispatching unguarded.
Order: web (migrate + API) → set `gateUrl` on the bindings → dispatcher host.
