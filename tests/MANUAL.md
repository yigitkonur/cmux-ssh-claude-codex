# Manual integration test plan (live cmux + SSH host)

These tests require a real cmux nightly running plus an SSH host (`mini` per
spec) with cc-ssh installed. They're documented here as a checklist; the bats
files at `tests/e2e/*.bats` carry corresponding `skip` stubs so the suite
can be wired into CI later.

The fully-automated subset that CAN run on the dev machine lives in:
- `tests/render/render-loop.bats` (renderer crash recovery, leader election)
- `tests/installers/*.bats` (golden-output)
- `tests/policy/*.bats` (policy engine rule matching)
- `tests/stop-block/*.bats` (T-8 simulation)
- `tests/render/hook-claude.bats` (PreToolUse latency spike)

## Prereqs

- macOS or Linux SSH host with cmux nightly `0.63.2-nightly.2489108673901` or later
- `cc-ssh` installed at `~/.cc-ssh/bin/cc-ssh` on the SSH host
- `cc-ssh install --claude --codex --yes` already run on the host
- `notify_dest` configured to a non-active workspace
- A scratch git repo for test sessions

## T-1..T-12 (Claude Code surface) — from `99-strategy/11-test-plan.md`

| ID | Description | Pass criteria |
|---|---|---|
| T-1 | Single Claude session, single tool | Tile shows `▶ Read foo.ts`; clears within 2 s |
| T-2 | 4 subagents cycling | desc-2..4 rotate through all 4 within 4 s; counter shows `4🤖` |
| T-3 | cmux daemon kill recovery | Renderer logs RPC errors, doesn't crash; tile resyncs within 2 s after restart |
| T-4 | Two sessions, leader election | Both sessions share one renderer; tile unions both |
| T-5 | Renderer killed mid-loop | Next hook respawns renderer within `LEADER_TTL` (60 s) |
| T-6 | Cross-workspace permission alert | `🔐 Permission needed` notification lands on `notify_dest` |
| T-7 | Rename before notify pattern | Notification card snapshots tile title from the moment it fires |
| T-8 | jq missing | `cc-ssh hook` works via python3 fallback (slower but functional) |
| T-9 | notify_dest deleted | Hook still exits 0; logs "no notify_dest available" |
| T-10 | PreToolUse 1000× latency | p99 < 50 ms once renderer is alive |
| T-11 | Disk hygiene | jsonl files older than 7 days can be cleaned manually |
| T-12 | Multi-session union | Title shows `2🪟 · 4🤖` with unioned subagent rows |

## T-1..T-20 (Codex surface) — from `99-strategy-codex/11-test-plan-codex.md`

| ID | Description | Pass criteria |
|---|---|---|
| T-1 | SessionStart smoke | Tile updates within 2 s; jsonl has start record |
| T-2 | PreToolUse Bash | desc-1 = `▶ Bash ls`; color = #FF9500 |
| T-3 | PostToolUse | Phase transitions back to ready; ops counter increments |
| T-4 | Multiple Bash cycling | 5 distinct calls cycle desc-2..4 at 1 Hz |
| T-5 | PreToolUse deny rule | `cc-ssh codex-hook PreToolUse` emits `permissionDecision: deny`; Codex shows "Denied by hook" |
| T-6 | PermissionRequest cross-workspace | Notification fires with title `🔐 Codex permission needed` |
| T-7 | Stop clean | desc-5 phase emoji ✅; no decision in stdout |
| T-8 | Stop with stop-block | Failing test triggers auto-continue; counter shows `1/3`; cap reached after 3 |
| T-9 | Stop with stop_reason=error | Cross-workspace alert title `🔴 Codex error` |
| T-10 | Mixed Claude + Codex | Title shows `2🪟 · 1🤖`; desc lanes mix Claude subagents + Codex tools |
| T-11 | PostToolUse feedback | Configured rule emits `decision:"block"` with reason |
| T-12 | Hook timeout grace | Slow hook (>5s) logs timeout; tool runs anyway; recovery on next call |
| T-13 | Policy bypass | `cc-ssh policy bypass --duration 1m` → deny rules ignored; desc-5 shows `⚠ bypass` |
| T-14 | Renderer crash recovery | Killing renderer respawns within 60 s |
| T-15 | SessionStart matcher=clear | jsonl truncated; ops counter resets |
| T-16 | Per-repo policy overlay | `<repo>/.cc-ssh/policy.toml` rules apply only inside that repo |
| T-17 | clear_notifications_on_prompt | Stale notifications cleared when UserPromptSubmit fires |
| T-18 | jq missing fallback | Hooks functional via python3 |
| T-19 | Stop-block ack required | Without ack, stop-block doesn't fire |
| T-20 | Doctor diagnostics | `cc-ssh doctor` reports all checks correctly |

## How to run

```bash
ssh mini
cd ~/scratch/some-repo
cmux  # opens a workspace
# Inside cmux shell:
claude  # for Claude tests
# or
codex   # for Codex tests
```

After each test, capture:
- Tile state (title + desc + color) via `cmux rpc workspace.list`
- Notification state via `cmux rpc notification.list`
- Session jsonl via `cat ~/.cc-ssh/state/$CMUX_WORKSPACE_ID/*.jsonl`
- Log via `cc-ssh log`

Mark each row pass/fail in this file or in a CI run report.
