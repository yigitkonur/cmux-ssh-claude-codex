#!/usr/bin/env bats
# Tests for lib/hook-codex.sh — 6 events, session prefix, policy emission,
# stop-block integration, fail-open.

setup() {
  export CC_SSH_HOME="$BATS_TEST_TMPDIR/cc-ssh"
  export CC_SSH_STATE_DIR="$CC_SSH_HOME/state"
  export CC_SSH_LOG_DIR="$CC_SSH_HOME/log"
  export CC_SSH_LOG_FILE="$CC_SSH_LOG_DIR/current.log"
  export CC_SSH_BIN_DIR="${BATS_TEST_DIRNAME}/../../bin"
  export CC_SSH_POLICY_FILE="$CC_SSH_HOME/policy.toml"
  export CC_SSH_BYPASS_FILE="$CC_SSH_HOME/.bypass-until"
  export CC_SSH_STOP_BLOCK_ACK="$CC_SSH_HOME/state/.stop-block-ack"
  export CC_SSH_STOP_BLOCK_FILE="$CC_SSH_HOME/stop-block.toml"
  export CMUX_WORKSPACE_ID="ws-codex"
  export PATH="$BATS_TEST_TMPDIR/stubs:$PATH"
  mkdir -p "$BATS_TEST_TMPDIR/stubs" "$CC_SSH_HOME" "$CC_SSH_STATE_DIR/$CMUX_WORKSPACE_ID"
  cat >"$BATS_TEST_TMPDIR/stubs/cmux" <<'EOF'
#!/usr/bin/env bash
echo "cmux $*" >>"$BATS_TEST_TMPDIR/cmux.log"
EOF
  chmod +x "$BATS_TEST_TMPDIR/stubs/cmux"
  : >"$BATS_TEST_TMPDIR/cmux.log"
  # shellcheck disable=SC1091
  . "${BATS_TEST_DIRNAME}/../../lib/util.sh"
  # shellcheck disable=SC1091
  . "${BATS_TEST_DIRNAME}/../../lib/state.sh"
  # shellcheck disable=SC1091
  . "${BATS_TEST_DIRNAME}/../../lib/cmux-pill.sh"
  # shellcheck disable=SC1091
  . "${BATS_TEST_DIRNAME}/../../lib/cmux-notify.sh"
  # shellcheck disable=SC1091
  . "${BATS_TEST_DIRNAME}/../../lib/policy.sh"
  # shellcheck disable=SC1091
  . "${BATS_TEST_DIRNAME}/../../lib/stop-block.sh"
  # shellcheck disable=SC1091
  . "${BATS_TEST_DIRNAME}/../../lib/credits-roll.sh"
  # shellcheck disable=SC1091
  . "${BATS_TEST_DIRNAME}/../../lib/render-loop.sh"
  ensure_renderer() { :; }
  # shellcheck disable=SC1091
  . "${BATS_TEST_DIRNAME}/../../lib/hook-codex.sh"
  ensure_renderer() { :; }
}

teardown() { rm -rf "$CC_SSH_HOME" "$BATS_TEST_TMPDIR/stubs"; }

_jsonl() {
  local sid="$1"
  cat "$CC_SSH_STATE_DIR/$CMUX_WORKSPACE_ID/codex-$sid.jsonl" 2>/dev/null
}

@test "codex hook exits 0 when CMUX_WORKSPACE_ID unset" {
  unset CMUX_WORKSPACE_ID
  echo '{}' | handle_codex_hook PreToolUse
  [ "$?" -eq 0 ]
}

@test "SessionStart records start with kind=codex and prefix" {
  echo '{"session_id":"abc-123","model":"gpt-5","cwd":"/Users/x/dev/proj","matcher":"startup"}' \
    | handle_codex_hook SessionStart
  [ -f "$CC_SSH_STATE_DIR/$CMUX_WORKSPACE_ID/codex-abc-123.jsonl" ]
  run cat "$CC_SSH_STATE_DIR/$CMUX_WORKSPACE_ID/codex-abc-123.kind"
  [ "$output" = "codex" ]
  run _jsonl "abc-123"
  [[ "$output" == *'"kind":"codex"'* ]]
  [[ "$output" == *'"matcher":"startup"'* ]]
}

@test "SessionStart with matcher=clear truncates prior jsonl" {
  echo '{"session_id":"sx","cwd":"/x","matcher":"startup"}' | handle_codex_hook SessionStart
  echo '{"session_id":"sx","tool_name":"Bash","tool_input":{"command":"ls"}}' | handle_codex_hook PreToolUse
  echo '{"session_id":"sx","cwd":"/x","matcher":"clear"}' | handle_codex_hook SessionStart
  run wc -l <"$CC_SSH_STATE_DIR/$CMUX_WORKSPACE_ID/codex-sx.jsonl"
  # Only one start record after the clear.
  [ "$(echo "$output" | tr -d ' ')" = "1" ]
}

@test "PreToolUse with no policy emits no stdout JSON" {
  local out
  out="$(echo '{"session_id":"sa","tool_name":"Bash","tool_input":{"command":"ls"}}' | handle_codex_hook PreToolUse)"
  # No policy => no decision JSON.
  [ -z "$out" ]
}

@test "PreToolUse with deny rule emits permissionDecision deny" {
  cat >"$CC_SSH_POLICY_FILE" <<'EOF'
[[deny]]
match.tool = "Bash"
match.command_regex = "^rm -rf /"
reason = "no"
EOF
  local out
  out="$(echo '{"session_id":"sa","tool_name":"Bash","tool_input":{"command":"rm -rf /"}}' | handle_codex_hook PreToolUse)"
  echo "$out" | jq -r '.permissionDecision' | grep -q '^deny$'
  echo "$out" | jq -r '.reason' | grep -q '^no$'
}

@test "PreToolUse with allow rule emits permissionDecision allow" {
  cat >"$CC_SSH_POLICY_FILE" <<'EOF'
[[allow]]
match.tool = "Bash"
match.command_regex = "^ls"
EOF
  local out
  out="$(echo '{"session_id":"sa","tool_name":"Bash","tool_input":{"command":"ls -la"}}' | handle_codex_hook PreToolUse)"
  echo "$out" | jq -r '.permissionDecision' | grep -q '^allow$'
}

@test "PostToolUse with non-zero exit_code records ok=false" {
  echo '{"session_id":"sa","tool_name":"Bash","tool_input":{"command":"false"},"tool_response":{"exit_code":1}}' \
    | handle_codex_hook PostToolUse
  run _jsonl "sa"
  [[ "$output" == *'"ok":false'* ]]
}

@test "PostToolUse with error string records ok=false" {
  echo '{"session_id":"sa","tool_name":"Bash","tool_input":{"command":"x"},"tool_response":{"error":"oh no"}}' \
    | handle_codex_hook PostToolUse
  run _jsonl "sa"
  [[ "$output" == *'"ok":false'* ]]
}

@test "PermissionRequest fires cross-workspace alert" {
  export CC_SSH_NOTIFY_DEST="ws-other"
  echo '{"session_id":"sa","tool_name":"Bash","tool_input":{"command":"git push --force"}}' \
    | handle_codex_hook PermissionRequest
  run cat "$BATS_TEST_TMPDIR/cmux.log"
  [[ "$output" == *"notification.create"* ]]
}

@test "Stop with stop_reason=error fires error alert" {
  export CC_SSH_NOTIFY_DEST="ws-other"
  echo '{"session_id":"sa","stop_reason":"error","error":"compile failure"}' \
    | handle_codex_hook Stop
  run cat "$BATS_TEST_TMPDIR/cmux.log"
  [[ "$output" == *"notification.create"* ]]
}

@test "Stop with stop-block enabled and matching rule emits decision block" {
  cat >"$CC_SSH_STOP_BLOCK_FILE" <<'EOF'
[[rule]]
matcher = "(pnpm|npm)[[:space:]]+test"
prompt = "Fix tests."
tool = "Bash"
EOF
  stop_block_enable >/dev/null
  local now
  now="$(date +%s)"
  state_init "codex-sa" "codex"
  state_append_jsonl "codex-sa" "{\"evt\":\"user_prompt_submit\",\"at\":$now}"
  state_append_jsonl "codex-sa" "{\"evt\":\"post_tool\",\"at\":$((now+1)),\"tool\":\"Bash\",\"label\":\"Bash pnpm test\",\"ok\":false}"
  local out
  out="$(echo '{"session_id":"sa","stop_reason":"user_turn_complete"}' | handle_codex_hook Stop)"
  echo "$out" | jq -r '.decision' | grep -q '^block$'
  echo "$out" | jq -r '.reason' | grep -q 'Fix tests'
}

@test "fail-open: malformed JSON exits 0" {
  echo 'not json at all' | handle_codex_hook PreToolUse
  [ "$?" -eq 0 ]
}

@test "format_codex_tool_label handles Bash, apply_patch, mcp__" {
  run format_codex_tool_label "Bash" '{"command":"ls -la"}'
  [[ "$output" == "Bash ls -la" ]]
  run format_codex_tool_label "apply_patch" '{"path":"/Users/x/foo.ts"}'
  [[ "$output" == "apply_patch foo.ts" ]]
  run format_codex_tool_label "mcp__github__create_issue" '{}'
  [[ "$output" == "mcp:github/create_issue" ]]
}
