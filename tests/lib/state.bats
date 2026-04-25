#!/usr/bin/env bats
# Tests for lib/state.sh — state_init, append, touch, truncate, project, alive.

setup() {
  export CC_SSH_HOME="$BATS_TEST_TMPDIR/cc-ssh"
  export CC_SSH_STATE_DIR="$CC_SSH_HOME/state"
  export CC_SSH_LOG_DIR="$CC_SSH_HOME/log"
  export CC_SSH_LOG_FILE="$CC_SSH_LOG_DIR/current.log"
  export CMUX_WORKSPACE_ID="ws-test-$$"
  # shellcheck disable=SC1091
  . "${BATS_TEST_DIRNAME}/../../lib/util.sh"
  # shellcheck disable=SC1091
  . "${BATS_TEST_DIRNAME}/../../lib/state.sh"
}

teardown() {
  rm -rf "$CC_SSH_HOME"
}

@test "state_init creates kind, alive, jsonl files" {
  state_init "sess-1" "claude"
  [ -f "$CC_SSH_STATE_DIR/$CMUX_WORKSPACE_ID/sess-1.kind" ]
  [ -f "$CC_SSH_STATE_DIR/$CMUX_WORKSPACE_ID/sess-1.alive" ]
  [ -f "$CC_SSH_STATE_DIR/$CMUX_WORKSPACE_ID/sess-1.jsonl" ]
  run cat "$CC_SSH_STATE_DIR/$CMUX_WORKSPACE_ID/sess-1.kind"
  [ "$output" = "claude" ]
}

@test "state_init records codex kind" {
  state_init "sess-2" "codex"
  run cat "$CC_SSH_STATE_DIR/$CMUX_WORKSPACE_ID/sess-2.kind"
  [ "$output" = "codex" ]
}

@test "state_append_jsonl appends one line per call" {
  state_init "sess-1" "claude"
  state_append_jsonl "sess-1" '{"evt":"start"}'
  state_append_jsonl "sess-1" '{"evt":"pre_tool"}'
  run wc -l <"$CC_SSH_STATE_DIR/$CMUX_WORKSPACE_ID/sess-1.jsonl"
  [ "$(echo "$output" | tr -d ' ')" = "2" ]
}

@test "state_truncate_jsonl empties the log" {
  state_init "sess-1" "claude"
  state_append_jsonl "sess-1" '{"evt":"start"}'
  state_truncate_jsonl "sess-1"
  run wc -c <"$CC_SSH_STATE_DIR/$CMUX_WORKSPACE_ID/sess-1.jsonl"
  [ "$(echo "$output" | tr -d ' ')" = "0" ]
}

@test "state_touch_alive refreshes mtime" {
  state_init "sess-1" "claude"
  local f="$CC_SSH_STATE_DIR/$CMUX_WORKSPACE_ID/sess-1.alive"
  # Backdate by 5 minutes.
  touch -t "$(date -v-5M +%Y%m%d%H%M.%S 2>/dev/null || date -d '5 minutes ago' +%Y%m%d%H%M.%S)" "$f" 2>/dev/null || skip "no relative date support"
  local before after
  before="$(stat -f '%m' "$f" 2>/dev/null || stat -c '%Y' "$f")"
  state_touch_alive "sess-1"
  after="$(stat -f '%m' "$f" 2>/dev/null || stat -c '%Y' "$f")"
  [ "$after" -gt "$before" ]
}

@test "state_kind echoes recorded kind" {
  state_init "sess-1" "codex"
  run state_kind "sess-1"
  [ "$status" -eq 0 ]
  [ "$output" = "codex" ]
}

@test "state_project pulls cwd from start event" {
  state_init "sess-1" "claude"
  state_append_jsonl "sess-1" '{"evt":"start","cwd":"/Users/yigit/dev/myrepo","kind":"claude"}'
  run state_project
  [ "$output" = "myrepo" ]
}

@test "state_project falls back to 'workspace' when no events" {
  state_init "sess-1" "claude"
  run state_project
  [ "$output" = "workspace" ]
}

@test "state_alive_sessions lists fresh sessions only" {
  state_init "sess-fresh" "claude"
  state_init "sess-stale" "claude"
  # Stale = 2 hours old.
  local stale="$CC_SSH_STATE_DIR/$CMUX_WORKSPACE_ID/sess-stale.alive"
  touch -t "$(date -v-2H +%Y%m%d%H%M.%S 2>/dev/null || date -d '2 hours ago' +%Y%m%d%H%M.%S)" "$stale" 2>/dev/null || skip "no relative date support"
  run state_alive_sessions "$CMUX_WORKSPACE_ID" 60
  [[ "$output" == *"sess-fresh"* ]]
  [[ "$output" != *"sess-stale"* ]]
}

@test "state_init returns 1 when CMUX_WORKSPACE_ID missing" {
  unset CMUX_WORKSPACE_ID
  run state_init "sess-1" "claude"
  [ "$status" -eq 1 ]
}

@test "concurrent appends do not interleave (atomic write)" {
  # Spike A: 5 concurrent processes each appending 100 lines; assert exactly
  # 500 lines and no torn lines (every line parses as JSON or matches schema).
  state_init "sess-x" "claude"
  local f="$CC_SSH_STATE_DIR/$CMUX_WORKSPACE_ID/sess-x.jsonl"
  local i pid
  pids=()
  for i in 1 2 3 4 5; do
    (
      for j in $(seq 1 100); do
        state_append_jsonl "sess-x" "{\"evt\":\"x\",\"i\":$i,\"j\":$j}"
      done
    ) &
    pids+=($!)
  done
  for pid in "${pids[@]}"; do wait "$pid"; done
  run wc -l <"$f"
  [ "$(echo "$output" | tr -d ' ')" = "500" ]
  # Every line should start with `{` and end with `}`.
  local bad
  bad="$(grep -cv '^{.*}$' "$f" || true)"
  [ "$bad" -eq 0 ]
}
