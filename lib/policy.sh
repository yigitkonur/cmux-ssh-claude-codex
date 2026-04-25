# policy.sh — Codex policy engine.
#
# Reads ~/.cc-ssh/policy.toml (and per-repo overlay) and decides whether
# to emit `permissionDecision: "deny"|"allow"` JSON for `PreToolUse` events.
# Also implements bypass mode and `cc-ssh policy {test,bypass}` admin commands.

[[ -n "${_CC_SSH_POLICY_SOURCED:-}" ]] && return 0
_CC_SSH_POLICY_SOURCED=1

if ! declare -F cc_have >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  . "$(dirname "${BASH_SOURCE[0]}")/util.sh" 2>/dev/null || true
fi

CC_SSH_POLICY_FILE="${CC_SSH_POLICY_FILE:-$CC_SSH_HOME/policy.toml}"
CC_SSH_BYPASS_FILE="${CC_SSH_BYPASS_FILE:-$CC_SSH_HOME/.bypass-until}"
# Last-prompt presence file. Touched by hook handlers on UserPromptSubmit;
# its mtime is the proxy for "user is at the keyboard". Default idle threshold
# is 300 s (configurable per-rule via .idle_seconds).
CC_SSH_PRESENCE_FILE="${CC_SSH_PRESENCE_FILE:-$CC_SSH_HOME/.last-prompt}"
CC_SSH_DEFAULT_IDLE_SECONDS="${CC_SSH_DEFAULT_IDLE_SECONDS:-300}"

# policy_user_idle_seconds — seconds since the last UserPromptSubmit (mtime
# of the presence file). Returns INT_MAX-equivalent (999999) when the file is
# missing so any threshold trips on a cold start.
policy_user_idle_seconds() {
  if [[ ! -e "$CC_SSH_PRESENCE_FILE" ]]; then
    printf '999999'
    return 0
  fi
  local mtime now
  if [[ "$(uname -s)" == "Darwin" ]]; then
    mtime=$(stat -f %m "$CC_SSH_PRESENCE_FILE" 2>/dev/null)
  else
    mtime=$(stat -c %Y "$CC_SSH_PRESENCE_FILE" 2>/dev/null)
  fi
  now=$(cc_now_s)
  [[ -z "$mtime" ]] && { printf '999999'; return 0; }
  local diff=$(( now - mtime ))
  (( diff < 0 )) && diff=0
  printf '%s' "$diff"
}

# policy_touch_presence — bump the mtime of the presence file. Hook handlers
# call this on UserPromptSubmit so the policy engine knows when the user is
# active. No-op (best-effort) if the directory is not writable.
policy_touch_presence() {
  cc_ensure_dir "$(dirname "$CC_SSH_PRESENCE_FILE")" 2>/dev/null || return 0
  : > "$CC_SSH_PRESENCE_FILE" 2>/dev/null || true
  touch "$CC_SSH_PRESENCE_FILE" 2>/dev/null || true
}

# policy_load <out_var_name> — load merged TOML rules into a JSON object via
# stdout; returns 0 on success, 1 if no rules.
#
# Strategy:
#  - If `taplo` is installed, taplo can convert TOML to JSON for us.
#  - Otherwise use a small POSIX-shell fallback parser supporting
#    `[[deny]]`, `[[allow]]`, `[[permission]]` array-of-tables and the
#    `match.*`, `reason`, `prompt`, `target_workspace_id` keys.
policy_load() {
  local files=()
  [[ -r "$CC_SSH_POLICY_FILE" ]] && files+=("$CC_SSH_POLICY_FILE")
  if [[ -n "${CC_SSH_REPO_POLICY_FILE:-}" && -r "$CC_SSH_REPO_POLICY_FILE" ]]; then
    files+=("$CC_SSH_REPO_POLICY_FILE")
  elif [[ -n "${POLICY_CWD:-}" ]]; then
    local repo_pol="${POLICY_CWD}/.cc-ssh/policy.toml"
    [[ -r "$repo_pol" ]] && files+=("$repo_pol")
  fi
  if (( ${#files[@]} == 0 )); then
    printf '{"deny":[],"allow":[],"permission":[]}'
    return 0
  fi

  if cc_have taplo; then
    # taplo can dump TOML as JSON; merge per-file using jq.
    local merged='{"deny":[],"allow":[],"permission":[]}'
    local f json
    for f in "${files[@]}"; do
      json=$(taplo get -f "$f" -o json . 2>/dev/null)
      [[ -z "$json" ]] && continue
      merged=$(printf '%s\n%s' "$merged" "$json" | cc_jq -s '
        .[0] as $a | .[1] as $b
        | {
            deny:       (($a.deny // []) + ($b.deny // [])),
            allow:      (($a.allow // []) + ($b.allow // [])),
            permission: (($a.permission // []) + ($b.permission // []))
          }
      ')
    done
    printf '%s' "$merged"
    return 0
  fi

  # POSIX-shell fallback parser.
  _policy_parse_toml "${files[@]}"
}

# _policy_parse_toml <file...> — minimal TOML->JSON for our schema.
_policy_parse_toml() {
  local f
  local out_deny="[]"
  local out_allow="[]"
  local out_perm="[]"

  for f in "$@"; do
    local current_section=""
    local current_obj="null"
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%%#*}"  # strip comments
      # Trim whitespace.
      line="${line#"${line%%[![:space:]]*}"}"
      line="${line%"${line##*[![:space:]]}"}"
      [[ -z "$line" ]] && continue

      if [[ "$line" =~ ^\[\[(deny|allow|permission)\]\]$ ]]; then
        # Flush prior object into its OWN section, not the new one.
        _policy_flush_obj "$current_section" "$current_obj" out_deny out_allow out_perm
        current_section="${BASH_REMATCH[1]}"
        current_obj='{}'
      elif [[ "$line" =~ ^([A-Za-z0-9_.]+)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
        local key="${BASH_REMATCH[1]}"
        local val="${BASH_REMATCH[2]}"
        # Strip trailing comment after value (rare in our shape).
        # Decode value (string, number, bool, list).
        local jval
        jval=$(_policy_decode_value "$val") || continue
        # Build nested path: key may be `match.tool` etc.
        if [[ "$current_obj" == "null" ]]; then continue; fi
        current_obj=$(printf '%s' "$current_obj" | cc_jq --arg path "$key" --argjson v "$jval" '
          ($path | split(".")) as $parts
          | reduce range(0; ($parts | length)) as $i (.;
              if $i == ($parts | length - 1) then
                setpath($parts; $v)
              else .
              end)
        ')
      fi
    done <"$f"
    # Flush trailing object.
    if [[ "$current_obj" != "null" && "$current_obj" != "" ]]; then
      _policy_flush_obj "$current_section" "$current_obj" out_deny out_allow out_perm
    fi
  done

  cc_jq -nc --argjson d "$out_deny" --argjson a "$out_allow" --argjson p "$out_perm" \
    '{deny:$d,allow:$a,permission:$p}'
}

_policy_flush_obj() {
  local section="$1" obj="$2"
  local _deny_var="$3" _allow_var="$4" _perm_var="$5"
  [[ "$obj" == "null" || "$obj" == "" ]] && return 0
  case "$section" in
    deny)
      printf -v "$_deny_var" '%s' "$(printf '%s' "${!_deny_var}" \
        | cc_jq --argjson o "$obj" '. + [$o]')" ;;
    allow)
      printf -v "$_allow_var" '%s' "$(printf '%s' "${!_allow_var}" \
        | cc_jq --argjson o "$obj" '. + [$o]')" ;;
    permission)
      printf -v "$_perm_var" '%s' "$(printf '%s' "${!_perm_var}" \
        | cc_jq --argjson o "$obj" '. + [$o]')" ;;
  esac
}

_policy_decode_value() {
  local v="$1"
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  if [[ "$v" =~ ^\".*\"$ ]]; then
    # Quoted string: pass through to jq.
    cc_jq -nc --arg s "${v:1:${#v}-2}" '$s' 2>/dev/null
    return
  fi
  if [[ "$v" =~ ^(true|false)$ ]]; then
    printf '%s' "$v"
    return
  fi
  if [[ "$v" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    printf '%s' "$v"
    return
  fi
  if [[ "$v" =~ ^\[.*\]$ ]]; then
    # Array: split by commas, decode each element.
    local body="${v:1:${#v}-2}"
    local parts=()
    local IFS=','
    read -ra parts <<<"$body"
    local arr_json="["
    local first=1 e dec
    for e in "${parts[@]}"; do
      e="${e#"${e%%[![:space:]]*}"}"
      e="${e%"${e##*[![:space:]]}"}"
      [[ -z "$e" ]] && continue
      dec=$(_policy_decode_value "$e")
      if (( first == 1 )); then arr_json="${arr_json}${dec}"; first=0
      else arr_json="${arr_json},${dec}"; fi
    done
    arr_json="${arr_json}]"
    printf '%s' "$arr_json"
    return
  fi
  # Fallback: treat as string.
  cc_jq -nc --arg s "$v" '$s' 2>/dev/null
}

# policy_bypass_active — return 0 if bypass timestamp is in the future.
policy_bypass_active() {
  [[ -r "$CC_SSH_BYPASS_FILE" ]] || return 1
  local until now
  until="$(cat "$CC_SSH_BYPASS_FILE" 2>/dev/null)"
  now="$(cc_now_s)"
  [[ -n "$until" ]] && (( until > now )) && return 0
  return 1
}

# policy_bypass_remaining — echo "Hh:Mm:Ss" or empty.
policy_bypass_remaining() {
  policy_bypass_active || { printf ''; return; }
  local until now diff
  until="$(cat "$CC_SSH_BYPASS_FILE" 2>/dev/null)"
  now="$(cc_now_s)"
  diff=$((until - now))
  if (( diff < 60 )); then printf '%ds' "$diff"
  elif (( diff < 3600 )); then printf '%dm%02ds' $((diff/60)) $((diff%60))
  else printf '%dh%02dm' $((diff/3600)) $(((diff%3600)/60))
  fi
}

# policy_set_bypass <duration> — duration like "10m", "1h", "30s".
policy_set_bypass() {
  local d="$1"
  local secs
  case "$d" in
    *h) secs=$(( ${d%h} * 3600 )) ;;
    *m) secs=$(( ${d%m} * 60 )) ;;
    *s) secs=$(( ${d%s} )) ;;
    *) secs="$d" ;;
  esac
  cc_ensure_dir "$(dirname "$CC_SSH_BYPASS_FILE")"
  printf '%s' "$(( $(cc_now_s) + secs ))" >"$CC_SSH_BYPASS_FILE"
  printf 'Bypass active for %s\n' "$d"
}

# _match_glob <glob> <path> — return 0 if match, 1 if not.
_match_glob() {
  local glob="$1" path="$2"
  # shellcheck disable=SC2254
  case "$path" in
    $glob) return 0 ;;
    *) return 1 ;;
  esac
}

# _rule_matches <rule_json> <event_json> -> 0 if match.
_rule_matches() {
  local rule="$1" event="$2"
  local tool tool_input cwd kind cmd path_field
  tool=$(printf '%s' "$event" | cc_jq -r '.tool_name // .tool // ""')
  cwd=$(printf '%s' "$event" | cc_jq -r '.cwd // ""')
  kind=$(printf '%s' "$event" | cc_jq -r '.session_kind // .kind // "codex"')
  tool_input=$(printf '%s' "$event" | cc_jq -c '.tool_input // {}')
  cmd=$(printf '%s' "$tool_input" | cc_jq -r '.command // ""' 2>/dev/null)
  path_field=$(printf '%s' "$tool_input" | cc_jq -r '.path // .file_path // ""' 2>/dev/null)

  # match.tool — exact, wildcard, or list.
  local m_tool
  m_tool=$(printf '%s' "$rule" | cc_jq -c '.match.tool // null' 2>/dev/null)
  if [[ "$m_tool" != "null" ]]; then
    local mt
    mt=$(printf '%s' "$m_tool" | cc_jq -r '
      if type == "string" then
        if . == "*" then "any" else . end
      elif type == "array" then
        (map(tostring) | join("|"))
      else "" end
    ')
    if [[ "$mt" != "any" && "$mt" != "" ]]; then
      local found=0
      local IFS='|'
      local cand
      for cand in $mt; do
        if [[ "$cand" == "$tool" ]]; then found=1; break; fi
      done
      (( found == 1 )) || return 1
    fi
  fi

  # match.command_regex.
  local m_cmd
  m_cmd=$(printf '%s' "$rule" | cc_jq -r '.match.command_regex // ""')
  if [[ -n "$m_cmd" ]]; then
    [[ "$tool" == "Bash" ]] || return 1
    [[ "$cmd" =~ $m_cmd ]] || return 1
  fi

  # match.path_regex.
  local m_path
  m_path=$(printf '%s' "$rule" | cc_jq -r '.match.path_regex // ""')
  if [[ -n "$m_path" ]]; then
    [[ "$path_field" =~ $m_path ]] || return 1
  fi

  # match.cwd_glob.
  local m_cwd
  m_cwd=$(printf '%s' "$rule" | cc_jq -r '.match.cwd_glob // ""')
  if [[ -n "$m_cwd" ]]; then
    _match_glob "$m_cwd" "$cwd" || return 1
  fi

  # match.session_kind.
  local m_kind
  m_kind=$(printf '%s' "$rule" | cc_jq -r '.match.session_kind // ""')
  if [[ -n "$m_kind" ]]; then
    [[ "$m_kind" == "$kind" ]] || return 1
  fi

  # match.input_field.<key>_regex.
  local m_inputs
  m_inputs=$(printf '%s' "$rule" | cc_jq -c '.match.input_field // {}')
  if [[ "$m_inputs" != "{}" && "$m_inputs" != "null" ]]; then
    local keys k v re
    keys=$(printf '%s' "$m_inputs" | cc_jq -r 'keys[]?' 2>/dev/null)
    while IFS= read -r k; do
      [[ -z "$k" ]] && continue
      re=$(printf '%s' "$m_inputs" | cc_jq -r --arg k "$k" '.[$k]')
      v=$(printf '%s' "$tool_input" | cc_jq -r --arg k "${k%_regex}" '.[$k] // ""')
      [[ "$v" =~ $re ]] || return 1
    done <<<"$keys"
  fi
  return 0
}

# policy_decide <event_json> -> JSON {action, reason?, rule?}
policy_decide() {
  local event="$1"
  if policy_bypass_active; then
    printf '{"action":"passthrough","reason":"bypass active"}'
    return 0
  fi
  local rules
  rules="$(policy_load)"
  local deny allow
  deny=$(printf '%s' "$rules" | cc_jq -c '.deny // []')
  allow=$(printf '%s' "$rules" | cc_jq -c '.allow // []')

  # Deny first.
  local n i rule reason
  n=$(printf '%s' "$deny" | cc_jq -r 'length')
  i=0
  while (( i < n )); do
    rule=$(printf '%s' "$deny" | cc_jq -c ".[$i]")
    if _rule_matches "$rule" "$event"; then
      reason=$(printf '%s' "$rule" | cc_jq -r '.reason // "denied by policy"')
      cc_jq -nc --arg r "$reason" --arg ridx "deny[$i]" \
        '{action:"deny",reason:$r,rule:$ridx}'
      return 0
    fi
    i=$((i + 1))
  done

  # Allow second.
  n=$(printf '%s' "$allow" | cc_jq -r 'length')
  i=0
  while (( i < n )); do
    rule=$(printf '%s' "$allow" | cc_jq -c ".[$i]")
    if _rule_matches "$rule" "$event"; then
      cc_jq -nc --arg ridx "allow[$i]" '{action:"allow",rule:$ridx}'
      return 0
    fi
    i=$((i + 1))
  done

  # Permission rules — auto_deny_when_idle. Evaluated last so explicit
  # deny/allow always take precedence. Only fires when the rule matches the
  # event AND the user has been idle for at least .idle_seconds (default
  # CC_SSH_DEFAULT_IDLE_SECONDS).
  local perm
  perm=$(printf '%s' "$rules" | cc_jq -c '.permission // []')
  n=$(printf '%s' "$perm" | cc_jq -r 'length')
  i=0
  local idle threshold
  while (( i < n )); do
    rule=$(printf '%s' "$perm" | cc_jq -c ".[$i]")
    if [[ "$(printf '%s' "$rule" | cc_jq -r '.type // ""')" == "auto_deny_when_idle" ]]; then
      if _rule_matches "$rule" "$event"; then
        threshold=$(printf '%s' "$rule" | cc_jq -r ".idle_seconds // $CC_SSH_DEFAULT_IDLE_SECONDS")
        idle=$(policy_user_idle_seconds)
        if (( idle >= threshold )); then
          reason=$(printf '%s' "$rule" | cc_jq -r '.reason // "auto-denied: user idle"')
          cc_jq -nc --arg r "$reason" --arg ridx "permission[$i]" \
            --argjson idle "$idle" --argjson thr "$threshold" \
            '{action:"deny",reason:($r + " (idle " + ($idle|tostring) + "s ≥ " + ($thr|tostring) + "s)"),rule:$ridx}'
          return 0
        fi
      fi
    fi
    i=$((i + 1))
  done

  printf '{"action":"passthrough"}'
}

# policy_permission_alert <event_json> — for PermissionRequest events; check
# permission rules and fire cross-workspace alerts as needed.
policy_permission_alert() {
  local event="$1"
  local rules
  rules="$(policy_load)"
  local perm
  perm=$(printf '%s' "$rules" | cc_jq -c '.permission // []')
  local n i rule rtype dest
  n=$(printf '%s' "$perm" | cc_jq -r 'length')
  i=0
  while (( i < n )); do
    rule=$(printf '%s' "$perm" | cc_jq -c ".[$i]")
    rtype=$(printf '%s' "$rule" | cc_jq -r '.type // ""')
    if [[ "$rtype" == "cross_workspace_alert" ]]; then
      if _rule_matches "$rule" "$event"; then
        dest=$(printf '%s' "$rule" | cc_jq -r '.target_workspace_id // ""')
        local title body project tool
        title=$(printf '%s' "$rule" | cc_jq -r '.title // "Codex permission needed"')
        project=$(state_project 2>/dev/null || echo "workspace")
        tool=$(printf '%s' "$event" | cc_jq -r '.tool_name // ""')
        body="${project} · ${tool}"
        cc_notify_cross_workspace "$title" "$body" \
          --rule "permission_alert[$i]" \
          ${dest:+--workspace "$dest"}
      fi
    elif [[ "$rtype" == "auto_deny_when_idle" ]]; then
      # Idle-based denial is handled inline in policy_decide so the deny
      # decision propagates to the Codex hook handler. This branch is left
      # here so policy_load doesn't need a separate type-allowlist.
      :
    fi
    i=$((i + 1))
  done
}

# policy_cli — admin subcommand handler used by `cc-ssh policy ...`.
policy_cli() {
  local sub="${1:-}"
  shift || true
  case "$sub" in
    test)
      local event="${1:-}"
      if [[ -z "$event" ]]; then
        echo "usage: cc-ssh policy test <event-json>" >&2
        return 2
      fi
      policy_decide "$event"
      echo
      ;;
    bypass)
      local d=""
      while [[ "$#" -gt 0 ]]; do
        case "$1" in
          --duration) d="${2:-}"; shift 2 ;;
          *) shift ;;
        esac
      done
      [[ -z "$d" ]] && { echo "usage: cc-ssh policy bypass --duration <Xs|Xm|Xh>" >&2; return 2; }
      policy_set_bypass "$d"
      ;;
    show|list)
      policy_load
      echo
      ;;
    *)
      echo "usage: cc-ssh policy {test,bypass,show}" >&2
      return 2
      ;;
  esac
}
