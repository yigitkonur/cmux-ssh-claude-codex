# state.sh — per-workspace, per-session state. All file I/O goes through here.
#
# Layout:
#   $CC_SSH_HOME/state/<wid>/<sid>.jsonl       append-only event log
#   $CC_SSH_HOME/state/<wid>/<sid>.alive       mtime heartbeat
#   $CC_SSH_HOME/state/<wid>/<sid>.kind        "claude" or "codex"
#   $CC_SSH_HOME/state/<wid>/<sid>.stop-block-count   per-session counter
#   $CC_SSH_HOME/state/<wid>/.leader/          mkdir lock for the renderer
#   $CC_SSH_HOME/state/<wid>/.last-render.json cached title/desc/color
#   $CC_SSH_HOME/state/.stop-block-ack         user opt-in
#   $CC_SSH_HOME/state/.bypass-until           UNIX timestamp
#   $CC_SSH_HOME/state/.notify-rate/<rule>     rate-limit window file

[[ -n "${_CC_SSH_STATE_SOURCED:-}" ]] && return 0
_CC_SSH_STATE_SOURCED=1

# Allow util.sh to be loaded after state.sh.
if ! declare -F cc_have >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  . "$(dirname "${BASH_SOURCE[0]}")/util.sh" 2>/dev/null || true
fi

# state_init <sid> <kind> — set up the per-session files.
state_init() {
  local sid="$1" kind="${2:-claude}"
  local wid="${CMUX_WORKSPACE_ID:-}"
  [[ -z "$wid" || -z "$sid" ]] && return 1
  local dir="$CC_SSH_STATE_DIR/$wid"
  cc_ensure_dir "$dir"
  printf '%s' "$kind" >"$dir/$sid.kind"
  : >>"$dir/$sid.alive"
  : >>"$dir/$sid.jsonl"
  return 0
}

# state_touch_alive <sid> — refresh mtime heartbeat.
state_touch_alive() {
  local sid="$1"
  local wid="${CMUX_WORKSPACE_ID:-}"
  [[ -z "$wid" || -z "$sid" ]] && return 0
  local f="$CC_SSH_STATE_DIR/$wid/$sid.alive"
  cc_ensure_dir "$(dirname "$f")"
  : >>"$f"
  # Force mtime update without rewriting (touch -c is the canonical primitive).
  touch -c "$f" 2>/dev/null || true
}

# state_append_jsonl <sid> <json-line> — atomic append.
# POSIX `>>` is atomic for writes <= PIPE_BUF (typically 4096 bytes); each event
# line fits comfortably under that bound.
state_append_jsonl() {
  local sid="$1" line="$2"
  local wid="${CMUX_WORKSPACE_ID:-}"
  [[ -z "$wid" || -z "$sid" ]] && return 0
  local f="$CC_SSH_STATE_DIR/$wid/$sid.jsonl"
  cc_ensure_dir "$(dirname "$f")"
  printf '%s\n' "$line" >>"$f"
}

# state_truncate_jsonl <sid> — clear the event log for the Codex /clear case.
state_truncate_jsonl() {
  local sid="$1"
  local wid="${CMUX_WORKSPACE_ID:-}"
  [[ -z "$wid" || -z "$sid" ]] && return 0
  local f="$CC_SSH_STATE_DIR/$wid/$sid.jsonl"
  : >"$f" 2>/dev/null || true
}

# state_kind <sid> — echo the recorded kind ("claude" or "codex").
state_kind() {
  local sid="$1"
  local wid="${CMUX_WORKSPACE_ID:-}"
  [[ -z "$wid" || -z "$sid" ]] && return 1
  cat "$CC_SSH_STATE_DIR/$wid/$sid.kind" 2>/dev/null
}

# state_project [<wid>] — basename of cwd from the most recent `start` event in
# any session jsonl in the workspace. Falls back to "workspace".
state_project() {
  local wid="${1:-${CMUX_WORKSPACE_ID:-}}"
  [[ -z "$wid" ]] && { printf 'workspace'; return; }
  local dir="$CC_SSH_STATE_DIR/$wid"
  [[ -d "$dir" ]] || { printf 'workspace'; return; }
  local cwd=""
  local f
  # Walk all jsonl files newest-first and pull the last `start` event's cwd.
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    local last
    last="$(grep '"evt":"start"' "$f" 2>/dev/null | tail -n 1)"
    if [[ -n "$last" ]]; then
      cwd="$(printf '%s' "$last" | cc_jq -r '.cwd // empty' 2>/dev/null)"
      [[ -n "$cwd" ]] && break
    fi
  done < <(ls -t "$dir"/*.jsonl 2>/dev/null)
  if [[ -n "$cwd" ]]; then
    basename "$cwd"
  else
    printf 'workspace'
  fi
}

# state_alive_sessions [<wid>] [<idle_ttl>] — list <sid> values whose .alive
# file mtime is within IDLE_TTL seconds (default 60).
state_alive_sessions() {
  local wid="${1:-${CMUX_WORKSPACE_ID:-}}"
  local ttl="${2:-${IDLE_TTL:-60}}"
  local dir="$CC_SSH_STATE_DIR/$wid"
  [[ -d "$dir" ]] || return 0
  local now
  now="$(cc_now_s)"
  local f
  for f in "$dir"/*.alive; do
    [[ -e "$f" ]] || continue
    local mt
    if mt="$(stat -f '%m' "$f" 2>/dev/null)" && [[ -n "$mt" ]]; then :; \
    elif mt="$(stat -c '%Y' "$f" 2>/dev/null)" && [[ -n "$mt" ]]; then :; \
    else continue
    fi
    if (( now - mt <= ttl )); then
      local sid
      sid="$(basename "$f" .alive)"
      printf '%s\n' "$sid"
    fi
  done
}

# state_session_count [<wid>] — count of currently-alive sessions.
state_session_count() {
  state_alive_sessions "$@" | wc -l | tr -d ' '
}
