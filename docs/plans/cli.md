# Plan — cli (tmux-cli, Go)

Lane: `cli`. Source on the fleet host: `~/PhpstormProjects/tmux-package/cli` (the dispatcher self-update
builds it with `make install`). Tests are `go test`; `make build` runs gofmt+vet+build.

## Done
- [x] `tmux-cli status --json` — machine-readable per-project worker state (task 213). Feeds the host reporter (dispatcher `status-report.js`).

## Remaining

### C-PLANNER-COLLISION — serialize/merge goals that edit the same files *(task 215, filed, in flight)*
- [ ] The daemon already DETECTS file overlap between concurrent goals (`dep warning: goal-B references <file> produced by goal-A without depends_on edge`) but only logs it at validate time and runs them in parallel worktrees anyway. **Promote that detection into a pre-dispatch constraint:** when two goals' produced/edited file sets overlap, either auto-insert a `depends_on` edge (deterministic order) so they serialize, or merge them — never dispatch both concurrently.
- [ ] Regression test: a plan/decomposition with two goals writing the same file serializes (inferred edge) or merges; reproduction = web task 208 → goal-001/goal-002 both editing `ProjectBinding.php` (cascade-failed the whole web branch on 2026-06-16).
- **Accept:** overlapping goals never run concurrently; the prior collision no longer yields non-converging validation. `go build` + tests green.
- **Why it matters:** this is the bug that forced the web backend to be hand-built instead of dispatched. Fixing it makes multi-goal dispatch reliable for everything below.

### C-PROVISION-SUPPORT — (only if needed) richer state for provisioning
- [ ] If dispatcher `D-PROVISION-ON-COMMAND` needs it, extend `tmux-cli status --json` with a `provisioning` runtimeState (e.g. detect an in-progress clone) and/or a structured `error` field. Likely **not required** — the dispatcher derives provisioning state itself around the clone+start. Confirm during D-PROVISION; mark N/A if the host script covers it.
- **needs:** dispatcher `D-PROVISION-ON-COMMAND` (only if that task surfaces a gap).

> No other cli changes are required for the fleet plane — heartbeat/control/deploy all live in the
> web backend + dispatcher host scripts. Keep this lane light.
