# doctor.sh — `cc-ssh doctor` health checks. Reports pass/warn/fail per check
# and exits non-zero on any failure.

[[ -n "${_CC_SSH_DOCTOR_SOURCED:-}" ]] && return 0
_CC_SSH_DOCTOR_SOURCED=1

if ! declare -F cc_have >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  . "$(dirname "${BASH_SOURCE[0]}")/util.sh" 2>/dev/null || true
fi

# _doc_pass / _doc_warn / _doc_fail / _doc_info — print one check line.
_doc_pass() { printf '✓ %s\n' "$1"; }
_doc_warn() { printf '⚠ %s\n' "$1"; CC_SSH_DOC_WARN_COUNT=$((${CC_SSH_DOC_WARN_COUNT:-0}+1)); }
_doc_fail() { printf '✗ %s\n' "$1"; CC_SSH_DOC_FAIL_COUNT=$((${CC_SSH_DOC_FAIL_COUNT:-0}+1)); }
_doc_info() { printf 'i %s\n' "$1"; }

cc_doctor() {
  CC_SSH_DOC_FAIL_COUNT=0
  CC_SSH_DOC_WARN_COUNT=0

  # 1. cc-ssh binary on PATH.
  local self_path
  self_path="$(command -v cc-ssh 2>/dev/null || true)"
  if [[ -n "$self_path" ]]; then
    _doc_pass "cc-ssh binary on PATH at $self_path"
  else
    _doc_warn "cc-ssh not on PATH (using $CC_SSH_BIN_DIR/cc-ssh)"
  fi

  # 2. State directory writable.
  local state_dir="$CC_SSH_HOME/state"
  cc_ensure_dir "$state_dir"
  if : >"$state_dir/.tmp.test" 2>/dev/null; then
    rm -f "$state_dir/.tmp.test"
    _doc_pass "$state_dir writable"
  else
    _doc_fail "$state_dir not writable"
  fi

  # 3. jq presence.
  if cc_have jq; then
    local v
    v="$(jq --version 2>/dev/null)"
    _doc_pass "jq installed ($v)"
  elif cc_have python3; then
    _doc_warn "jq missing — using python3 fallback (slower; install --claude requires jq)"
  else
    _doc_fail "neither jq nor python3 available"
  fi

  # 4. cmux on PATH.
  if cc_have cmux; then
    _doc_pass "cmux CLI on PATH at $(command -v cmux)"
  else
    _doc_fail "cmux CLI missing on PATH"
  fi

  # 5. Claude hooks registered.
  local cs="$HOME/.claude/settings.json"
  if [[ -r "$cs" ]]; then
    local cnt
    cnt="$(cc_jq -r '[.. | .command? | strings | select(test("/cc-ssh hook "))] | length' "$cs" 2>/dev/null || true)"
    cnt="${cnt:-0}"
    if (( cnt >= 16 )); then
      _doc_pass "$cnt/16 cc-ssh hooks registered in $cs"
    elif (( cnt > 0 )); then
      _doc_fail "$cnt/16 cc-ssh hooks registered in $cs (run: cc-ssh install --claude)"
    else
      _doc_info "Claude hooks not installed (run: cc-ssh install --claude)"
    fi
  else
    _doc_info "$cs not found (Claude Code not configured)"
  fi

  # 6. Codex hooks registered + feature flag.
  local cf="$HOME/.codex/config.toml"
  if [[ -r "$cf" ]]; then
    if grep -q 'BEGIN cc-ssh hooks' "$cf"; then
      local cnt
      cnt="$(grep -c '/cc-ssh codex-hook ' "$cf" 2>/dev/null || true)"
      cnt="${cnt:-0}"
      if (( cnt >= 6 )); then
        _doc_pass "$cnt/6 cc-ssh hooks registered in $cf"
      else
        _doc_fail "$cnt/6 cc-ssh hooks registered in $cf (run: cc-ssh install --codex)"
      fi
    else
      _doc_info "Codex hooks not installed (run: cc-ssh install --codex)"
    fi
    if grep -E '^[[:space:]]*codex_hooks[[:space:]]*=[[:space:]]*true' "$cf" >/dev/null 2>&1; then
      _doc_pass "[features] codex_hooks = true"
    else
      if grep -q 'BEGIN cc-ssh hooks' "$cf"; then
        _doc_fail "[features] codex_hooks = true is missing or false in $cf — Codex will silently ignore all hooks"
      else
        _doc_info "[features] codex_hooks not yet enabled"
      fi
    fi
  else
    _doc_info "$cf not found (Codex CLI not configured)"
  fi

  # 7. Policy file syntax.
  local pol="$CC_SSH_HOME/policy.toml"
  if [[ -r "$pol" ]]; then
    local rule_cnt
    if cc_have taplo; then
      if taplo validate "$pol" >/dev/null 2>&1; then
        rule_cnt="$(grep -c '^\[\[' "$pol" 2>/dev/null || true)"
        rule_cnt="${rule_cnt:-0}"
        _doc_pass "$pol exists ($rule_cnt rules)"
      else
        _doc_fail "$pol has TOML syntax errors (taplo validate failed)"
      fi
    else
      rule_cnt="$(grep -c '^\[\[' "$pol" 2>/dev/null || true)"
      rule_cnt="${rule_cnt:-0}"
      _doc_pass "$pol exists ($rule_cnt rules; taplo not installed for validation)"
    fi
  else
    _doc_info "$pol not present (no Codex policy active)"
  fi

  # 8. Stop-block status.
  local ack="$CC_SSH_HOME/state/.stop-block-ack"
  if [[ -r "$ack" ]]; then
    _doc_pass "stop-block enabled (acknowledged $(cat "$ack" 2>/dev/null))"
  else
    _doc_info "stop-block disabled (run cc-ssh codex enable-stop-block to enable)"
  fi

  # 9. notify_dest valid.
  local cfg="$CC_SSH_HOME/config.toml"
  local dest=""
  if [[ -r "$cfg" ]]; then
    dest=$(grep -E '^[[:space:]]*notify_dest[[:space:]]*=' "$cfg" 2>/dev/null \
      | head -n 1 | sed -E 's/.*=[[:space:]]*"?([^"]+)"?.*/\1/')
  fi
  if [[ -n "${CC_SSH_NOTIFY_DEST:-}" ]]; then
    dest="$CC_SSH_NOTIFY_DEST"
  fi
  if [[ -n "$dest" ]]; then
    if [[ "$dest" == "${CMUX_WORKSPACE_ID:-}" ]]; then
      _doc_fail "notify_dest equals current workspace — alerts will be silently suppressed"
    else
      _doc_pass "notify_dest configured: $dest"
    fi
  else
    _doc_info "notify_dest not configured (will auto-pick a non-active workspace)"
  fi

  # 10. Renderer liveness.
  if [[ -n "${CMUX_WORKSPACE_ID:-}" ]]; then
    local lock="$CC_SSH_HOME/state/$CMUX_WORKSPACE_ID/.leader"
    if [[ -d "$lock" ]]; then
      local mt now diff
      mt="$(stat -f '%m' "$lock" 2>/dev/null || stat -c '%Y' "$lock" 2>/dev/null)"
      now="$(cc_now_s)"
      diff=$((now - mt))
      if (( diff <= ${LEADER_TTL:-60} )); then
        _doc_pass "renderer alive in workspace $CMUX_WORKSPACE_ID (heartbeat ${diff}s ago)"
      else
        _doc_info "stale renderer lock for $CMUX_WORKSPACE_ID (will respawn on next hook)"
      fi
    else
      _doc_info "no renderer running for workspace $CMUX_WORKSPACE_ID (will spawn on next hook event)"
    fi
  else
    _doc_info "CMUX_WORKSPACE_ID unset (run inside a cmux workspace to test renderer liveness)"
  fi

  # Summary.
  local fc="${CC_SSH_DOC_FAIL_COUNT:-0}" wc="${CC_SSH_DOC_WARN_COUNT:-0}"
  if (( fc > 0 )); then
    printf '\nStatus: UNHEALTHY (%d failures, %d warnings)\n' "$fc" "$wc"
    return 1
  else
    if (( wc > 0 )); then
      printf '\nStatus: HEALTHY (%d warnings)\n' "$wc"
    else
      printf '\nStatus: HEALTHY\n'
    fi
    return 0
  fi
}
