#!/usr/bin/env bats
# Golden-output tests for lib/install-claude.sh.

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

@test "first install creates settings.json with marker block" {
  install_claude --yes >/dev/null
  [ -f "$HOME/.claude/settings.json" ]
  grep -q '// BEGIN cc-ssh hooks' "$HOME/.claude/settings.json"
  grep -q '// END cc-ssh hooks' "$HOME/.claude/settings.json"
}

@test "first install registers all 16 events" {
  install_claude --yes >/dev/null
  for e in SessionStart UserPromptSubmit PreToolUse PostToolUse PostToolUseFailure \
           PermissionRequest Stop StopFailure SubagentStart SubagentStop \
           Notification SessionEnd TaskCompleted PreCompact PostCompact WorktreeCreate; do
    grep -q "\"$e\"" "$HOME/.claude/settings.json" || { echo "missing event: $e"; false; }
  done
}

@test "second install replaces in place without duplication" {
  install_claude --yes >/dev/null
  install_claude --yes >/dev/null
  local n
  n="$(grep -c '// BEGIN cc-ssh hooks' "$HOME/.claude/settings.json")"
  [ "$n" -eq 1 ]
}

@test "preserves existing user hooks alongside cc-ssh block" {
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
  grep -q '/some/user/script' "$HOME/.claude/settings.json"
  grep -q '// BEGIN cc-ssh hooks' "$HOME/.claude/settings.json"
}

@test "uninstall removes only the marker block" {
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
  grep -q '/some/user/script' "$HOME/.claude/settings.json"
  ! grep -q '// BEGIN cc-ssh hooks' "$HOME/.claude/settings.json"
}

@test "uninstall is no-op when nothing installed" {
  mkdir -p "$HOME/.claude"
  echo '{"model": "x"}' >"$HOME/.claude/settings.json"
  run uninstall_claude --yes
  echo "$output" | grep -q 'nothing to uninstall'
}

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
}

@test "--repo writes to .claude/settings.local.json under cwd" {
  cd "$BATS_TEST_TMPDIR"
  install_claude --repo --yes >/dev/null
  [ -f "$BATS_TEST_TMPDIR/.claude/settings.local.json" ]
}
