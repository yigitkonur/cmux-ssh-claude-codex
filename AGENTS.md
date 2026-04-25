# AGENTS.md — for any AI editing this repo

`cc-ssh` is a single-binary bash + jq tool that bridges Claude Code (16 hook
events) and Codex CLI (6 hook events) into the cmux workspace tile. Read
**README.md** for the user-facing surface; this file is the rule sheet for
making changes that don't break anyone's terminal.

---

## The seven rules

1. **Hooks must fail open.** Every event handler exits 0 silently on jq parse
   errors, missing fields, or unexpected payloads. Codex defaults to allow
   when a hook crashes; we never want that to be a denial-of-service vector.
2. **No secrets in git.** This repo is public. There are no API keys here
   today and there should never be any. Don't add config files with embedded
   credentials, even in examples — use `<replace-me>` placeholders.
3. **Use only the seven verified-working cmux primitives** (see README.md
   § "What this tool does NOT depend on"). If you reach for `set_status`,
   `set_progress`, `log`, `notify_target`, etc. — stop. Those silently fail
   on the current cmux nightly. The single chokepoint is `lib/cmux-pill.sh`;
   when cmux ships those verbs, only that file changes.
4. **Hot-path budget: <150 ms warm-cache p95.** The PreToolUse hook runs
   on every tool call. Don't add new `jq` invocations on the hot path — fold
   logic into the existing pipeline. Spec target is <50 ms; current
   implementation hits ~90-110 ms on macOS Apple Silicon. Tightening
   requires a single-pass jq rewrite, not more passes.
5. **State is append-only.** `state_append_jsonl` and `state_truncate_jsonl`
   are the only writers. The renderer reads tails. Don't introduce mutable
   state files; if you need new fields, add them to the jsonl event schema.
6. **Installer blocks are marker-bracketed.** `// BEGIN cc-ssh hooks` … `// END`
   for JSONC, `# BEGIN cc-ssh hooks` … `# END` for TOML. Never write outside
   the markers; never assume what's inside is yours. `cmux-claude-pro` and
   `cmux-claude-code` may coexist — preserve them with a stdout notice.
7. **Tests gate everything.** `make test` (= bats over `tests/`) must stay
   green. Shellcheck must stay clean (`shellcheck -x bin/cc-ssh lib/*.sh`).
   The CI workflow at `.github/workflows/ci.yml` enforces both on PR.

---

## Architecture cheat-sheet

```
~/.cc-ssh/
├── bin/cc-ssh              # ~370 LOC dispatcher; subcommands → lib modules
├── lib/                    # 13 modules, each with [[ -n "${_SOURCED}" ]] guard
├── share/                  # *.toml.example for policy + stop-block
└── state/<workspace_id>/
    ├── <session_id>.jsonl  # append-only event log (start, pre_tool, …)
    ├── <session_id>.alive  # heartbeat (mtime)
    ├── <session_id>.kind   # "claude" | "codex"
    ├── <session_id>.stop-block-count
    ├── .leader/            # mkdir() lock for the renderer
    ├── .last-render.json   # diff cache (only fire RPC when changed)
    └── .notify-rate/       # per-rule rate-limiter buckets
```

Key invariants:

- **Leader election** uses `mkdir(.leader)` with `LEADER_TTL` seconds. Stale
  locks are replaced by re-running `mkdir`. There's exactly one renderer
  per workspace.
- **The renderer is fail-tolerant by design.** It can crash, get killed, or
  drift; the next hook fires `_bootstrap_render` and respawns it.
- **`compute_union_state` is the single producer** of the workspace tile JSON.
  All consumers (`format_credits_roll`, `render_apply`) read from its output.
  When you add a derived field (auto-continue, bypass, git status, …), add
  the producer there.
- **Cross-workspace alerts have a per-rule rate limiter.** 5 hits in 30 s
  triggers a "(blocked Nx — review your policy)" suffix; the 6th and beyond
  are dropped silently. Don't bypass this for "important" alerts.

---

## Where to edit what

| Intent | File |
|---|---|
| Add a Claude Code event handler | `lib/hook-claude.sh::handle_claude_hook` |
| Add a Codex event handler | `lib/hook-codex.sh::handle_codex_hook` |
| Surface a new field in the tile | `lib/render-loop.sh::compute_union_state` (producer) + `lib/credits-roll.sh::format_credits_roll` (consumer) |
| Add a policy rule type | `lib/policy.sh::policy_decide` (deny path) or `policy_apply_postdecide` (alert path) |
| Add a stop-block matcher | `lib/stop-block.sh::stop_block_decide` |
| Add a doctor check | `lib/doctor.sh::cc_doctor` |
| Change installer behavior | `lib/install-{claude,codex}.sh` |
| Add a dispatcher subcommand | `bin/cc-ssh` (case block) + `subcommand_help` for `--help` |

---

## Test layout

```
tests/
├── lib/                  # state, notify (rate-limiter)
├── render/               # credits-roll, render-loop, hook-claude, hook-codex
├── policy/               # rule matching, deny/allow/passthrough, idle gate
├── stop-block/           # T-8 simulation, dedup, idle, cap
├── installers/           # JSONC/TOML splice, requirements.toml overlay
├── doctor/               # snapshot output across known-good and broken envs
├── e2e/
│   ├── e2e-claude.bats   # skip-stubs for live SSH harness (T-1 … T-12)
│   ├── e2e-codex.bats    # skip-stubs for live SSH harness (T-1 … T-20)
│   └── local-fallbacks.bats   # T-12.5/7/8 — runnable without an SSH host
└── MANUAL.md             # checklist for live cmux + SSH host runs
```

When you add a feature, also add a test. When a bats test fails on macOS BSD
awk/sed but works on GNU, prefer rewriting in awk + tempfile patterns over
GNU-specific flags — the CI runs Linux but contributors are mostly on macOS.

---

## Forbidden patterns

- `cmux rpc workspace.set_status` / `set_progress` / `log` — not implemented
  in cmux. Use `set_description` (multi-line stack) instead.
- `--no-verify` on commits — the pre-commit hook is the only thing keeping
  shellcheck green.
- `chmod +x lib/*.sh` — libs are sourced, not executed. Only `bin/cc-ssh`
  and `install.sh` are executable.
- Mocking jq or cmux in tests — they're stubbed via `$BATS_TEST_TMPDIR/stubs`
  to keep the assertions honest. Pure unit tests aren't worth much when
  the binary surface is shell + jq.
- Editing `~/.claude.json` from chezmoi or installer code. That file is
  Claude's runtime-managed registry; we register hooks via
  `~/.claude/settings.json` instead. (See `lib/install-claude.sh`.)

---

## Commit discipline

Conventional commits with scope. The scope corresponds to the lib module or
spec area:

- `feat(policy): add auto_deny_when_idle rule type`
- `fix(render): drop tool history older than 5 min`
- `chore(ci): bump bats to 1.13`
- `docs(readme): add testing section`

Every commit message ends with the standard Claude Code coauthor trailer
when the change was Claude-generated.

---

**Golden rule: hooks fail open, primitives stay verified, tests stay green.**
