# stop-block.sh — Codex auto-continue engine.
#
# Off by default. Once enabled (`cc-ssh codex enable-stop-block`), the engine
# watches `Stop` events and emits `decision: "block"` on stdout to keep Codex
# working when a known fixable failure is detected (test fail / type-check /
# marker comment). Hard caps + reason dedup + idle gate prevent runaway loops.

[[ -n "${_CC_SSH_STOP_BLOCK_SOURCED:-}" ]] && return 0
_CC_SSH_STOP_BLOCK_SOURCED=1

if ! declare -F cc_have >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  . "$(dirname "${BASH_SOURCE[0]}")/util.sh" 2>/dev/null || true
fi
if ! declare -F state_append_jsonl >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  . "$(dirname "${BASH_SOURCE[0]}")/state.sh" 2>/dev/null || true
fi

CC_SSH_STOP_BLOCK_ACK="${CC_SSH_STOP_BLOCK_ACK:-$CC_SSH_HOME/state/.stop-block-ack}"
CC_SSH_STOP_BLOCK_FILE="${CC_SSH_STOP_BLOCK_FILE:-$CC_SSH_HOME/stop-block.toml}"
MAX_AUTO_CONTINUE_ITERATIONS="${MAX_AUTO_CONTINUE_ITERATIONS:-5}"
MAX_AUTO_CONTINUE_AGE="${MAX_AUTO_CONTINUE_AGE:-1800}"

# stop_block_enabled — return 0 if user has acknowledged enabling.
stop_block_enabled() {
  [[ -r "$CC_SSH_STOP_BLOCK_ACK" ]]
}

# stop_block_enable — write the ack file with the current timestamp.
stop_block_enable() {
  cc_ensure_dir "$(dirname "$CC_SSH_STOP_BLOCK_ACK")"
  date -u +'%Y-%m-%dT%H:%M:%SZ' >"$CC_SSH_STOP_BLOCK_ACK"
  printf 'stop-block enabled at %s\n' "$(cat "$CC_SSH_STOP_BLOCK_ACK")"
  printf '  rules:        %s\n' "$CC_SSH_STOP_BLOCK_FILE"
  printf '  max iters:    %s\n' "$MAX_AUTO_CONTINUE_ITERATIONS"
  printf '  idle gate:    %ss since last UserPromptSubmit\n' "$MAX_AUTO_CONTINUE_AGE"
}

# stop_block_disable — remove ack and per-session counters.
stop_block_disable() {
  rm -f "$CC_SSH_STOP_BLOCK_ACK" 2>/dev/null
  if [[ -d "$CC_SSH_HOME/state" ]]; then
    find "$CC_SSH_HOME/state" -type f -name '*.stop-block-count' -delete 2>/dev/null || true
  fi
  printf 'stop-block disabled.\n'
}

# _counter_path <wid> <sid> -> file path.
_counter_path() {
  printf '%s/state/%s/%s.stop-block-count' "$CC_SSH_HOME" "$1" "$2"
}

# _counter_get <wid> <sid> -> echo current count (0 if absent).
_counter_get() {
  local p
  p="$(_counter_path "$1" "$2")"
  [[ -r "$p" ]] || { echo 0; return; }
  cat "$p" 2>/dev/null || echo 0
}

# _counter_inc <wid> <sid> -> echo new count after increment.
_counter_inc() {
  local p
  p="$(_counter_path "$1" "$2")"
  cc_ensure_dir "$(dirname "$p")"
  local cur=0
  [[ -r "$p" ]] && cur="$(cat "$p" 2>/dev/null || echo 0)"
  local new=$((cur + 1))
  printf '%s' "$new" >"$p.tmp"
  mv -f "$p.tmp" "$p"
  printf '%s' "$new"
}

# _counter_reset <wid> <sid> — remove the counter file.
_counter_reset() {
  rm -f "$(_counter_path "$1" "$2")" 2>/dev/null
}

# _last_user_prompt_at <wid> <sid> -> echo seconds-since-epoch or 0.
_last_user_prompt_at() {
  local f="$CC_SSH_HOME/state/$1/$2.jsonl"
  [[ -r "$f" ]] || { echo 0; return; }
  grep '"evt":"user_prompt_submit"' "$f" 2>/dev/null \
    | tail -n 1 \
    | cc_jq -r '.at // 0' 2>/dev/null \
    || echo 0
}

# stop_block_load_rules -> JSON array of {matcher, prompt, tool?}.
stop_block_load_rules() {
  local files=()
  [[ -r "$CC_SSH_STOP_BLOCK_FILE" ]] && files+=("$CC_SSH_STOP_BLOCK_FILE")
  if [[ -n "${POLICY_CWD:-}" && -r "${POLICY_CWD}/.cc-ssh/stop-block.toml" ]]; then
    files+=("${POLICY_CWD}/.cc-ssh/stop-block.toml")
  fi
  if (( ${#files[@]} == 0 )); then
    printf '[]'
    return
  fi
  if cc_have taplo; then
    local merged='[]' f json
    for f in "${files[@]}"; do
      json=$(taplo get -f "$f" -o json . 2>/dev/null)
      [[ -z "$json" ]] && continue
      merged=$(printf '%s\n%s' "$merged" "$json" | cc_jq -s '
        (.[0] // []) + (.[1].rule // [])
      ')
    done
    printf '%s' "$merged"
    return
  fi
  # POSIX-shell fallback (single-section [[rule]]).
  _stop_block_parse_toml "${files[@]}"
}

_stop_block_parse_toml() {
  local f
  local out="[]"
  for f in "$@"; do
    local current="null"
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%%#*}"
      line="${line#"${line%%[![:space:]]*}"}"
      line="${line%"${line##*[![:space:]]}"}"
      [[ -z "$line" ]] && continue
      if [[ "$line" =~ ^\[\[rule\]\]$ ]]; then
        if [[ "$current" != "null" && "$current" != "" ]]; then
          out=$(printf '%s' "$out" | cc_jq --argjson o "$current" '. + [$o]')
        fi
        current='{}'
      elif [[ "$line" =~ ^([A-Za-z0-9_]+)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
        local key="${BASH_REMATCH[1]}" val="${BASH_REMATCH[2]}"
        local jval
        jval=$(_policy_decode_value "$val" 2>/dev/null) || continue
        [[ "$current" == "null" ]] && continue
        current=$(printf '%s' "$current" | cc_jq --arg k "$key" --argjson v "$jval" '.[$k] = $v')
      fi
    done <"$f"
    if [[ "$current" != "null" && "$current" != "" ]]; then
      out=$(printf '%s' "$out" | cc_jq --argjson o "$current" '. + [$o]')
    fi
  done
  printf '%s' "$out"
}

# stop_block_decide <wid> <sid> -> JSON {action: "block"|"none", reason?, count?}
stop_block_decide() {
  local wid="$1" sid="$2"
  if ! stop_block_enabled; then
    printf '{"action":"none","reason":"not enabled"}'
    return 0
  fi

  local rules
  rules="$(stop_block_load_rules)"
  if [[ "$(printf '%s' "$rules" | cc_jq -r 'length')" -eq 0 ]]; then
    printf '{"action":"none","reason":"no rules"}'
    return 0
  fi

  # Read recent jsonl tail for the session.
  local jsonl="$CC_SSH_HOME/state/$wid/$sid.jsonl"
  [[ -r "$jsonl" ]] || { printf '{"action":"none","reason":"no events"}'; return 0; }
  local recent
  recent="$(tail -n 100 "$jsonl" 2>/dev/null \
    | cc_jq -cR 'fromjson? // empty' 2>/dev/null \
    | cc_jq -cs '.' 2>/dev/null \
    || echo '[]')"

  # Match each rule against recent post_tool / phase events.
  local n i rule matcher prompt rule_tool
  n="$(printf '%s' "$rules" | cc_jq -r 'length')"
  i=0
  local match_prompt="" match_idx=""
  while (( i < n )); do
    rule="$(printf '%s' "$rules" | cc_jq -c ".[$i]")"
    matcher="$(printf '%s' "$rule" | cc_jq -r '.matcher // ""')"
    prompt="$(printf '%s' "$rule" | cc_jq -r '.prompt // ""')"
    rule_tool="$(printf '%s' "$rule" | cc_jq -r '.tool // ""')"
    [[ -z "$matcher" || -z "$prompt" ]] && { i=$((i+1)); continue; }

    # Check the most recent failed tool against the matcher.
    local last_label last_ok last_tool
    last_label="$(printf '%s' "$recent" | cc_jq -r '
      ([.[] | select(.evt == "post_tool")] | last) as $p | ($p.label // "")
    ')"
    # `// true` would flip false→true (jq treats false as nullish); use tostring.
    last_ok="$(printf '%s' "$recent" | cc_jq -r '
      ([.[] | select(.evt == "post_tool")] | last) as $p
      | (if $p == null then "true" elif $p.ok == false then "false" else "true" end)
    ')"
    last_tool="$(printf '%s' "$recent" | cc_jq -r '
      ([.[] | select(.evt == "post_tool")] | last) as $p | ($p.tool // "")
    ')"
    if [[ "$last_ok" == "false" ]]; then
      if [[ -n "$rule_tool" && "$rule_tool" != "$last_tool" ]]; then
        i=$((i+1)); continue
      fi
      if [[ "$last_label" =~ $matcher ]]; then
        match_prompt="$prompt"
        match_idx="$i"
        break
      fi
    fi
    i=$((i+1))
  done

  if [[ -z "$match_prompt" ]]; then
    printf '{"action":"none"}'
    return 0
  fi

  # Hard cap.
  local count
  count="$(_counter_get "$wid" "$sid")"
  if (( count >= MAX_AUTO_CONTINUE_ITERATIONS )); then
    state_append_jsonl "$sid" "$(cc_jq -nc --arg evt stop_block_capped --argjson at "$(cc_now_s)" --argjson count "$count" '{evt:$evt,at:$at,count:$count}')"
    cc_jq -nc --arg r "max iterations reached ($count/$MAX_AUTO_CONTINUE_ITERATIONS)" \
      '{action:"none",reason:$r}'
    return 0
  fi

  # Idle-time guard.
  local last_prompt_at now_at age
  last_prompt_at="$(_last_user_prompt_at "$wid" "$sid")"
  now_at="$(cc_now_s)"
  age=$(( now_at - last_prompt_at ))
  if (( last_prompt_at > 0 )) && (( age > MAX_AUTO_CONTINUE_AGE )); then
    state_append_jsonl "$sid" "$(cc_jq -nc --arg evt stop_block_idle --argjson at "$now_at" --argjson age "$age" '{evt:$evt,at:$at,age:$age}')"
    cc_jq -nc --arg r "idle gate ($age s since last user prompt)" \
      '{action:"none",reason:$r}'
    return 0
  fi

  # Reason dedup: refuse same reason 3× in a row.
  local recent_reasons
  recent_reasons="$(grep '"evt":"stop"' "$jsonl" 2>/dev/null | tail -n 3 | cc_jq -r '.reason // ""' 2>/dev/null)"
  local same_count=0 r
  while IFS= read -r r; do
    [[ "$r" == "$match_prompt" ]] && same_count=$((same_count+1))
  done <<<"$recent_reasons"
  if (( same_count >= 2 )); then
    state_append_jsonl "$sid" "$(cc_jq -nc --arg evt stop_block_dedup --argjson at "$now_at" --arg reason "$match_prompt" '{evt:$evt,at:$at,reason:$reason}')"
    cc_jq -nc --arg r "dedup: same reason emitted twice already" \
      '{action:"none",reason:$r}'
    return 0
  fi

  # All gates pass: emit block.
  local new_count
  new_count="$(_counter_inc "$wid" "$sid")"
  state_append_jsonl "$sid" "$(cc_jq -nc --arg evt stop_block_emit --argjson at "$now_at" --arg reason "$match_prompt" --argjson count "$new_count" --argjson rule "$match_idx" '{evt:$evt,at:$at,reason:$reason,count:$count,rule:$rule}')"
  cc_jq -nc --arg r "$match_prompt" --argjson c "$new_count" --argjson m "$MAX_AUTO_CONTINUE_ITERATIONS" \
    '{action:"block",reason:$r,count:$c,max:$m}'
}

# stop_block_alert <wid> <sid> <kind> <reason> — fire cross-workspace alert.
# Used when cap, dedup, or idle gate exits the loop.
stop_block_alert() {
  local wid="$1" sid="$2" kind="$3" reason="$4"
  local project
  project="$(state_project "$wid" 2>/dev/null || echo workspace)"
  local count
  count="$(_counter_get "$wid" "$sid")"
  local body="${project} · ${count} attempts"
  case "$kind" in
    cap) body="${body} · cap reached" ;;
    dedup) body="${body} · dedup: ${reason}" ;;
    idle) body="${body} · idle gate triggered" ;;
  esac
  cc_notify_cross_workspace "Codex stop-block exhausted" "$body" --rule "stop_block_$kind"
}

# codex_admin_cli — sub-handler for `cc-ssh codex ...`.
codex_admin_cli() {
  local sub="${1:-}"
  shift || true
  case "$sub" in
    enable-stop-block) stop_block_enable ;;
    disable-stop-block) stop_block_disable ;;
    status)
      if stop_block_enabled; then
        printf 'stop-block: ENABLED (acknowledged %s)\n' "$(cat "$CC_SSH_STOP_BLOCK_ACK")"
      else
        printf 'stop-block: disabled\n'
      fi
      ;;
    *)
      echo "usage: cc-ssh codex {enable-stop-block,disable-stop-block,status}" >&2
      return 2
      ;;
  esac
}
