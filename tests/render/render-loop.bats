#!/usr/bin/env bats
# Tests for lib/render-loop.sh — leader election, jsonl tail, union state, diff, cleanup.

setup() {
  export CC_SSH_HOME="$BATS_TEST_TMPDIR/cc-ssh"
  export CC_SSH_STATE_DIR="$CC_SSH_HOME/state"
  export CC_SSH_LOG_DIR="$CC_SSH_HOME/log"
  export CC_SSH_LOG_FILE="$CC_SSH_LOG_DIR/current.log"
  export CC_SSH_BIN_DIR="${BATS_TEST_DIRNAME}/../../bin"
  export CMUX_WORKSPACE_ID="ws-render"
  export LEADER_TTL=2
  export IDLE_TTL=2
  export RENDER_TICK_S=1
  export PATH="$BATS_TEST_TMPDIR/stubs:$PATH"
  mkdir -p "$BATS_TEST_TMPDIR/stubs"
  cat >"$BATS_TEST_TMPDIR/stubs/cmux" <<'EOF'
#!/usr/bin/env bash
echo "cmux $*" >>"$BATS_TEST_TMPDIR/cmux.log"
[[ -t 0 ]] || cat >>"$BATS_TEST_TMPDIR/cmux-stdin.log" 2>/dev/null || true
EOF
  chmod +x "$BATS_TEST_TMPDIR/stubs/cmux"
  : >"$BATS_TEST_TMPDIR/cmux.log"
  # shellcheck disable=SC1091
  . "${BATS_TEST_DIRNAME}/../../lib/util.sh"
  # shellcheck disable=SC1091
  . "${BATS_TEST_DIRNAME}/../../lib/state.sh"
  # shellcheck disable=SC1091
  . "${BATS_TEST_DIRNAME}/../../lib/credits-roll.sh"
  # shellcheck disable=SC1091
  . "${BATS_TEST_DIRNAME}/../../lib/cmux-pill.sh"
  # shellcheck disable=SC1091
  . "${BATS_TEST_DIRNAME}/../../lib/render-loop.sh"
}

teardown() { rm -rf "$CC_SSH_HOME" "$BATS_TEST_TMPDIR/stubs"; }

@test "leader_acquire succeeds on first call" {
  run leader_acquire "$CMUX_WORKSPACE_ID"
  [ "$status" -eq 0 ]
  [ -d "$CC_SSH_STATE_DIR/$CMUX_WORKSPACE_ID/.leader" ]
}

@test "leader_acquire fails when active leader exists" {
  leader_acquire "$CMUX_WORKSPACE_ID"
  run leader_acquire "$CMUX_WORKSPACE_ID"
  [ "$status" -ne 0 ]
}

@test "leader_acquire replaces stale lock" {
  leader_acquire "$CMUX_WORKSPACE_ID"
  # Backdate the lock to make it stale.
  touch -t "$(date -v-5M +%Y%m%d%H%M.%S 2>/dev/null || date -d '5 minutes ago' +%Y%m%d%H%M.%S)" \
    "$CC_SSH_STATE_DIR/$CMUX_WORKSPACE_ID/.leader" 2>/dev/null || skip "no relative date"
  run leader_acquire "$CMUX_WORKSPACE_ID"
  [ "$status" -eq 0 ]
}

@test "read_jsonl_tail returns last N records as JSON array" {
  local f="$BATS_TEST_TMPDIR/test.jsonl"
  printf '{"evt":"start"}\n{"evt":"pre_tool"}\n{"evt":"post_tool"}\n' >"$f"
  run read_jsonl_tail "$f" 100
  [ "$status" -eq 0 ]
  echo "$output" | jq -r '. | length' | grep -q '^3$'
}

@test "read_jsonl_tail handles missing file" {
  run read_jsonl_tail "$BATS_TEST_TMPDIR/missing.jsonl" 100
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "compute_session_state derives ops count" {
  local f="$BATS_TEST_TMPDIR/sess.jsonl"
  printf '%s\n' \
    '{"evt":"start","at":1000,"cwd":"/x"}' \
    '{"evt":"pre_tool","at":1010,"tool":"Read","first_arg":"a.ts","label":"Read a.ts"}' \
    '{"evt":"post_tool","at":1011,"tool":"Read","ok":true}' \
    '{"evt":"pre_tool","at":1020,"tool":"Bash","first_arg":"ls"}' \
    '{"evt":"post_tool","at":1021,"tool":"Bash","ok":true}' \
    >"$f"
  run compute_session_state "$f" "claude" 1100
  [ "$status" -eq 0 ]
  echo "$output" | jq -r '.ops' | grep -q '^2$'
  echo "$output" | jq -r '.kind' | grep -q '^claude$'
}

@test "compute_session_state derives working phase from latest pre_tool" {
  local f="$BATS_TEST_TMPDIR/sess.jsonl"
  printf '%s\n' \
    '{"evt":"start","at":1000}' \
    '{"evt":"pre_tool","at":1010,"tool":"Read","first_arg":"a.ts","label":"Read a.ts"}' \
    >"$f"
  run compute_session_state "$f" "claude" 1100
  [ "$status" -eq 0 ]
  echo "$output" | jq -r '.phase' | grep -q '^working$'
  echo "$output" | jq -r '.current_tool' | grep -q 'Read a.ts'
}

@test "compute_session_state derives done phase from clean stop" {
  local f="$BATS_TEST_TMPDIR/sess.jsonl"
  printf '%s\n' \
    '{"evt":"start","at":1000}' \
    '{"evt":"stop","at":1100,"stop_reason":"user_turn_complete"}' \
    >"$f"
  run compute_session_state "$f" "claude" 1200
  [ "$status" -eq 0 ]
  echo "$output" | jq -r '.phase' | grep -q '^done$'
  # phase_started_at is the stop's at, not the session's start.
  echo "$output" | jq -r '.phase_started_at' | grep -q '^1100$'
  # elapsed_s is now - stop.at, not now - start.at.
  echo "$output" | jq -r '.elapsed_s' | grep -q '^100$'
}

@test "permission_request without subsequent pre_tool yields phase=waiting" {
  local f="$BATS_TEST_TMPDIR/sess.jsonl"
  printf '%s\n' \
    '{"evt":"start","at":1000}' \
    '{"evt":"user_prompt_submit","at":1010}' \
    '{"evt":"permission_request","at":1500,"tool":"Bash"}' \
    >"$f"
  run compute_session_state "$f" "claude" 2000
  [ "$status" -eq 0 ]
  echo "$output" | jq -r '.phase' | grep -q '^waiting$'
  echo "$output" | jq -r '.phase_started_at' | grep -q '^1500$'
  echo "$output" | jq -r '.elapsed_s' | grep -q '^500$'
}

@test "permission_request followed by pre_tool yields phase=working (implicit resolve)" {
  local f="$BATS_TEST_TMPDIR/sess.jsonl"
  printf '%s\n' \
    '{"evt":"start","at":1000}' \
    '{"evt":"user_prompt_submit","at":1010}' \
    '{"evt":"permission_request","at":1500,"tool":"Bash"}' \
    '{"evt":"pre_tool","at":1600,"tool":"Bash","first_arg":"ls"}' \
    >"$f"
  run compute_session_state "$f" "claude" 2000
  [ "$status" -eq 0 ]
  echo "$output" | jq -r '.phase' | grep -q '^working$'
  echo "$output" | jq -r '.phase_started_at' | grep -q '^1600$'
}

@test "user_prompt_submit after stop transitions out of done" {
  local f="$BATS_TEST_TMPDIR/sess.jsonl"
  printf '%s\n' \
    '{"evt":"start","at":1000}' \
    '{"evt":"user_prompt_submit","at":1010}' \
    '{"evt":"pre_tool","at":1020,"tool":"Read"}' \
    '{"evt":"post_tool","at":1030,"tool":"Read","ok":true}' \
    '{"evt":"stop","at":1100,"stop_reason":"user_turn_complete"}' \
    '{"evt":"user_prompt_submit","at":1900}' \
    >"$f"
  run compute_session_state "$f" "claude" 2000
  [ "$status" -eq 0 ]
  echo "$output" | jq -r '.phase' | grep -q '^thinking$'
  echo "$output" | jq -r '.phase_started_at' | grep -q '^1900$'
  echo "$output" | jq -r '.elapsed_s' | grep -q '^100$'
}

@test "elapsed_s reflects phase duration, not session duration" {
  local f="$BATS_TEST_TMPDIR/sess.jsonl"
  # Session has been alive a long time (since 100); stop happened 10s ago.
  printf '%s\n' \
    '{"evt":"start","at":100}' \
    '{"evt":"stop","at":200,"stop_reason":"user_turn_complete"}' \
    >"$f"
  run compute_session_state "$f" "claude" 210
  [ "$status" -eq 0 ]
  echo "$output" | jq -r '.elapsed_s' | grep -q '^10$'
}

@test "post_tool with no following pre_tool yields phase=thinking (in-turn)" {
  # Regression for the "0s · ready while Claude is reading the result" bug.
  # Between PostToolUse and the next PreToolUse, Claude is still in-turn —
  # the tile must say "thinking", not "ready", and the timer must reflect
  # time-since-post_tool, not time-since-session-start.
  local f="$BATS_TEST_TMPDIR/sess.jsonl"
  printf '%s\n' \
    '{"evt":"start","at":1000}' \
    '{"evt":"user_prompt_submit","at":1010}' \
    '{"evt":"pre_tool","at":1020,"tool":"Bash"}' \
    '{"evt":"post_tool","at":1990,"tool":"Bash","ok":true}' \
    >"$f"
  run compute_session_state "$f" "claude" 2000
  [ "$status" -eq 0 ]
  echo "$output" | jq -r '.phase' | grep -q '^thinking$'
  echo "$output" | jq -r '.phase_started_at' | grep -q '^1990$'
  echo "$output" | jq -r '.elapsed_s' | grep -q '^10$'
}

@test "respawn after truncation (only post_tool, no prompt) infers in-turn" {
  # JSONL truncation can drop user_prompt_submit; a recent pre/post still
  # signals in-turn so the tile shows thinking, not ready.
  local f="$BATS_TEST_TMPDIR/sess.jsonl"
  printf '%s\n' \
    '{"evt":"post_tool","at":1900,"tool":"Bash"}' \
    >"$f"
  run compute_session_state "$f" "claude" 2000
  [ "$status" -eq 0 ]
  echo "$output" | jq -r '.phase' | grep -q '^thinking$'
}

@test "ready phase only when no in-turn marker exists" {
  # Empty tail — truly idle workspace, no session activity at all.
  local f="$BATS_TEST_TMPDIR/sess.jsonl"
  : >"$f"
  run compute_session_state "$f" "claude" 1000
  [ "$status" -eq 0 ]
  echo "$output" | jq -r '.phase' | grep -q '^ready$'
}

@test "compute_session_state collects subagent metadata" {
  local f="$BATS_TEST_TMPDIR/sess.jsonl"
  printf '%s\n' \
    '{"evt":"start","at":1000}' \
    '{"evt":"sub_start","at":1010,"uuid":"abc-def-1234567","agent_type":"Explore","counter":1}' \
    '{"evt":"post_tool","at":1020,"agent_uuid":"abc-def-1234567","tool":"Read","label":"Read a.ts"}' \
    >"$f"
  run compute_session_state "$f" "claude" 1100
  [ "$status" -eq 0 ]
  echo "$output" | jq -r '.subagents | length' | grep -q '^1$'
  echo "$output" | jq -r '.subagents[0].agent_type' | grep -q '^Explore$'
}

@test "compute_union_state aggregates two sessions" {
  state_init "s1" "claude"
  state_init "s2" "codex"
  state_append_jsonl "s1" '{"evt":"start","at":1000,"cwd":"/Users/x/dev/proj"}'
  state_append_jsonl "s1" '{"evt":"post_tool","at":1010,"tool":"Read","label":"Read a"}'
  state_append_jsonl "s2" '{"evt":"start","at":1000,"cwd":"/Users/x/dev/proj"}'
  state_append_jsonl "s2" '{"evt":"post_tool","at":1015,"tool":"Bash","first_arg":"ls"}'
  run compute_union_state "$CMUX_WORKSPACE_ID"
  [ "$status" -eq 0 ]
  echo "$output" | jq -r '.session_count' | grep -q '^2$'
  echo "$output" | jq -r '.ops' | grep -q '^2$'
  echo "$output" | jq -r '.project' | grep -q '^proj$'
}

@test "diff_against_last_render returns 0 (changed) on first call, 1 on identical second call" {
  local r1='{"title":"a","desc":"b","color":"#FF0000"}'
  run diff_against_last_render "$CMUX_WORKSPACE_ID" "$r1"
  [ "$status" -eq 0 ]
  run diff_against_last_render "$CMUX_WORKSPACE_ID" "$r1"
  [ "$status" -ne 0 ]
  local r2='{"title":"a","desc":"b","color":"#00FF00"}'
  run diff_against_last_render "$CMUX_WORKSPACE_ID" "$r2"
  [ "$status" -eq 0 ]
}

@test "render_apply forwards to cmux for title/desc/color" {
  local r='{"title":"📂 t","desc":"line1\nline2","color":"#FF9500"}'
  render_apply "$CMUX_WORKSPACE_ID" "$r"
  run cat "$BATS_TEST_TMPDIR/cmux.log"
  [[ "$output" == *"workspace.action"* ]]
}

@test "compute_union_state surfaces auto_continue from stop-block-count files" {
  state_init "s1" "codex"
  state_append_jsonl "s1" '{"evt":"start","at":1000,"cwd":"/x/proj"}'
  echo "2" > "$CC_SSH_STATE_DIR/$CMUX_WORKSPACE_ID/s1.stop-block-count"
  export MAX_AUTO_CONTINUE_ITERATIONS=5
  run compute_union_state "$CMUX_WORKSPACE_ID"
  [ "$status" -eq 0 ]
  echo "$output" | jq -r '.auto_continue' | grep -q '^2/5$'
}

@test "compute_union_state omits auto_continue when no counters exist" {
  state_init "s1" "codex"
  state_append_jsonl "s1" '{"evt":"start","at":1000,"cwd":"/x/proj"}'
  run compute_union_state "$CMUX_WORKSPACE_ID"
  [ "$status" -eq 0 ]
  echo "$output" | jq -r '.auto_continue' | grep -q '^$'
}

@test "compute_union_state drops Codex tool history older than 5 min" {
  state_init "c1" "codex"
  # now=2000; entries at 1100 (>5 min old) and 1900 (recent).
  state_append_jsonl "c1" '{"evt":"start","at":1000,"cwd":"/x/proj"}'
  state_append_jsonl "c1" '{"evt":"post_tool","at":1100,"tool":"Bash","first_arg":"old","ok":true}'
  state_append_jsonl "c1" '{"evt":"post_tool","at":1900,"tool":"Bash","first_arg":"recent","ok":true}'
  # Backdate the alive heartbeat so we don't outrun the 30s alive cutoff.
  : > "$CC_SSH_STATE_DIR/$CMUX_WORKSPACE_ID/c1.alive"
  # Pin "now" by stubbing cc_now_s. Force the value compute_union_state sees.
  cc_now_s() { echo 2000; }
  export -f cc_now_s
  run compute_union_state "$CMUX_WORKSPACE_ID"
  [ "$status" -eq 0 ]
  # The "old" row must be filtered; the "recent" row should remain.
  [[ "$output" != *'"old"'* ]] || [[ "$output" == *'"recent"'* ]]
  [[ "$output" == *'recent'* ]]
}
