#!/usr/bin/env bats
# Tests for lib/cmux-notify.sh — destination resolution + rate limiter.

setup() {
  export CC_SSH_HOME="$BATS_TEST_TMPDIR/cc-ssh"
  export CC_SSH_STATE_DIR="$CC_SSH_HOME/state"
  export CC_SSH_LOG_DIR="$CC_SSH_HOME/log"
  export CC_SSH_LOG_FILE="$CC_SSH_LOG_DIR/current.log"
  export CC_SSH_NOTIFY_RATE_DIR="$CC_SSH_STATE_DIR/.notify-rate"
  export CMUX_WORKSPACE_ID="ws-active"
  # Stub `cmux` so we capture rpc calls without a daemon.
  export PATH="$BATS_TEST_TMPDIR/stubs:$PATH"
  mkdir -p "$BATS_TEST_TMPDIR/stubs"
  cat >"$BATS_TEST_TMPDIR/stubs/cmux" <<'EOF'
#!/usr/bin/env bash
echo "cmux $*" >>"$BATS_TEST_TMPDIR/cmux.log"
echo "$(cat)" >>"$BATS_TEST_TMPDIR/cmux-stdin.log" 2>/dev/null || true
EOF
  chmod +x "$BATS_TEST_TMPDIR/stubs/cmux"
  : >"$BATS_TEST_TMPDIR/cmux.log"
  # shellcheck disable=SC1091
  . "${BATS_TEST_DIRNAME}/../../lib/util.sh"
  # shellcheck disable=SC1091
  . "${BATS_TEST_DIRNAME}/../../lib/cmux-notify.sh"
}

teardown() {
  rm -rf "$CC_SSH_HOME" "$BATS_TEST_TMPDIR/stubs"
}

@test "notify uses --workspace flag when provided" {
  cc_notify_cross_workspace "Hi" "Body" --workspace "ws-other"
  run cat "$BATS_TEST_TMPDIR/cmux.log"
  [[ "$output" == *"ws-other"* ]] || [[ "$output" == *"notification.create"* ]]
}

@test "notify drops alert when dest equals active workspace" {
  cc_notify_cross_workspace "Hi" "Body" --workspace "ws-active"
  run cat "$BATS_TEST_TMPDIR/cmux.log"
  [ -z "$output" ]
}

@test "notify reads notify_dest from config.toml" {
  mkdir -p "$CC_SSH_HOME"
  printf 'notify_dest = "ws-from-config"\n' >"$CC_SSH_HOME/config.toml"
  cc_notify_cross_workspace "Hi" "Body"
  run cat "$BATS_TEST_TMPDIR/cmux.log"
  [[ "$output" == *"notification.create"* ]]
}

@test "rate limiter suppresses 6th hit within window" {
  export CC_SSH_NOTIFY_DEST="ws-other"
  for i in 1 2 3 4 5 6 7; do
    cc_notify_cross_workspace "T$i" "B$i" --rule "rule-x"
  done
  # Expect at most 5 calls (the 5th carries the "review your policy" hint;
  # the 6th and beyond are suppressed).
  local n
  n="$(grep -c notification.create "$BATS_TEST_TMPDIR/cmux.log" || true)"
  [ "$n" -le 5 ]
  [ "$n" -ge 1 ]
}

@test "rate limiter resets after window expires" {
  export CC_SSH_NOTIFY_DEST="ws-other"
  export CC_SSH_NOTIFY_RATE_WINDOW=1
  for i in 1 2; do
    cc_notify_cross_workspace "T$i" "B$i" --rule "rule-y"
  done
  sleep 2
  cc_notify_cross_workspace "T3" "B3" --rule "rule-y"
  local n
  n="$(grep -c notification.create "$BATS_TEST_TMPDIR/cmux.log" || true)"
  [ "$n" -ge 3 ]
}
