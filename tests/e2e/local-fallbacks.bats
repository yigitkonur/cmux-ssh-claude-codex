#!/usr/bin/env bats
# Locally-runnable subset of integration tests that simulate live behaviour
# without an actual cmux daemon: jq fallback, hook-timeout grace,
# renderer-crash recovery (via leader-lock TTL).

setup() {
  export CC_SSH_HOME="$BATS_TEST_TMPDIR/cc-ssh"
  export CC_SSH_STATE_DIR="$CC_SSH_HOME/state"
  export CC_SSH_LOG_DIR="$CC_SSH_HOME/log"
  export CC_SSH_LOG_FILE="$CC_SSH_LOG_DIR/current.log"
  export CC_SSH_BIN_DIR="${BATS_TEST_DIRNAME}/../../bin"
  export CMUX_WORKSPACE_ID="ws-e2e"
  export LEADER_TTL=2
  mkdir -p "$BATS_TEST_TMPDIR/stubs" "$CC_SSH_HOME/state/$CMUX_WORKSPACE_ID"
  cat >"$BATS_TEST_TMPDIR/stubs/cmux" <<'EOF'
#!/usr/bin/env bash
echo "cmux $*" >>"$BATS_TEST_TMPDIR/cmux.log"
EOF
  chmod +x "$BATS_TEST_TMPDIR/stubs/cmux"
  export PATH="$BATS_TEST_TMPDIR/stubs:$PATH"
  : >"$BATS_TEST_TMPDIR/cmux.log"
  # shellcheck disable=SC1091
  . "${BATS_TEST_DIRNAME}/../../lib/util.sh"
  # shellcheck disable=SC1091
  . "${BATS_TEST_DIRNAME}/../../lib/state.sh"
  # shellcheck disable=SC1091
  . "${BATS_TEST_DIRNAME}/../../lib/cmux-pill.sh"
  # shellcheck disable=SC1091
  . "${BATS_TEST_DIRNAME}/../../lib/credits-roll.sh"
  # shellcheck disable=SC1091
  . "${BATS_TEST_DIRNAME}/../../lib/render-loop.sh"
}

teardown() { rm -rf "$CC_SSH_HOME" "$BATS_TEST_TMPDIR/stubs"; }

@test "T-12.5: stale leader lock is replaced after LEADER_TTL" {
  leader_acquire "$CMUX_WORKSPACE_ID"
  [ -d "$CC_SSH_STATE_DIR/$CMUX_WORKSPACE_ID/.leader" ]
  # Backdate the lock to simulate a crashed renderer.
  touch -t "$(date -v-5M +%Y%m%d%H%M.%S 2>/dev/null || date -d '5 minutes ago' +%Y%m%d%H%M.%S)" \
    "$CC_SSH_STATE_DIR/$CMUX_WORKSPACE_ID/.leader" 2>/dev/null || skip "no relative date"
  run leader_acquire "$CMUX_WORKSPACE_ID"
  [ "$status" -eq 0 ]
}

@test "T-12.7: hook timeout grace — slow handler does not deadlock" {
  # Wrap a fake slow hook in `timeout 6` and ensure cc-ssh's hook returns 0
  # without waiting for the full 6 seconds (Codex would time out at 5s).
  if ! command -v timeout >/dev/null 2>&1 && ! command -v gtimeout >/dev/null 2>&1; then
    skip "no GNU timeout available"
  fi
  TO=$(command -v timeout || command -v gtimeout)
  local lib="${BATS_TEST_DIRNAME}/../../lib"
  # Run the hook with a 4s timeout — it should complete well under that.
  # The subprocess re-sources its own helpers so cc_log et al. are available.
  local t0 t1
  t0="$(date +%s)"
  echo '{"session_id":"s1","tool_name":"Read","tool_input":{"file_path":"/x/a.ts"}}' \
    | "$TO" 4 bash -c '
        set -e
        . "$1/util.sh"
        . "$1/state.sh"
        . "$1/cmux-pill.sh"
        . "$1/credits-roll.sh"
        . "$1/render-loop.sh"
        . "$1/cmux-notify.sh"
        ensure_renderer() { :; }
        . "$1/hook-claude.sh"
        handle_claude_hook PreToolUse
      ' _ "$lib"
  t1="$(date +%s)"
  [ "$((t1 - t0))" -lt 4 ]
}

@test "T-12.8: jq missing fallback — hook still functions via python3" {
  # Strip jq from PATH for this single hook call.
  local cleaned
  cleaned="$(echo "$PATH" | tr ':' '\n' | grep -v '/jq$' | paste -sd: -)"
  # We can't easily remove jq directory-wide; instead, override cc_have to
  # report jq missing.
  # shellcheck disable=SC1091
  . "${BATS_TEST_DIRNAME}/../../lib/cmux-notify.sh"
  ensure_renderer() { :; }
  # shellcheck disable=SC1091
  . "${BATS_TEST_DIRNAME}/../../lib/hook-claude.sh"
  cc_have() { case "$1" in jq) return 1 ;; *) command -v "$1" >/dev/null 2>&1 ;; esac; }
  echo '{"session_id":"s1","cwd":"/x","model":"claude"}' | handle_claude_hook SessionStart
  # The fallback path may produce slightly less precise jsonl, but the hook
  # must still exit 0 and not crash.
  [ "$?" -eq 0 ]
}
