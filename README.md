# tmux-cli worker dispatcher

The deploy-anywhere control plane that runs autonomous **tmux-cli** workers on a
machine. It is **registry-driven**: it asks the `tmux.vojta.ai` backend which
projects this host should run, provisions each, and keeps one lane-scoped
consume loop alive per project — self-healing, attachable, and idempotent.

Install it once per machine; add a row in the admin registry per project that
machine should host. No per-host script edits.

## What it does

For each project bound to this host in the registry, `worker-up.sh`:

1. **Provisions** — clones the project's git repo to its path if missing.
2. **Ensures the worker session** — a detached tmux session (`supervisor` window
   running `claude --dangerously-skip-permissions` + a `taskvisor` daemon window),
   created via `tmux-cli start`.
3. **Ensures a lane-scoped dispatcher** (`dispatcher.sh <project-path>`, one per
   project) that, whenever the supervisor is idle and the backend has NEW tasks
   in *this project's lane*, sends `/tmux:task-list consume` so taskvisor drains
   the lane in batches.

A per-minute `flock`-guarded cron + `@reboot` re-runs `worker-up.sh`, so any dead
worker or dispatcher is revived within ~60s.

## Components (`bin/`)

| File | Role |
|------|------|
| `worker-up.sh` | Registry-driven bring-up / self-heal: reads the registry for `$(hostname)`, provisions repos, ensures a worker session + dispatcher per project. Run by cron. |
| `dispatcher.sh <project-path>` | The per-project poll loop. Gates on: taskvisor not active, no goal windows, supervisor Claude provably idle (`esc to interrupt` absent, no modal dialog, debounced), and lane `NEW>0`; then sends `/clear` + `/tmux:task-list consume N`. |
| `registry.js [hostname]` | Signed `GET /api/v1/project-bindings` → prints `name<TAB>path<TAB>repo<TAB>branch` lines for this host. |
| `be-queue-count.js <status> [project]` | Signed `GET /api/v1/tasks?status=&project=` → prints the count (the dispatcher's NEW-in-lane gate). |
| `status-report.js [--loop]` | Signed `POST /api/v1/dispatchers/heartbeat` — reports each project's live worker state (session/consuming/idle, current goal, lane NEW) for the web fleet view. One per host. |
| `control-listener.js` | Long-polls `GET /api/v1/dispatchers/commands` and enacts `desiredState` near-instantly: `paused`→touch `PAUSED-<project>`, `running`→clear it, `stopped`→clear+kill the session. One per host. |

Lane = the **project name** (e.g. `cli`, `web`) = a worker's working-folder
basename; the registry maps the name → `{machine, absolute path, repo}`.

## Prerequisites on the target host

- `tmux`, `node`, and **tmux-cli** (`curl -fsSL https://tmux.vojta.ai/install.sh | bash`).
- For projects whose validation runs in Docker (e.g. PHP), Docker + compose.
- The toolchain each hosted project needs to build/validate (e.g. Go for tmux-cli).
- The **Ed25519 signing key** at `keys/private.pem` (gitignored) — the shared
  client key tmux-cli embeds; the Node helpers sign API calls with it.
- A write-enabled **GitHub deploy key** for any private repo the host must clone.

## Deploy

```bash
# 1. put the signing key in place (gitignored, never committed)
cp /secure/path/private.pem keys/private.pem      # or: export TMUX_KEY=/secure/path/private.pem

# 2. install (scripts -> ~/.tmux-cli-worker, key, self-heal cron)
./install.sh

# 3. bring it up now (cron also does this every minute)
~/.tmux-cli-worker/worker-up.sh
```

Override targets with `WORKER_HOME`, `TMUX_CLI_API_URL`, `TMUX_KEY`.

## Operate

```bash
touch ~/.tmux-cli-worker/PAUSED     # stop everything (cron won't revive); rm to resume
tail -f ~/.tmux-cli-worker/dispatcher.log
tmux attach -t "$(tmux ls -F '#{session_name}' | grep -m1 tmux-cli-)"   # watch a worker
```

## Register a project (admin)

In `https://tmux.vojta.ai/admin` → **Projekty**, add a binding: project name
(the lane), hostname (this machine), absolute path, repository, branch. The next
`worker-up.sh` tick clones it (if missing) and starts its worker.

## Notes

- Dispatchers compute their lane once at startup from the project path's basename;
  a project's basename is stable, so they don't need refreshing under normal use.
- The signing key is the only secret. It is gitignored here and installed at
  `~/.tmux-cli-worker/keys/private.pem` (mode 600).
