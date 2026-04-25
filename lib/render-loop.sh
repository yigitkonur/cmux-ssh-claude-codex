# render-loop.sh — single-writer per-workspace renderer.
#
# - Leader-elect via mkdir(.leader); next hook respawns when stale.
# - 1 Hz tick: read all alive jsonl tails -> compute union state -> credits-roll
#   -> diff vs .last-render.json -> only fire workspace.action if changed.
# - When zero alive sessions, clear color/desc + rename to project + exit.

[[ -n "${_CC_SSH_RENDER_LOOP_SOURCED:-}" ]] && return 0
_CC_SSH_RENDER_LOOP_SOURCED=1

if ! declare -F cc_have >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  . "$(dirname "${BASH_SOURCE[0]}")/util.sh" 2>/dev/null || true
fi
if ! declare -F state_alive_sessions >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  . "$(dirname "${BASH_SOURCE[0]}")/state.sh" 2>/dev/null || true
fi
if ! declare -F format_credits_roll >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  . "$(dirname "${BASH_SOURCE[0]}")/credits-roll.sh" 2>/dev/null || true
fi

LEADER_TTL="${LEADER_TTL:-60}"
IDLE_TTL="${IDLE_TTL:-60}"
RENDER_TICK_S="${RENDER_TICK_S:-1}"
JSONL_TAIL_LINES="${JSONL_TAIL_LINES:-200}"

# read_jsonl_tail <path> <N> — emit a JSON array of the last N parsed lines.
read_jsonl_tail() {
  local path="$1" n="${2:-200}"
  [[ -r "$path" ]] || { printf '[]'; return; }
  tail -n "$n" "$path" 2>/dev/null \
    | cc_jq -cR 'fromjson? // empty' 2>/dev/null \
    | cc_jq -cs '.' 2>/dev/null \
    || printf '[]'
}

# compute_session_state <jsonl_path> <kind> <now_s> -> JSON per-session state.
compute_session_state() {
  local path="$1" kind="$2" now_s="$3"
  local arr
  arr="$(read_jsonl_tail "$path" "$JSONL_TAIL_LINES")"
  printf '%s' "$arr" | cc_jq --arg kind "$kind" --argjson now "$now_s" '
    . as $events
    | (([$events[] | select(.evt=="start") | .at] | map(select(. != null)) | last) // $now) as $started_at
    | ($events[-1] // {}) as $last
    | ([$events[] | select(.evt=="stop")] | last // {}) as $last_stop
    | ([$events[] | select(.evt=="permission_request")] | last) as $last_perm
    | ([$events[] | select(.evt=="permission_resolved")] | last) as $last_perm_res
    | ([$events[] | select(.evt=="compact_pre")] | last) as $last_compact_pre
    | ([$events[] | select(.evt=="compact_post")] | last) as $last_compact_post
    | ([$events[] | select(.evt=="pre_tool")] | last) as $last_pre
    | ([$events[] | select(.evt=="post_tool")] | last) as $last_post
    | ([$events[] | select(.evt=="user_prompt_submit")] | last) as $last_prompt
    | (
        if ($last_stop.stop_reason // "") == "error" and ($last_stop.at // 0) >= ($last.at // 0)
          then "error"
        elif ($last_perm != null) and (($last_perm.at // 0) > ($last_perm_res.at // -1))
          then "waiting"
        elif ($last_compact_pre != null) and (($last_compact_pre.at // 0) > ($last_compact_post.at // -1))
          then "compacting"
        elif ($last_pre != null) and (($last_pre.at // 0) > ($last_post.at // -1))
          then "working"
        elif ($last_prompt != null) and (($last_prompt.at // 0) > ($last_pre.at // -1)) and (($last_prompt.at // 0) > ($last_post.at // -1))
          then "thinking"
        elif ($last_stop.stop_reason // "") == "user_turn_complete"
          then "done"
        else "ready"
        end
      ) as $phase
    | ([$events[] | select(.evt=="post_tool")] | length) as $ops
    | (
        if ($last_pre != null) and (($last_pre.at // 0) > ($last_post.at // -1))
          then ($last_pre.label // ((($last_pre.tool // "") + (if ($last_pre.first_arg // "") != "" then " " + $last_pre.first_arg else "" end))))
          else null
        end
      ) as $current_tool
    | (
        # Subagents (Claude): keep open ones (started but not stopped) keyed by uuid.
        reduce $events[] as $e ({};
          if $e.evt == "sub_start" then
            .[$e.uuid // ""] = {
              uuid: ($e.uuid // ""),
              agent_type: ($e.agent_type // null),
              counter: ($e.counter // 0),
              last_tool: null,
              last_tool_at: ($e.at // 0)
            }
          elif $e.evt == "sub_stop" then
            del(.[$e.uuid // ""])
          elif $e.evt == "post_tool" then
            (if (.[$e.agent_uuid // ""] // null) != null then
              .[$e.agent_uuid] |= (. + {
                last_tool: ($e.label // ($e.tool // "")),
                last_tool_at: ($e.at // 0)
              })
             else . end)
          else . end
        )
        | to_entries | map(.value)
        | sort_by(-(.last_tool_at // 0))
      ) as $subs_arr
    | (
        # Recent Codex tool history: dedupe by tool+first_arg, drop entries > 5 min old.
        [ $events[] | select(.evt == "post_tool") ]
        | reduce .[] as $p ({}; .[((($p.tool // "") + "::" + ($p.first_arg // "")))] = $p)
        | to_entries | map(.value)
        | map(select(($now - (.at // 0)) <= 300))
        | sort_by(-(.at // 0))
      ) as $recent
    | {
        kind: $kind,
        phase: $phase,
        ops: $ops,
        current_tool: $current_tool,
        elapsed_s: ($now - $started_at),
        subagents: $subs_arr,
        recent_tools: $recent,
        last_event_at: ($last.at // $now)
      }
  '
}

# compute_union_state <wid> -> JSON for the workspace tile.
compute_union_state() {
  local wid="${1:-${CMUX_WORKSPACE_ID:-}}"
  [[ -z "$wid" ]] && { printf '{}'; return; }
  local dir="$CC_SSH_STATE_DIR/$wid"
  [[ -d "$dir" ]] || { printf '{}'; return; }
  local now_s
  now_s="$(cc_now_s)"

  # Per-session state objects, joined into one JSON array.
  local sids_arr=()
  while IFS= read -r sid; do
    [[ -n "$sid" ]] && sids_arr+=("$sid")
  done < <(state_alive_sessions "$wid")
  if (( ${#sids_arr[@]} == 0 )); then
    printf '{"session_count":0,"alive":false}'
    return
  fi

  local sessions_json="["
  local first=1
  local sid kind path s
  for sid in "${sids_arr[@]}"; do
    kind="$(state_kind "$sid")"
    [[ -z "$kind" ]] && kind="claude"
    path="$dir/$sid.jsonl"
    s="$(compute_session_state "$path" "$kind" "$now_s")"
    [[ -z "$s" ]] && s="{}"
    if (( first == 1 )); then
      sessions_json="${sessions_json}${s}"
      first=0
    else
      sessions_json="${sessions_json},${s}"
    fi
  done
  sessions_json="${sessions_json}]"

  local project
  project="$(state_project "$wid")"

  # Phase priority order: error > waiting > working > thinking > compacting > ready > done.
  # Aggregate per-session states.
  local git_branch="" git_dirty="false"
  if cc_have git; then
    # Best-effort from cwd; only meaningful if renderer was started inside a repo.
    local b
    b="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
    if [[ -n "$b" && "$b" != "HEAD" ]]; then
      git_branch="$b"
      [[ -n "$(git status --porcelain 2>/dev/null)" ]] && git_dirty="true"
    fi
  fi

  # Sum stop-block counters across all sessions in this workspace.
  local sb_count=0 sb_max="${MAX_AUTO_CONTINUE_ITERATIONS:-5}" cf n
  shopt -s nullglob
  for cf in "$dir"/*.stop-block-count; do
    n="$(cat "$cf" 2>/dev/null || echo 0)"
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    sb_count=$((sb_count + n))
  done
  shopt -u nullglob
  local auto_continue=""
  if (( sb_count > 0 )); then
    auto_continue="${sb_count}/${sb_max}"
  fi

  # Bypass timestamp surface for renderer (read-only).
  local bypass=""
  if [[ -r "${CC_SSH_BYPASS_FILE:-$CC_SSH_HOME/.bypass-until}" ]]; then
    local until
    until="$(cat "${CC_SSH_BYPASS_FILE:-$CC_SSH_HOME/.bypass-until}" 2>/dev/null)"
    [[ "$until" =~ ^[0-9]+$ ]] && (( until > now_s )) && bypass="active"
  fi

  printf '%s' "$sessions_json" | cc_jq --arg project "$project" \
    --arg git_branch "$git_branch" --argjson git_dirty "$git_dirty" \
    --arg auto_continue "$auto_continue" --arg bypass "$bypass" \
    --argjson now "$now_s" '
    . as $sessions
    | ([
        ($sessions[] | .phase // "ready")
        | (if . == "error" then 7
           elif . == "waiting" then 6
           elif . == "working" then 5
           elif . == "thinking" then 4
           elif . == "compacting" then 3
           elif . == "ready" then 2
           elif . == "done" then 1
           else 0 end)
      ] | max // 0) as $pmax
    | (
        if   $pmax == 7 then "error"
        elif $pmax == 6 then "waiting"
        elif $pmax == 5 then "working"
        elif $pmax == 4 then "thinking"
        elif $pmax == 3 then "compacting"
        elif $pmax == 2 then "ready"
        elif $pmax == 1 then "done"
        else "ready" end
      ) as $phase
    | ($sessions | map(.ops // 0) | add // 0) as $ops
    | ($sessions | map(.elapsed_s // 0) | max // 0) as $elapsed
    | ($sessions | map(.current_tool) | map(select(. != null and . != "")) | first // null) as $cur
    | ($sessions | map(.subagents // []) | add // []) as $subs
    | ($subs | length) as $sub_count
    | ($sessions | map(.recent_tools // []) | add // []) as $tools
    | ($subs | sort_by(-(.last_tool_at // 0))) as $subs_sorted
    | (
        # Build cycling-lane rows. Subagent rows for any Claude subagents,
        # Codex tool rows for any Codex tool history, deduped + sorted by recency.
        ($subs_sorted | map(
            "· " +
            (if (.agent_type // null) != null and ((.counter // 0) | tonumber? // 0) > 0
             then ((.agent_type | ascii_downcase) + "-" + ((.counter // 0) | tostring))
             else (.uuid // "" | sub("-";"";"g") | (if length>=7 then .[length-7:] else . end))
             end) +
            " → " + (.last_tool // "")
          )
        ) as $sub_rows
        | ($tools
            | map(select(.at != null and ($now - (.at // 0)) < 300))
            | unique_by(((.tool // "") + "::" + (.first_arg // "")))
            | sort_by(-(.at // 0))
            | map(
                ($now - (.at // 0)) as $age
                | "· " +
                  (if $age < 60 then "\($age)s"
                   elif $age < 3600 then "\(($age/60)|floor)m\(($age%60)|floor)s"
                   else "\(($age/3600)|floor)h\((($age%3600)/60)|floor)m" end) +
                  " " + (.tool // "") +
                  (if (.first_arg // "") != "" then " " + .first_arg else "" end)
              )
          ) as $tool_rows
        | ($sub_rows + $tool_rows)
      ) as $lanes
    | {
        project: $project,
        session_count: ($sessions | length),
        subagent_count: $sub_count,
        ops: $ops,
        phase: $phase,
        elapsed_s: $elapsed,
        current_tool: $cur,
        git_branch: $git_branch,
        git_dirty: $git_dirty,
        cycling_lanes: $lanes,
        auto_continue: $auto_continue,
        bypass: $bypass,
        sessions: $sessions
      }
  '
}

# diff_against_last_render <wid> <render-json> -> 0 if changed, 1 if same.
# Side effect: when changed, atomically writes the new render to .last-render.json.
diff_against_last_render() {
  local wid="$1" render="$2"
  local dir="$CC_SSH_STATE_DIR/$wid"
  cc_ensure_dir "$dir"
  local last="$dir/.last-render.json"
  if [[ -r "$last" ]] && cmp -s <(printf '%s' "$render") "$last"; then
    return 1
  fi
  cc_atomic_write "$last" "$render"
  return 0
}

# render_apply <wid> <render-json> — call cmux-pill to apply title/desc/color.
render_apply() {
  local wid="$1" render="$2"
  local title desc color
  title=$(printf '%s' "$render" | cc_jq -r '.title // ""')
  desc=$(printf '%s' "$render" | cc_jq -r '.desc // ""')
  color=$(printf '%s' "$render" | cc_jq -r '.color // ""')

  if ! cc_have cmux; then
    cc_log warn "cmux missing; cannot apply render to $wid"
    return 0
  fi

  if declare -F cmux-pill >/dev/null 2>&1; then
    if [[ -n "$title" ]]; then cmux-pill title --ws "$wid" "$title" 2>/dev/null || true; fi
    if [[ -n "$desc" ]]; then cmux-pill desc --ws "$wid" "$desc" 2>/dev/null || true; fi
    if [[ -n "$color" ]]; then cmux-pill color --ws "$wid" "$color" 2>/dev/null || true
    else cmux-pill color --ws "$wid" "" 2>/dev/null || true
    fi
  else
    # Fallback: direct rpc.
    cmux rpc workspace.action "$(cc_jq -n --arg w "$wid" --arg t "$title" '{workspace_id:$w, action:"rename", title:$t}')" >/dev/null 2>&1 || true
    cmux rpc workspace.action "$(cc_jq -n --arg w "$wid" --arg d "$desc" '{workspace_id:$w, action:"set_description", description:$d}')" >/dev/null 2>&1 || true
    if [[ -n "$color" ]]; then
      cmux rpc workspace.action "$(cc_jq -n --arg w "$wid" --arg c "$color" '{workspace_id:$w, action:"set_color", color:$c}')" >/dev/null 2>&1 || true
    else
      cmux rpc workspace.action "$(cc_jq -n --arg w "$wid" '{workspace_id:$w, action:"clear_color"}')" >/dev/null 2>&1 || true
    fi
  fi
}

# leader_acquire <wid> — try mkdir lock; replace if stale; return 0 on success.
leader_acquire() {
  local wid="$1"
  local dir="$CC_SSH_STATE_DIR/$wid"
  cc_ensure_dir "$dir"
  local lock="$dir/.leader"
  if mkdir "$lock" 2>/dev/null; then
    return 0
  fi
  # Already exists; check staleness.
  local mt now
  if mt="$(stat -f '%m' "$lock" 2>/dev/null)" || mt="$(stat -c '%Y' "$lock" 2>/dev/null)"; then
    now="$(cc_now_s)"
    if (( now - mt > LEADER_TTL )); then
      rmdir "$lock" 2>/dev/null || rm -rf "$lock" 2>/dev/null
      mkdir "$lock" 2>/dev/null && return 0
    fi
  fi
  return 1
}

leader_heartbeat() {
  local wid="$1"
  local lock="$CC_SSH_STATE_DIR/$wid/.leader"
  touch -c "$lock" 2>/dev/null || true
}

leader_release() {
  local wid="$1"
  rmdir "$CC_SSH_STATE_DIR/$wid/.leader" 2>/dev/null || true
}

# render_cleanup <wid> — clear tile to default project name on exit.
render_cleanup() {
  local wid="$1"
  local project
  project="$(state_project "$wid")"
  if cc_have cmux; then
    if declare -F cmux-pill >/dev/null 2>&1; then
      cmux-pill clear --ws "$wid" 2>/dev/null || true
      cmux-pill title --ws "$wid" "📂 ${project}" 2>/dev/null || true
    else
      cmux rpc workspace.action "$(cc_jq -n --arg w "$wid" '{workspace_id:$w, action:"clear_color"}')" >/dev/null 2>&1 || true
      cmux rpc workspace.action "$(cc_jq -n --arg w "$wid" '{workspace_id:$w, action:"clear_description"}')" >/dev/null 2>&1 || true
      cmux rpc workspace.action "$(cc_jq -n --arg w "$wid" --arg t "📂 ${project}" '{workspace_id:$w, action:"rename", title:$t}')" >/dev/null 2>&1 || true
    fi
  fi
  rm -f "$CC_SSH_STATE_DIR/$wid/.last-render.json" 2>/dev/null
  leader_release "$wid"
}

# render_loop <wid> — main loop. Returns once all sessions age out.
render_loop() {
  local wid="${1:-${CMUX_WORKSPACE_ID:-}}"
  if [[ -z "$wid" ]]; then
    echo "render_loop: missing workspace id" >&2
    return 2
  fi

  if ! leader_acquire "$wid"; then
    cc_log info "render_loop: another leader holds $wid; exiting"
    return 0
  fi

  trap 'render_cleanup "$wid"; exit 0' INT TERM EXIT

  local consecutive_idle=0
  local idle_grace=$(( IDLE_TTL / RENDER_TICK_S + 5 ))

  while :; do
    leader_heartbeat "$wid"
    local count
    count="$(state_session_count "$wid")"
    if [[ "$count" -eq 0 ]]; then
      consecutive_idle=$((consecutive_idle + 1))
      if (( consecutive_idle >= idle_grace )); then
        cc_log info "render_loop: idle; exiting workspace=$wid"
        break
      fi
    else
      consecutive_idle=0
    fi

    local state render
    state="$(compute_union_state "$wid")"
    if [[ -z "$state" || "$state" == "{}" ]]; then
      sleep "$RENDER_TICK_S"
      continue
    fi
    local tick_ms
    tick_ms="$(cc_now_ms)"
    render="$(format_credits_roll "$state" "$tick_ms")"
    if [[ -n "$render" ]] && diff_against_last_render "$wid" "$render"; then
      render_apply "$wid" "$render"
    fi
    sleep "$RENDER_TICK_S"
  done

  return 0
}

# ensure_renderer <wid> — non-blocking spawn from a hook context.
# Returns 0 if a renderer is now running (newly spawned or already alive).
ensure_renderer() {
  local wid="${1:-${CMUX_WORKSPACE_ID:-}}"
  [[ -z "$wid" ]] && return 1
  local lock="$CC_SSH_STATE_DIR/$wid/.leader"
  if [[ -d "$lock" ]]; then
    local mt now
    if mt="$(stat -f '%m' "$lock" 2>/dev/null)" || mt="$(stat -c '%Y' "$lock" 2>/dev/null)"; then
      now="$(cc_now_s)"
      if (( now - mt <= LEADER_TTL )); then
        return 0
      fi
    fi
  fi
  # Need to spawn. Use nohup + setsid where available so we survive the hook
  # process exit.
  local self="$CC_SSH_BIN_DIR/cc-ssh"
  if [[ ! -x "$self" ]]; then
    self="$(command -v cc-ssh 2>/dev/null || echo "$CC_SSH_BIN_DIR/cc-ssh")"
  fi
  cc_ensure_dir "$CC_SSH_LOG_DIR"
  if cc_have setsid; then
    setsid nohup "$self" render-loop "$wid" \
      </dev/null >>"$CC_SSH_LOG_DIR/current.log" 2>&1 &
  else
    nohup "$self" render-loop "$wid" \
      </dev/null >>"$CC_SSH_LOG_DIR/current.log" 2>&1 &
  fi
  disown 2>/dev/null || true
  return 0
}
