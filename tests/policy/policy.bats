#!/usr/bin/env bats
# Tests for lib/policy.sh — TOML loader, rule matching, deny/allow/passthrough,
# bypass, dry-run.

setup() {
  export CC_SSH_HOME="$BATS_TEST_TMPDIR/cc-ssh"
  export CC_SSH_STATE_DIR="$CC_SSH_HOME/state"
  export CC_SSH_LOG_DIR="$CC_SSH_HOME/log"
  export CC_SSH_LOG_FILE="$CC_SSH_LOG_DIR/current.log"
  export CC_SSH_POLICY_FILE="$CC_SSH_HOME/policy.toml"
  export CC_SSH_BYPASS_FILE="$CC_SSH_HOME/.bypass-until"
  export CC_SSH_PRESENCE_FILE="$CC_SSH_HOME/.last-prompt"
  mkdir -p "$CC_SSH_HOME"
  # shellcheck disable=SC1091
  . "${BATS_TEST_DIRNAME}/../../lib/util.sh"
  # shellcheck disable=SC1091
  . "${BATS_TEST_DIRNAME}/../../lib/policy.sh"
}

teardown() { rm -rf "$CC_SSH_HOME"; }

@test "policy_load returns empty when no rules file" {
  rm -f "$CC_SSH_POLICY_FILE"
  run policy_load
  [ "$status" -eq 0 ]
  [ "$output" = '{"deny":[],"allow":[],"permission":[]}' ]
}

@test "policy_load parses simple deny rule" {
  cat >"$CC_SSH_POLICY_FILE" <<'EOF'
[[deny]]
match.tool = "Bash"
match.command_regex = "^rm -rf /"
reason = "no"
EOF
  run policy_load
  [ "$status" -eq 0 ]
  echo "$output" | jq -r '.deny | length' | grep -q '^1$'
  echo "$output" | jq -r '.deny[0].reason' | grep -q '^no$'
  echo "$output" | jq -r '.deny[0].match.tool' | grep -q '^Bash$'
}

@test "policy_decide deny matches rm -rf" {
  cat >"$CC_SSH_POLICY_FILE" <<'EOF'
[[deny]]
match.tool = "Bash"
match.command_regex = "^rm -rf /"
reason = "no"
EOF
  local event='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"rm -rf /"}}'
  run policy_decide "$event"
  [ "$status" -eq 0 ]
  echo "$output" | jq -r '.action' | grep -q '^deny$'
  echo "$output" | jq -r '.reason' | grep -q '^no$'
  echo "$output" | jq -r '.rule' | grep -q '^deny\[0\]$'
}

@test "policy_decide allow when no deny matches" {
  cat >"$CC_SSH_POLICY_FILE" <<'EOF'
[[deny]]
match.tool = "Bash"
match.command_regex = "^rm -rf /"

[[allow]]
match.tool = "Bash"
match.command_regex = "^ls"
EOF
  local event='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls -la"}}'
  run policy_decide "$event"
  echo "$output" | jq -r '.action' | grep -q '^allow$'
}

@test "policy_decide passthrough when nothing matches" {
  cat >"$CC_SSH_POLICY_FILE" <<'EOF'
[[deny]]
match.tool = "Bash"
match.command_regex = "^rm -rf /"
EOF
  local event='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"echo hi"}}'
  run policy_decide "$event"
  echo "$output" | jq -r '.action' | grep -q '^passthrough$'
}

@test "policy_decide deny wins over allow" {
  cat >"$CC_SSH_POLICY_FILE" <<'EOF'
[[deny]]
match.tool = "Bash"
match.command_regex = "force"
reason = "no force"

[[allow]]
match.tool = "Bash"
match.command_regex = "git push"
EOF
  local event='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git push --force origin main"}}'
  run policy_decide "$event"
  echo "$output" | jq -r '.action' | grep -q '^deny$'
}

@test "policy_decide tool list matches" {
  cat >"$CC_SSH_POLICY_FILE" <<'EOF'
[[deny]]
match.tool = ["Bash", "apply_patch"]
match.path_regex = "^/etc/"
reason = "system files"
EOF
  local event='{"hook_event_name":"PreToolUse","tool_name":"apply_patch","tool_input":{"path":"/etc/passwd"}}'
  run policy_decide "$event"
  echo "$output" | jq -r '.action' | grep -q '^deny$'
}

@test "policy_decide tool wildcard matches everything" {
  cat >"$CC_SSH_POLICY_FILE" <<'EOF'
[[deny]]
match.tool = "*"
reason = "lockdown"
EOF
  local event='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{}}'
  run policy_decide "$event"
  echo "$output" | jq -r '.action' | grep -q '^deny$'
}

@test "policy bypass returns passthrough" {
  cat >"$CC_SSH_POLICY_FILE" <<'EOF'
[[deny]]
match.tool = "*"
reason = "lockdown"
EOF
  policy_set_bypass 60
  local event='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"rm -rf /"}}'
  run policy_decide "$event"
  echo "$output" | jq -r '.action' | grep -q '^passthrough$'
}

@test "policy bypass auto-expires" {
  echo "1" >"$CC_SSH_BYPASS_FILE"  # past timestamp
  cat >"$CC_SSH_POLICY_FILE" <<'EOF'
[[deny]]
match.tool = "*"
reason = "lockdown"
EOF
  local event='{"hook_event_name":"PreToolUse","tool_name":"Bash"}'
  run policy_decide "$event"
  echo "$output" | jq -r '.action' | grep -q '^deny$'
}

@test "policy_cli test prints decision" {
  cat >"$CC_SSH_POLICY_FILE" <<'EOF'
[[deny]]
match.tool = "Bash"
match.command_regex = "^rm -rf /"
reason = "no"
EOF
  run policy_cli test '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"rm -rf /"}}'
  [ "$status" -eq 0 ]
  echo "$output" | jq -r '.action' | grep -q '^deny$'
}

@test "policy_cli bypass writes timestamp" {
  policy_cli bypass --duration 30s
  [ -r "$CC_SSH_BYPASS_FILE" ]
  policy_bypass_active
  [ "$?" -eq 0 ]
}

@test "ship policy.toml.example loads and parses" {
  cp "${BATS_TEST_DIRNAME}/../../share/policy.toml.example" "$CC_SSH_POLICY_FILE"
  run policy_load
  [ "$status" -eq 0 ]
  echo "$output" | jq -r '.deny | length' | grep -q '^[1-9]'
  echo "$output" | jq -r '.allow | length' | grep -q '^[1-9]'
}

@test "ship policy.toml.example denies rm -rf /" {
  cp "${BATS_TEST_DIRNAME}/../../share/policy.toml.example" "$CC_SSH_POLICY_FILE"
  local event='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"rm -rf /"}}'
  run policy_decide "$event"
  echo "$output" | jq -r '.action' | grep -q '^deny$'
}

@test "ship policy.toml.example allows git status" {
  cp "${BATS_TEST_DIRNAME}/../../share/policy.toml.example" "$CC_SSH_POLICY_FILE"
  local event='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git status"}}'
  run policy_decide "$event"
  echo "$output" | jq -r '.action' | grep -q '^allow$'
}

@test "auto_deny_when_idle denies when presence file is stale" {
  cat >"$CC_SSH_POLICY_FILE" <<'EOF'
[[permission]]
type = "auto_deny_when_idle"
match.tool = "Bash"
idle_seconds = 60
reason = "user idle"
EOF
  # Backdate presence to 5 min ago.
  : > "$CC_SSH_PRESENCE_FILE"
  touch -t "$(date -v-5M +%Y%m%d%H%M.%S 2>/dev/null || date -d '5 minutes ago' +%Y%m%d%H%M.%S)" \
    "$CC_SSH_PRESENCE_FILE" 2>/dev/null || skip "no relative date"
  local event='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{}}'
  run policy_decide "$event"
  echo "$output" | jq -r '.action' | grep -q '^deny$'
  echo "$output" | jq -r '.reason' | grep -qi 'idle'
}

@test "auto_deny_when_idle does NOT fire when user is active" {
  cat >"$CC_SSH_POLICY_FILE" <<'EOF'
[[permission]]
type = "auto_deny_when_idle"
match.tool = "*"
idle_seconds = 60
EOF
  policy_touch_presence
  local event='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{}}'
  run policy_decide "$event"
  echo "$output" | jq -r '.action' | grep -q '^passthrough$'
}

@test "auto_deny_when_idle yields to explicit allow" {
  cat >"$CC_SSH_POLICY_FILE" <<'EOF'
[[allow]]
match.tool = "Bash"
match.command_regex = "^ls"

[[permission]]
type = "auto_deny_when_idle"
match.tool = "Bash"
idle_seconds = 60
EOF
  # presence missing → idle = 999999 → would deny without the allow rule.
  rm -f "$CC_SSH_PRESENCE_FILE"
  local event='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
  run policy_decide "$event"
  echo "$output" | jq -r '.action' | grep -q '^allow$'
}

@test "policy_user_idle_seconds returns 999999 when presence file missing" {
  rm -f "$CC_SSH_PRESENCE_FILE"
  run policy_user_idle_seconds
  [ "$output" = "999999" ]
}

@test "policy_touch_presence creates and bumps mtime" {
  rm -f "$CC_SSH_PRESENCE_FILE"
  policy_touch_presence
  [ -e "$CC_SSH_PRESENCE_FILE" ]
  run policy_user_idle_seconds
  [ "$output" -lt 5 ]
}
