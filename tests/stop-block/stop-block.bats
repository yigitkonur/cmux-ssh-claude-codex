#!/usr/bin/env bats
# Tests for lib/stop-block.sh — ack gate, rule match, cap, dedup, idle gate.

setup() {
  export CC_SSH_HOME="$BATS_TEST_TMPDIR/cc-ssh"
  export CC_SSH_STATE_DIR="$CC_SSH_HOME/state"
  export CC_SSH_LOG_DIR="$CC_SSH_HOME/log"
  export CC_SSH_LOG_FILE="$CC_SSH_LOG_DIR/current.log"
  export CC_SSH_STOP_BLOCK_ACK="$CC_SSH_HOME/state/.stop-block-ack"
  export CC_SSH_STOP_BLOCK_FILE="$CC_SSH_HOME/stop-block.toml"
  export CMUX_WORKSPACE_ID="ws-sb"
  export MAX_AUTO_CONTINUE_ITERATIONS=3
  export MAX_AUTO_CONTINUE_AGE=1800
  mkdir -p "$CC_SSH_HOME/state/$CMUX_WORKSPACE_ID"
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
}

teardown() { rm -rf "$CC_SSH_HOME"; }

_seed_jsonl() {
  local sid="$1"
  local f="$CC_SSH_HOME/state/$CMUX_WORKSPACE_ID/$sid.jsonl"
  shift
  : >"$f"
  for line in "$@"; do
    printf '%s\n' "$line" >>"$f"
  done
}

@test "stop_block_enabled returns false when ack absent" {
  ! stop_block_enabled
}

@test "stop_block_enable / disable manage ack file" {
  stop_block_enable >/dev/null
  [ -r "$CC_SSH_STOP_BLOCK_ACK" ]
  stop_block_enabled
  stop_block_disable >/dev/null
  ! [ -r "$CC_SSH_STOP_BLOCK_ACK" ]
}

@test "stop_block_decide returns none when not enabled" {
  run stop_block_decide "$CMUX_WORKSPACE_ID" "s1"
  echo "$output" | jq -r '.action' | grep -q '^none$'
  echo "$output" | jq -r '.reason' | grep -q 'not enabled'
}

@test "stop_block_decide returns none when no rules file" {
  stop_block_enable >/dev/null
  run stop_block_decide "$CMUX_WORKSPACE_ID" "s1"
  echo "$output" | jq -r '.action' | grep -q '^none$'
}

@test "stop_block_decide blocks on failing test rule match" {
  stop_block_enable >/dev/null
  cat >"$CC_SSH_STOP_BLOCK_FILE" <<'EOF'
[[rule]]
matcher = "(pnpm|npm)[[:space:]]+test"
prompt = "Fix tests."
tool = "Bash"
EOF
  local now
  now="$(date +%s)"
  _seed_jsonl "s1" \
    "{\"evt\":\"user_prompt_submit\",\"at\":$now}" \
    "{\"evt\":\"post_tool\",\"at\":$((now+1)),\"tool\":\"Bash\",\"label\":\"Bash pnpm test\",\"ok\":false}"
  run stop_block_decide "$CMUX_WORKSPACE_ID" "s1"
  echo "$output" | jq -r '.action' | grep -q '^block$'
  echo "$output" | jq -r '.reason' | grep -q 'Fix tests'
  echo "$output" | jq -r '.count' | grep -q '^1$'
}

@test "stop_block_decide cap stops emitting block after max iterations" {
  stop_block_enable >/dev/null
  cat >"$CC_SSH_STOP_BLOCK_FILE" <<'EOF'
[[rule]]
matcher = "test"
prompt = "Fix."
tool = "Bash"
EOF
  local now
  now="$(date +%s)"
  _seed_jsonl "s1" \
    "{\"evt\":\"user_prompt_submit\",\"at\":$now}" \
    "{\"evt\":\"post_tool\",\"at\":$((now+1)),\"tool\":\"Bash\",\"label\":\"Bash pnpm test\",\"ok\":false}"
  for i in 1 2 3; do
    run stop_block_decide "$CMUX_WORKSPACE_ID" "s1"
    echo "iter=$i action=$(echo "$output" | jq -r '.action')" >&2
  done
  # 4th call should return none (capped at 3).
  run stop_block_decide "$CMUX_WORKSPACE_ID" "s1"
  echo "$output" | jq -r '.action' | grep -q '^none$'
  echo "$output" | jq -r '.reason' | grep -q 'max iterations'
}

@test "stop_block_decide idle gate triggers" {
  stop_block_enable >/dev/null
  cat >"$CC_SSH_STOP_BLOCK_FILE" <<'EOF'
[[rule]]
matcher = "test"
prompt = "Fix."
tool = "Bash"
EOF
  # User prompt 1 hour ago > idle threshold (1800s) -> stale.
  local now old_at
  now="$(date +%s)"
  old_at="$((now - 3600))"
  _seed_jsonl "s1" \
    "{\"evt\":\"user_prompt_submit\",\"at\":$old_at}" \
    "{\"evt\":\"post_tool\",\"at\":$now,\"tool\":\"Bash\",\"label\":\"Bash pnpm test\",\"ok\":false}"
  run stop_block_decide "$CMUX_WORKSPACE_ID" "s1"
  echo "$output" | jq -r '.action' | grep -q '^none$'
  echo "$output" | jq -r '.reason' | grep -q 'idle gate'
}

@test "ship stop-block.toml.example loads and parses" {
  stop_block_enable >/dev/null
  cp "${BATS_TEST_DIRNAME}/../../share/stop-block.toml.example" "$CC_SSH_STOP_BLOCK_FILE"
  run stop_block_load_rules
  [ "$status" -eq 0 ]
  echo "$output" | jq -r 'length' | grep -q '^[1-9]'
}

@test "T-8 simulation: failing test loop reaches cap and exits" {
  stop_block_enable >/dev/null
  cp "${BATS_TEST_DIRNAME}/../../share/stop-block.toml.example" "$CC_SSH_STOP_BLOCK_FILE"
  _seed_jsonl "s1" \
    "{\"evt\":\"user_prompt_submit\",\"at\":$(date +%s)}" \
    '{"evt":"post_tool","at":1010,"tool":"Bash","label":"Bash pnpm test","ok":false}'
  local i action
  local block_count=0 stop_count=0
  for i in 1 2 3 4 5 6; do
    local out
    out="$(stop_block_decide "$CMUX_WORKSPACE_ID" "s1")"
    action="$(echo "$out" | jq -r '.action')"
    if [[ "$action" == "block" ]]; then
      block_count=$((block_count + 1))
    else
      stop_count=$((stop_count + 1))
    fi
  done
  # We expect $MAX_AUTO_CONTINUE_ITERATIONS blocks then "none" forever.
  [ "$block_count" -eq "$MAX_AUTO_CONTINUE_ITERATIONS" ]
  [ "$stop_count" -gt 0 ]
}

@test "codex_admin_cli enable / disable / status" {
  run codex_admin_cli status
  echo "$output" | grep -q 'disabled'
  codex_admin_cli enable-stop-block >/dev/null
  run codex_admin_cli status
  echo "$output" | grep -q 'ENABLED'
  codex_admin_cli disable-stop-block >/dev/null
  run codex_admin_cli status
  echo "$output" | grep -q 'disabled'
}
