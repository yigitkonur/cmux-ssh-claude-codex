#!/usr/bin/env bats
# Tests for lib/doctor.sh — green and broken-fixture snapshot tests.

setup() {
  export CC_SSH_HOME="$BATS_TEST_TMPDIR/cc-ssh"
  export CC_SSH_STATE_DIR="$CC_SSH_HOME/state"
  export CC_SSH_LOG_DIR="$CC_SSH_HOME/log"
  export CC_SSH_LOG_FILE="$CC_SSH_LOG_DIR/current.log"
  export CC_SSH_BIN_DIR="${BATS_TEST_DIRNAME}/../../bin"
  export CMUX_WORKSPACE_ID=""
  export PATH="$BATS_TEST_TMPDIR/stubs:$PATH"
  mkdir -p "$BATS_TEST_TMPDIR/stubs" "$CC_SSH_HOME/state"
  cat >"$BATS_TEST_TMPDIR/stubs/cmux" <<'EOF'
#!/usr/bin/env bash
echo "cmux $*" >>"$BATS_TEST_TMPDIR/cmux.log"
EOF
  chmod +x "$BATS_TEST_TMPDIR/stubs/cmux"
  # Symlink cc-ssh into stubs so command -v finds it.
  ln -sf "${BATS_TEST_DIRNAME}/../../bin/cc-ssh" "$BATS_TEST_TMPDIR/stubs/cc-ssh"
  # shellcheck disable=SC1091
  . "${BATS_TEST_DIRNAME}/../../lib/util.sh"
  # shellcheck disable=SC1091
  . "${BATS_TEST_DIRNAME}/../../lib/doctor.sh"
}

teardown() { rm -rf "$CC_SSH_HOME" "$BATS_TEST_TMPDIR/stubs"; }

@test "doctor reports cc-ssh binary on PATH" {
  run cc_doctor
  echo "$output" | grep -q '✓ cc-ssh binary on PATH'
}

@test "doctor reports state dir writable" {
  run cc_doctor
  echo "$output" | grep -q 'state writable'
}

@test "doctor reports jq present (or python fallback)" {
  run cc_doctor
  echo "$output" | grep -E '(✓ jq installed|⚠ jq missing)' | grep -q .
}

@test "doctor reports cmux on PATH (stub)" {
  run cc_doctor
  echo "$output" | grep -q '✓ cmux CLI on PATH'
}

@test "doctor reports stop-block disabled when ack absent" {
  run cc_doctor
  echo "$output" | grep -q 'stop-block disabled'
}

@test "doctor reports stop-block enabled when ack present" {
  date -u +'%Y-%m-%dT%H:%M:%SZ' >"$CC_SSH_HOME/state/.stop-block-ack"
  run cc_doctor
  echo "$output" | grep -q '✓ stop-block enabled'
}

@test "doctor flags notify_dest equal to current workspace" {
  export CMUX_WORKSPACE_ID="ws-self"
  printf 'notify_dest = "ws-self"\n' >"$CC_SSH_HOME/config.toml"
  run cc_doctor
  echo "$output" | grep -q '✗ notify_dest equals current workspace'
  [ "$status" -ne 0 ]
}

@test "doctor passes notify_dest when set to other workspace" {
  export CMUX_WORKSPACE_ID="ws-self"
  printf 'notify_dest = "ws-other"\n' >"$CC_SSH_HOME/config.toml"
  run cc_doctor
  echo "$output" | grep -q '✓ notify_dest configured: ws-other'
}

@test "doctor flags missing codex_hooks feature flag when hooks block present" {
  mkdir -p "$HOME/.codex"
  # Use a temp HOME so we don't touch the user's real config.
  local tmp
  tmp="$(mktemp -d)"
  HOME="$tmp" mkdir -p "$tmp/.codex"
  cat >"$tmp/.codex/config.toml" <<'EOF'
# BEGIN cc-ssh hooks
[[hooks.SessionStart]]
command = "cc-ssh codex-hook SessionStart"
[[hooks.UserPromptSubmit]]
command = "cc-ssh codex-hook UserPromptSubmit"
[[hooks.PreToolUse]]
command = "cc-ssh codex-hook PreToolUse"
[[hooks.PostToolUse]]
command = "cc-ssh codex-hook PostToolUse"
[[hooks.Stop]]
command = "cc-ssh codex-hook Stop"
[[hooks.PermissionRequest]]
command = "cc-ssh codex-hook PermissionRequest"
# END cc-ssh hooks
EOF
  HOME="$tmp" run cc_doctor
  echo "$output" | grep -q 'codex_hooks = true is missing'
  [ "$status" -ne 0 ]
  rm -rf "$tmp"
}

@test "doctor produces final status line" {
  run cc_doctor
  echo "$output" | tail -n 1 | grep -E '^Status: (HEALTHY|UNHEALTHY)' | grep -q .
}

@test "doctor exits 0 on a clean fixture" {
  # Remove any state that would be flagged as failed.
  rm -rf "$HOME/.claude" "$HOME/.codex" 2>/dev/null || true
  run cc_doctor
  [ "$status" -eq 0 ]
}
