# cmux-notify.sh — cross-workspace notification helper with rate-limiting.
#
# Wraps `cmux rpc notification.create`. Resolves the destination workspace via
# (in order): explicit --workspace flag → $CC_SSH_NOTIFY_DEST →
# config.toml notify_dest → first non-active workspace from `cmux list-workspaces`.
# If only the active workspace is available, the alert is dropped (cmux silently
# suppresses active-workspace notifications anyway).

[[ -n "${_CC_SSH_NOTIFY_SOURCED:-}" ]] && return 0
_CC_SSH_NOTIFY_SOURCED=1

if ! declare -F cc_have >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  . "$(dirname "${BASH_SOURCE[0]}")/util.sh" 2>/dev/null || true
fi

CC_SSH_NOTIFY_RATE_DIR="${CC_SSH_NOTIFY_RATE_DIR:-$CC_SSH_HOME/state/.notify-rate}"
CC_SSH_NOTIFY_RATE_WINDOW="${CC_SSH_NOTIFY_RATE_WINDOW:-30}"  # seconds
CC_SSH_NOTIFY_RATE_THRESHOLD="${CC_SSH_NOTIFY_RATE_THRESHOLD:-5}"

# _cc_notify_resolve_dest — echo a workspace_id to send to (or empty).
_cc_notify_resolve_dest() {
  local explicit="$1"
  if [[ -n "$explicit" ]]; then
    printf '%s' "$explicit"
    return
  fi
  if [[ -n "${CC_SSH_NOTIFY_DEST:-}" ]]; then
    printf '%s' "$CC_SSH_NOTIFY_DEST"
    return
  fi
  # Try config.toml.
  local cfg="$CC_SSH_HOME/config.toml"
  if [[ -r "$cfg" ]]; then
    local from_cfg
    from_cfg="$(grep -E '^[[:space:]]*notify_dest[[:space:]]*=' "$cfg" 2>/dev/null \
      | head -n 1 | sed -E 's/.*=[[:space:]]*"?([^"]+)"?.*/\1/')"
    if [[ -n "$from_cfg" ]]; then
      printf '%s' "$from_cfg"
      return
    fi
  fi
  # Last-resort: first non-active workspace from cmux list-workspaces.
  if cc_have cmux && cc_have jq; then
    cmux list-workspaces --json 2>/dev/null \
      | jq -r --arg active "${CMUX_WORKSPACE_ID:-}" \
          '.workspaces[]? | select(.id != $active) | .id' 2>/dev/null \
      | head -n 1
  fi
}

# _cc_notify_rate_check <rule> — return code 0 = allow & log; 1 = suppressed;
# also echoes a hint suffix on stdout when the threshold is hit.
_cc_notify_rate_check() {
  local rule="${1:-_default}"
  cc_ensure_dir "$CC_SSH_NOTIFY_RATE_DIR"
  local f="$CC_SSH_NOTIFY_RATE_DIR/${rule//\//_}"
  local now win
  now="$(cc_now_s)"
  win="$CC_SSH_NOTIFY_RATE_WINDOW"
  local count first hint=""
  if [[ -r "$f" ]]; then
    # Format: <first_ts> <count>
    first="$(awk 'NR==1{print $1}' "$f" 2>/dev/null || echo "$now")"
    count="$(awk 'NR==1{print $2}' "$f" 2>/dev/null || echo 0)"
    if (( now - first > win )); then
      first="$now"
      count=0
    fi
  else
    first="$now"
    count=0
  fi
  count=$((count + 1))
  printf '%s %s\n' "$first" "$count" >"$f.tmp"
  mv -f "$f.tmp" "$f" 2>/dev/null || true

  if (( count == 1 )); then
    return 0
  fi
  if (( count == CC_SSH_NOTIFY_RATE_THRESHOLD )); then
    printf '%s' "(blocked $count× in ${win}s — review your policy)"
    return 0
  fi
  if (( count > CC_SSH_NOTIFY_RATE_THRESHOLD )); then
    return 1
  fi
  return 0
}

# cc_notify_cross_workspace <title> <body> [--workspace <id>] [--rule <name>]
cc_notify_cross_workspace() {
  local title="" body="" ws="" rule=""
  if [[ "$#" -gt 0 ]]; then
    title="$1"; shift
  fi
  if [[ "$#" -gt 0 && "${1:-}" != --* ]]; then
    body="$1"; shift
  fi
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --workspace) ws="${2:-}"; shift 2 ;;
      --rule)      rule="${2:-}"; shift 2 ;;
      *) shift ;;
    esac
  done

  if [[ -z "$title" ]]; then
    cc_log warn "cc_notify_cross_workspace called without title"
    return 0
  fi

  local hint
  if ! hint="$(_cc_notify_rate_check "${rule:-_default}")"; then
    cc_log info "notify suppressed by rate limit (rule=${rule:-_default}): $title"
    return 0
  fi
  if [[ -n "$hint" ]]; then
    body="${body}${body:+ }$hint"
  fi

  local dest
  dest="$(_cc_notify_resolve_dest "$ws")"
  if [[ -z "$dest" ]]; then
    cc_log warn "no notify_dest available; dropping: $title"
    return 0
  fi
  if [[ "$dest" == "${CMUX_WORKSPACE_ID:-}" ]]; then
    cc_log warn "notify_dest equals active workspace; alert would be suppressed: $title"
    return 0
  fi

  if ! cc_have cmux; then
    cc_log warn "cmux CLI missing; cannot fire notification: $title"
    return 0
  fi
  local payload
  if cc_have jq; then
    payload="$(jq -n --arg w "$dest" --arg t "$title" --arg b "$body" \
      '{workspace_id:$w, title:$t, body:$b}')"
  else
    # JSON-escape minimal: drop control bytes, escape quotes/backslashes.
    local esc_t esc_b
    esc_t="$(printf '%s' "$title" | sed 's/\\/\\\\/g; s/"/\\"/g')"
    esc_b="$(printf '%s' "$body"  | sed 's/\\/\\\\/g; s/"/\\"/g')"
    payload="{\"workspace_id\":\"$dest\",\"title\":\"$esc_t\",\"body\":\"$esc_b\"}"
  fi
  cmux rpc notification.create "$payload" >/dev/null 2>&1 || \
    cc_log warn "cmux rpc notification.create failed (dest=$dest)"
}
