# cc-ssh

A POSIX bash + jq tool that bridges Claude Code (16 hook events) and Codex CLI
(6 hook events) into the [cmux](https://cmux.dev) workspace tile. Single
executable, no daemon, no listening port.

## Quickstart

```bash
git clone https://github.com/yigitkonur/cmux-ssh-claude-codex.git cc-ssh
cd cc-ssh
make install                                  # → ~/.cc-ssh/bin/cc-ssh
export PATH="$HOME/.cc-ssh/bin:$PATH"
cc-ssh install --claude                       # register Claude Code hooks
cc-ssh install --codex                        # register Codex CLI hooks
cc-ssh doctor                                 # verify
```

## What this tool does NOT depend on

cc-ssh deliberately uses **only the seven verified-working cmux primitives**:

| primitive | purpose |
|---|---|
| `workspace.action {rename}` | tile title |
| `workspace.action {set_color, clear_color}` | tile color tint |
| `workspace.action {set_description, clear_description}` | 5-line description |
| `notification.create` | cross-workspace alerts |
| `notification.list / .clear` | inbox management |
| `surface.{list, send_text, ...}` | future surface ops |
| `system.identify` | workspace lookup |

It does **NOT** depend on `set_status`, `set_progress`, `log`, `notify_target`,
`mark_unread`, `rename_tab`, `set_agent_pid`, or any other primitive that
silently fails on the current cmux nightly. If/when those ship, only
`lib/cmux-pill.sh` needs to change.

## Architecture

```
~/.cc-ssh/
├── bin/cc-ssh                    # ~80 LOC dispatcher
├── lib/                          # state.sh, render-loop.sh, hook-claude.sh, …
├── share/                        # policy.toml.example, stop-block.toml.example
├── log/current.log               # rotating log
└── state/<workspace_id>/
    ├── <session_id>.jsonl        # append-only event log
    ├── <session_id>.alive        # heartbeat (mtime)
    ├── <session_id>.kind         # "claude" or "codex"
    ├── <session_id>.stop-block-count
    ├── .leader/                  # mkdir lock for renderer
    └── .last-render.json         # diff cache
```

A per-workspace render loop (1 Hz, leader-elected via `mkdir`) polls all
session jsonl tails and writes a unified workspace tile via
`cmux rpc workspace.action`. Hooks are fail-open: any error exits 0 silently.

## Commands

```
cc-ssh hook <event>           # Claude Code hook entry
cc-ssh codex-hook <event>     # Codex CLI hook entry
cc-ssh render-loop <wid>      # spawn renderer for a workspace
cc-ssh notify <title> <body>  # cross-workspace notification
cc-ssh log [--follow]         # tail ~/.cc-ssh/log/current.log
cc-ssh doctor                 # health check
cc-ssh policy {test,bypass}   # policy engine ops
cc-ssh codex {enable,disable}-stop-block
cc-ssh install   --claude|--codex [--repo]
cc-ssh uninstall --claude|--codex [--repo] [--remove-feature-flag]
```

Every subcommand accepts `--help` for inline man-style usage:

```bash
cc-ssh policy --help
cc-ssh install --help
```

## Supported hook events

| Surface | Events |
|---|---|
| Claude Code (16) | `SessionStart` `UserPromptSubmit` `PreToolUse` `PostToolUse` `PostToolUseFailure` `PermissionRequest` `Stop` `StopFailure` `SubagentStart` `SubagentStop` `Notification` `SessionEnd` `TaskCompleted` `PreCompact` `PostCompact` `WorktreeCreate` |
| Codex CLI (6) | `SessionStart` `UserPromptSubmit` `PreToolUse` `PermissionRequest` `PostToolUse` `Stop` |

Hooks are fail-open: any jq parse error or unexpected payload exits 0 silently. Codex requires `[features] codex_hooks = true` in `~/.codex/config.toml` (the installer enforces this).

## Configuration

| File | Purpose |
|---|---|
| `~/.cc-ssh/config.toml` | global settings (`notify_dest`, `on_stop_notify`) |
| `~/.cc-ssh/policy.toml` | Codex deny/allow/permission rules |
| `~/.cc-ssh/stop-block.toml` | Codex auto-continue rules |
| `<repo>/.cc-ssh/policy.toml` | per-repo overlay |
| `<repo>/.cc-ssh/stop-block.toml` | per-repo overlay |

## Testing

```bash
make test                                    # full bats suite
bats tests/installers tests/policy tests/render tests/stop-block
bats tests/e2e/local-fallbacks.bats          # runs without an SSH host
```

Live cmux + SSH host integration tests are documented in
[`tests/MANUAL.md`](tests/MANUAL.md). The `tests/e2e/e2e-{claude,codex}.bats`
files carry `skip` stubs that wire into CI once the SSH harness is available.

## License

MIT.
