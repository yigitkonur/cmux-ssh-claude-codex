#!/usr/bin/env bats
# Golden-output tests for lib/install-claude.sh.
#
# Identification of "our" hook entries is by command shape — any entry whose
# command matches `/cc-ssh hook <Event>$` — not by `// BEGIN/END` text markers.
# Output must always parse as strict JSON (Claude Code v2 rejects JSONC).

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  export CC_SSH_HOME="$HOME/.cc-ssh"
  export CC_SSH_LOG_FILE="$CC_SSH_HOME/log/current.log"
  export CC_SSH_BIN_DIR="${BATS_TEST_DIRNAME}/../../bin"
  mkdir -p "$HOME"
  # shellcheck disable=SC1091
  . "${BATS_TEST_DIRNAME}/../../lib/util.sh"
  # shellcheck disable=SC1091
  . "${BATS_TEST_DIRNAME}/../../lib/install-claude.sh"
}

teardown() { rm -rf "$BATS_TEST_TMPDIR/home"; }

# --- happy path ---------------------------------------------------------------

@test "first install creates strict-JSON settings file" {
  install_claude --yes >/dev/null
  [ -f "$HOME/.claude/settings.json" ]
  jq empty "$HOME/.claude/settings.json"
  ! grep -q '//' "$HOME/.claude/settings.json"
}

@test "first install registers all 16 events" {
  install_claude --yes >/dev/null
  for e in SessionStart UserPromptSubmit PreToolUse PostToolUse PostToolUseFailure \
           PermissionRequest Stop StopFailure SubagentStart SubagentStop \
           Notification SessionEnd TaskCompleted PreCompact PostCompact WorktreeCreate; do
    [ "$(jq -r --arg e "$e" '.hooks[$e] | length' "$HOME/.claude/settings.json")" = "1" ] \
      || { echo "missing or duplicated event: $e"; false; }
  done
}

@test "second install replaces in place without duplication" {
  install_claude --yes >/dev/null
  install_claude --yes >/dev/null
  [ "$(jq -r '.hooks.SessionStart | length' "$HOME/.claude/settings.json")" = "1" ]
  [ "$(jq -r '[.. | .command? | strings | select(test("/cc-ssh hook "))] | length' "$HOME/.claude/settings.json")" = "16" ]
}

@test "every install path produces strict (non-JSONC) JSON" {
  install_claude --yes >/dev/null
  ! grep -q '//' "$HOME/.claude/settings.json"
  jq empty "$HOME/.claude/settings.json"
  install_claude --yes >/dev/null
  ! grep -q '//' "$HOME/.claude/settings.json"
  jq empty "$HOME/.claude/settings.json"
}

# --- coexistence with user hooks ---------------------------------------------

@test "preserves existing user hooks alongside cc-ssh entries" {
  mkdir -p "$HOME/.claude"
  cat >"$HOME/.claude/settings.json" <<'EOF'
{
  "model": "claude-opus-4",
  "hooks": {
    "Stop": [{ "hooks": [{ "type": "command", "command": "/some/user/script" }] }]
  }
}
EOF
  install_claude --yes >/dev/null
  jq empty "$HOME/.claude/settings.json"
  grep -q '/some/user/script' "$HOME/.claude/settings.json"
  [ "$(jq -e '.hooks.Stop | map(.hooks[].command | test("/cc-ssh hook Stop$")) | any' "$HOME/.claude/settings.json")" = "true" ]
}

@test "preserves user hook while replacing ours in same event array" {
  mkdir -p "$HOME/.claude"
  cat >"$HOME/.claude/settings.json" <<'EOF'
{ "hooks": { "Stop": [
  { "hooks": [{ "type": "command", "command": "/some/user/script" }] },
  { "hooks": [{ "type": "command", "command": "/old/cc-ssh hook Stop" }] }
] } }
EOF
  install_claude --yes >/dev/null
  grep -q '/some/user/script' "$HOME/.claude/settings.json"
  ! grep -q '/old/cc-ssh' "$HOME/.claude/settings.json"
  [ "$(jq -r '[.. | .command? | strings | select(test("/cc-ssh hook Stop$"))] | length' "$HOME/.claude/settings.json")" = "1" ]
}

# --- migration heal & idempotency edge cases ---------------------------------

@test "install heals previously-broken JSONC settings file" {
  mkdir -p "$HOME/.claude"
  cat >"$HOME/.claude/settings.json" <<'EOF'
{
  "hooks": {
    // BEGIN cc-ssh hooks
    "Stop": [{ "hooks": [{ "type": "command", "command": "/old/cc-ssh hook Stop" }] }]
    // END cc-ssh hooks
  }
}
EOF
  install_claude --yes >/dev/null
  jq empty "$HOME/.claude/settings.json"
  ! grep -q '//' "$HOME/.claude/settings.json"
  [ "$(jq -r '.hooks.Stop | length' "$HOME/.claude/settings.json")" = "1" ]
  [ "$(jq -r '.hooks.Stop[0].hooks[0].command' "$HOME/.claude/settings.json")" != "/old/cc-ssh hook Stop" ]
}

@test "install collapses two ours-entries from different bin paths" {
  mkdir -p "$HOME/.claude"
  cat >"$HOME/.claude/settings.json" <<'EOF'
{ "hooks": { "Stop": [
  { "hooks": [{ "type": "command", "command": "/old/path/cc-ssh hook Stop" }] },
  { "hooks": [{ "type": "command", "command": "/new/path/cc-ssh hook Stop" }] }
] } }
EOF
  install_claude --yes >/dev/null
  [ "$(jq -r '.hooks.Stop | length' "$HOME/.claude/settings.json")" = "1" ]
  ! grep -q '/old/path' "$HOME/.claude/settings.json"
  ! grep -q '/new/path' "$HOME/.claude/settings.json"
}

@test "install handles non-object .hooks gracefully" {
  mkdir -p "$HOME/.claude"
  echo '{ "hooks": [] }' >"$HOME/.claude/settings.json"
  install_claude --yes >/dev/null
  [ "$(jq -r '.hooks | type' "$HOME/.claude/settings.json")" = "object" ]
  jq empty "$HOME/.claude/settings.json"
  [ "$(jq -r '.hooks | keys | length' "$HOME/.claude/settings.json")" = "16" ]
}

# --- uninstall ---------------------------------------------------------------

@test "uninstall preserves user hooks while dropping ours" {
  mkdir -p "$HOME/.claude"
  cat >"$HOME/.claude/settings.json" <<'EOF'
{
  "model": "claude-opus-4",
  "hooks": {
    "Stop": [{ "hooks": [{ "type": "command", "command": "/some/user/script" }] }]
  }
}
EOF
  install_claude --yes >/dev/null
  uninstall_claude --yes >/dev/null
  jq empty "$HOME/.claude/settings.json"
  grep -q '/some/user/script' "$HOME/.claude/settings.json"
  [ "$(jq -r '[.. | .command? | strings | select(test("/cc-ssh hook "))] | length' "$HOME/.claude/settings.json")" = "0" ]
}

@test "uninstall removes .hooks key entirely when only ours present" {
  install_claude --yes >/dev/null
  uninstall_claude --yes >/dev/null
  jq empty "$HOME/.claude/settings.json"
  [ "$(jq 'has("hooks")' "$HOME/.claude/settings.json")" = "false" ]
}

@test "uninstall is no-op when nothing installed" {
  mkdir -p "$HOME/.claude"
  echo '{"model": "x"}' >"$HOME/.claude/settings.json"
  run uninstall_claude --yes
  echo "$output" | grep -q 'nothing to uninstall'
}

# --- modes & guards ----------------------------------------------------------

@test "dry-run prints without writing" {
  install_claude --yes --dry-run >/dev/null
  [ ! -f "$HOME/.claude/settings.json" ]
}

@test "refuses to modify invalid JSON" {
  mkdir -p "$HOME/.claude"
  echo 'not json {' >"$HOME/.claude/settings.json"
  run install_claude --yes
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'not valid JSON'
}

@test "coexistence detects cmux-claude-pro entries" {
  mkdir -p "$HOME/.claude"
  cat >"$HOME/.claude/settings.json" <<'EOF'
{
  "hooks": {
    "Stop": [{ "hooks": [{ "type": "command", "command": "cmux-claude-pro hook Stop" }] }]
  }
}
EOF
  run install_claude --yes
  echo "$output" | grep -q 'cmux-claude-pro'
  [ "$status" -eq 0 ]
  jq empty "$HOME/.claude/settings.json"
}

@test "--repo writes to .claude/settings.local.json under cwd" {
  cd "$BATS_TEST_TMPDIR"
  install_claude --repo --yes >/dev/null
  [ -f "$BATS_TEST_TMPDIR/.claude/settings.local.json" ]
  jq empty "$BATS_TEST_TMPDIR/.claude/settings.local.json"
}
