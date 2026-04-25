#!/usr/bin/env bats
# Tests for lib/credits-roll.sh — title chips, cycling, phase emoji.

setup() {
  export CC_SSH_HOME="$BATS_TEST_TMPDIR/cc-ssh"
  export CC_SSH_LOG_DIR="$CC_SSH_HOME/log"
  export CC_SSH_LOG_FILE="$CC_SSH_LOG_DIR/current.log"
  # shellcheck disable=SC1091
  . "${BATS_TEST_DIRNAME}/../../lib/util.sh"
  # shellcheck disable=SC1091
  . "${BATS_TEST_DIRNAME}/../../lib/credits-roll.sh"
}

teardown() { rm -rf "$CC_SSH_HOME"; }

@test "phase_emoji maps phases" {
  [ "$(phase_emoji ready)" = "🟢" ]
  [ "$(phase_emoji thinking)" = "🧠" ]
  [ "$(phase_emoji working)" = "🛠" ]
  [ "$(phase_emoji waiting)" = "✋" ]
  [ "$(phase_emoji compacting)" = "🌀" ]
  [ "$(phase_emoji done)" = "✅" ]
  [ "$(phase_emoji error)" = "🔴" ]
}

@test "phase_color maps phases" {
  [ "$(phase_color working)" = "#FF9500" ]
  [ "$(phase_color thinking)" = "#5856D6" ]
  [ "$(phase_color waiting)" = "#FF3B30" ]
  [ "$(phase_color done)" = "#34C759" ]
  [ "$(phase_color error)" = "#FF3B30" ]
}

@test "phase_max picks higher priority" {
  [ "$(phase_max working done)" = "working" ]
  [ "$(phase_max error working)" = "error" ]
  [ "$(phase_max ready done)" = "ready" ]
}

@test "format_credits_roll basic single-session" {
  local state title color
  state='{"project":"myrepo","session_count":1,"subagent_count":0,"ops":3,"phase":"working","elapsed_s":42,"current_tool":"Read foo.ts","cycling_lanes":[],"git_branch":"main","git_dirty":false}'
  run format_credits_roll "$state" 0
  [ "$status" -eq 0 ]
  title=$(echo "$output" | jq -r '.title')
  color=$(echo "$output" | jq -r '.color')
  [ "$title" = "📂 myrepo · 3 ops" ]
  [ "$color" = "#FF9500" ]
  echo "$output" | jq -r '.desc' | head -n 1 | grep -q '▶ Read foo.ts'
}

@test "format_credits_roll adds session/subagent chips" {
  local state title
  state='{"project":"app","session_count":2,"subagent_count":3,"ops":12,"phase":"thinking","elapsed_s":120,"cycling_lanes":[],"git_branch":"feat/x","git_dirty":true}'
  run format_credits_roll "$state" 0
  [ "$status" -eq 0 ]
  title=$(echo "$output" | jq -r '.title')
  [[ "$title" == *"2🪟"* ]]
  [[ "$title" == *"3🤖"* ]]
  [[ "$title" == *"git:feat/x*"* ]]
}

@test "format_credits_roll cycles when lanes ≥ 4" {
  local state desc
  state='{"project":"x","session_count":1,"subagent_count":0,"ops":0,"phase":"ready","cycling_lanes":["A","B","C","D","E"],"current_tool":""}'
  # tick 0 -> rows 2..4 = A,B,C
  run format_credits_roll "$state" 0
  [ "$status" -eq 0 ]
  desc=$(echo "$output" | jq -r '.desc')
  [[ "$desc" == *$'\nA\nB\nC\n'* ]]
  # tick 1000 -> rows 2..4 = B,C,D
  run format_credits_roll "$state" 1000
  desc=$(echo "$output" | jq -r '.desc')
  [[ "$desc" == *$'\nB\nC\nD\n'* ]]
  # tick 5000 -> wraps to A,B,C (5 % 5 == 0)
  run format_credits_roll "$state" 5000
  desc=$(echo "$output" | jq -r '.desc')
  [[ "$desc" == *$'\nA\nB\nC\n'* ]]
}

@test "format_credits_roll does not cycle when lanes ≤ 3" {
  local state
  state='{"project":"x","ops":0,"phase":"ready","cycling_lanes":["A","B"],"session_count":1,"subagent_count":0}'
  run format_credits_roll "$state" 0
  [ "$status" -eq 0 ]
  run format_credits_roll "$state" 9999
  [ "$status" -eq 0 ]
}

@test "format_credits_roll truncates long current_tool" {
  local state
  state='{"project":"x","ops":0,"phase":"working","cycling_lanes":[],"current_tool":"Bash this is a very very very long command that exceeds forty chars"}'
  run format_credits_roll "$state" 0
  [ "$status" -eq 0 ]
  # desc-1 should be 40 chars max with ellipsis.
  local desc1
  desc1="$(echo "$output" | jq -r '.desc' | head -n 1)"
  [ "${#desc1}" -le 41 ] || [ "${#desc1}" -le 50 ]
}

@test "format_subagent_row uses agent_type-counter when set" {
  run format_subagent_row "abc-def-1234567" "Explore" "2" "Read" "foo.ts"
  [ "$status" -eq 0 ]
  [[ "$output" == "· explore-2 → Read foo.ts" ]]
}

@test "format_subagent_row falls back to short-id" {
  run format_subagent_row "d2a8f31abcdef" "" "0" "Read" "foo.ts"
  [ "$status" -eq 0 ]
  [[ "$output" == *"abcdef"* ]] || [[ "$output" == *"a8f31"* ]]
}

@test "format_codex_row formats age in seconds and minutes" {
  run format_codex_row "14" "Bash" "ls"
  [[ "$output" == "· 14s Bash ls" ]]
  run format_codex_row "134" "Bash" "ls"
  [[ "$output" == "· 2m14s Bash ls" ]]
}

@test "format_credits_roll done phase yields green color" {
  local state
  state='{"project":"x","ops":1,"phase":"done","cycling_lanes":[],"session_count":1,"subagent_count":0}'
  run format_credits_roll "$state" 0
  echo "$output" | grep -q '#34C759'
}

@test "format_credits_roll error phase yields red and 🔴" {
  local state
  state='{"project":"x","ops":1,"phase":"error","cycling_lanes":[],"session_count":1,"subagent_count":0}'
  run format_credits_roll "$state" 0
  echo "$output" | grep -q '#FF3B30'
  echo "$output" | grep -q '🔴'
}

@test "format_credits_roll surfaces auto-continue suffix in desc-5" {
  local state
  state='{"project":"x","ops":1,"phase":"ready","cycling_lanes":[],"session_count":1,"subagent_count":0,"auto_continue":"2/5"}'
  run format_credits_roll "$state" 0
  [ "$status" -eq 0 ]
  echo "$output" | jq -r '.desc' | grep -q '(auto-continue 2/5)'
}

@test "format_credits_roll omits auto-continue when counter is empty" {
  local state
  state='{"project":"x","ops":1,"phase":"ready","cycling_lanes":[],"session_count":1,"subagent_count":0,"auto_continue":""}'
  run format_credits_roll "$state" 0
  [ "$status" -eq 0 ]
  ! echo "$output" | jq -r '.desc' | grep -q 'auto-continue'
}
