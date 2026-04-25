# Changelog

All notable changes to `cc-ssh` are recorded here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[SemVer](https://semver.org).

## [0.1.0] — 2026-04-24

Initial public release. Greenfield; no migration path required.

### Added

- **Dispatcher** (`bin/cc-ssh`): single-binary entry point with subcommands
  `hook`, `codex-hook`, `render-loop`, `notify`, `log`, `doctor`, `policy`,
  `codex`, `install`, `uninstall`. Per-subcommand `--help`. `CC_SSH_DEBUG=1`
  for traced execution into `~/.cc-ssh/log/debug.log`.
- **Claude Code hooks** (`lib/hook-claude.sh`): all 16 events
  (`SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`,
  `PostToolUseFailure`, `PermissionRequest`, `Stop`, `StopFailure`,
  `SubagentStart`, `SubagentStop`, `Notification`, `SessionEnd`,
  `TaskCompleted`, `PreCompact`, `PostCompact`, `WorktreeCreate`).
- **Codex CLI hooks** (`lib/hook-codex.sh`): all 6 events with policy-engine
  integration on `PreToolUse` and stop-block engine on `Stop`.
- **Renderer** (`lib/render-loop.sh`, `lib/credits-roll.sh`): per-workspace
  1 Hz tick, leader-elected via `mkdir(.leader)` with TTL, `IDLE_TTL`
  shutdown, multi-session union state, cycling subagent / tool-history
  lanes, atomic diff against `.last-render.json`.
- **Cmux pill** (`lib/cmux-pill.sh`): wraps the seven verified-working cmux
  primitives — `workspace.action {rename, set_color, clear_color,
  set_description, clear_description}`, `notification.create`,
  `notification.list`, `notification.clear`, `surface.*`, `system.identify`.
  Single chokepoint for forward-compat (`set_status`/`log`/`set_progress`
  upgrade lands here only).
- **State** (`lib/state.sh`): jsonl append, `state_truncate_jsonl` for
  `/clear` matcher, mtime-heartbeat alive tracking, project-name detection.
- **Cross-workspace alerts** (`lib/cmux-notify.sh`): rate-limited
  `cc_notify_cross_workspace`, configurable `notify_dest`, "review your
  policy" suffix on per-rule storms.
- **Policy engine** (`lib/policy.sh`): TOML rules with deny-first /
  allow-second / passthrough order, match clauses (`tool`, `command_regex`,
  `path_regex`, `input_field.<key>_regex`, `cwd_glob`, `session_kind`),
  cross-workspace alert + auto-deny-when-idle hooks, bypass mode with TTL.
  Subcommand `cc-ssh policy {test, bypass}`.
- **Stop-block engine** (`lib/stop-block.sh`): ack-gated auto-continue with
  per-session counter, reason dedup (3× cap), idle-time guard, cap-exhausted
  cross-workspace alert. Renderer surfaces `(auto-continue N/M)` in desc-5.
- **Doctor** (`lib/doctor.sh`): binary on PATH, state-dir writable, jq
  present, hooks registered, `[features] codex_hooks = true`, policy syntax,
  stop-block status, notify_dest validity, renderer alive in workspace.
  Pass/fail/warn/info glyphs, exits non-zero on any failure.
- **Installers** (`lib/install-claude.sh`, `lib/install-codex.sh`):
  marker-bracketed `// BEGIN cc-ssh hooks` / `# BEGIN cc-ssh hooks` block
  splicing, idempotent re-runs, JSON/TOML pre-flight syntax check,
  cmux-claude-pro / cmux-claude-code coexistence detection, per-repo
  override (`--repo`), `--dry-run` and `--yes`, optional Codex
  `--remove-feature-flag` on uninstall.
- **Tests**: bats suites under `tests/{lib,render,policy,stop-block,
  installers,e2e}/` with full coverage of the local-runnable surface
  (renderer crash recovery, leader election, hook latency, jq fallback,
  policy rule matching, stop-block T-8 simulation, installer
  golden-output). Live SSH-host integration tests skip-stubbed in
  `tests/e2e/e2e-{claude,codex}.bats` with the manual procedure in
  `tests/MANUAL.md`.

### Notes

- This release uses **only** the seven cmux primitives that are verified
  working on the current nightly; see `README.md` § "What this tool does
  NOT depend on". When cmux ships `set_status` / `log` / `set_progress`,
  only `lib/cmux-pill.sh` needs to change.
- Claude Code's `~/.claude.json` is runtime-managed; hooks register via
  `~/.claude/settings.json` instead. `cc-ssh install --claude` writes there.

[0.1.0]: https://github.com/yigitkonur/cc-ssh/releases/tag/v0.1.0
