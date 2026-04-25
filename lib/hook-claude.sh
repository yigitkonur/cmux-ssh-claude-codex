# hook-claude.sh — Claude Code hook handler. Reads a JSON payload on stdin,
# appends a jsonl record, touches the session heartbeat, ensures the renderer,
# and exits 0. Always fail-open: any error is logged and swallowed.

[[ -n "${_CC_SSH_HOOK_CLAUDE_SOURCED:-}" ]] && return 0
_CC_SSH_HOOK_CLAUDE_SOURCED=1

if ! declare -F cc_have >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  . "$(dirname "${BASH_SOURCE[0]}")/util.sh" 2>/dev/null || true
fi
if ! declare -F state_init >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  . "$(dirname "${BASH_SOURCE[0]}")/state.sh" 2>/dev/null || true
fi
if ! declare -F cc_notify_cross_workspace >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  . "$(dirname "${BASH_SOURCE[0]}")/cmux-notify.sh" 2>/dev/null || true
fi
if ! declare -F ensure_renderer >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  . "$(dirname "${BASH_SOURCE[0]}")/render-loop.sh" 2>/dev/null || true
fi

# _hook_emit <sid> <json> — append jsonl and touch heartbeat.
_hook_emit() {
  local sid="$1" line="$2"
  state_append_jsonl "$sid" "$line"
  state_touch_alive "$sid"
}

# _short_input <tool_input_json> — produce a 60-char snippet for notification bodies.
_short_input() {
  local input="$1"
  if [[ -z "$input" || "$input" == "null" ]]; then printf ''; return; fi
  local s
  s="$(printf '%s' "$input" | cc_jq -r '
    if type == "object" then
      (.command // .file_path // .path // .pattern // .url // (.[] // empty) | tostring)
    else tostring end
  ' 2>/dev/null | head -n 1)"
  cc_truncate_str 60 "$s"
}

# _bootstrap_render <wid> — fire one immediate paint when this hook is the
# first to arrive (mkdir .leader succeeded). Spawn the renderer either way.
_bootstrap_render() {
  local wid="$1"
  if [[ -z "$wid" ]]; then return; fi
  ensure_renderer "$wid"
}

# handle_claude_hook <event> — main dispatcher. Reads stdin JSON.
handle_claude_hook() {
  local event="${1:-}"
  if [[ -z "${CMUX_WORKSPACE_ID:-}" ]]; then
    return 0
  fi

  local payload
  payload="$(cat)"
  if [[ -z "$payload" ]]; then
    return 0
  fi

  # Trap any internal failure — never block Claude Code.
  trap 'cc_log warn "claude hook ${event} encountered an error"; return 0' ERR

  local session_id model cwd tool_name tool_input
  session_id=$(printf '%s' "$payload" | cc_jq -r '.session_id // .sessionId // ""' 2>/dev/null)
  if [[ -z "$session_id" ]]; then
    session_id="cc-default"
  fi
  model=$(printf '%s' "$payload" | cc_jq -r '.model // ""' 2>/dev/null)
  cwd=$(printf '%s' "$payload" | cc_jq -r '.cwd // ""' 2>/dev/null)
  tool_name=$(printf '%s' "$payload" | cc_jq -r '.tool_name // ""' 2>/dev/null)
  tool_input=$(printf '%s' "$payload" | cc_jq -c '.tool_input // null' 2>/dev/null)

  state_init "$session_id" "claude" || return 0

  local at
  at="$(cc_now_s)"
  local project
  if [[ -n "$cwd" ]]; then project="$(basename "$cwd")"; else project="workspace"; fi

  case "$event" in
    SessionStart)
      _hook_emit "$session_id" "$(cc_jq -nc --arg evt start --arg kind claude --argjson at "$at" --arg model "$model" --arg cwd "$cwd" --arg project "$project" '{evt:$evt,kind:$kind,at:$at,model:$model,cwd:$cwd,project:$project}')"
      _bootstrap_render "$CMUX_WORKSPACE_ID"
      ;;

    UserPromptSubmit)
      _hook_emit "$session_id" "$(cc_jq -nc --arg evt user_prompt_submit --argjson at "$at" '{evt:$evt,at:$at}')"
      declare -F policy_touch_presence >/dev/null 2>&1 && policy_touch_presence
      _bootstrap_render "$CMUX_WORKSPACE_ID"
      ;;

    PreToolUse)
      local first_arg label parent_agent
      first_arg=$(_first_arg_from_input "$tool_name" "$tool_input")
      label=$(format_claude_tool_label "$tool_name" "$tool_input")
      parent_agent=$(printf '%s' "$payload" | cc_jq -r '.agent_id // .parent_agent_id // ""' 2>/dev/null)
      _hook_emit "$session_id" "$(cc_jq -nc --arg evt pre_tool --argjson at "$at" \
        --arg tool "$tool_name" --arg first_arg "$first_arg" --arg label "$label" \
        --arg agent_uuid "$parent_agent" \
        '{evt:$evt,at:$at,tool:$tool,first_arg:$first_arg,label:$label,agent_uuid:$agent_uuid}')"
      _bootstrap_render "$CMUX_WORKSPACE_ID"
      ;;

    PostToolUse)
      local label first_arg parent_agent ok exit_code
      first_arg=$(_first_arg_from_input "$tool_name" "$tool_input")
      label=$(format_claude_tool_label "$tool_name" "$tool_input")
      parent_agent=$(printf '%s' "$payload" | cc_jq -r '.agent_id // .parent_agent_id // ""' 2>/dev/null)
      exit_code=$(printf '%s' "$payload" | cc_jq -r '.tool_response.exit_code // .exit_code // ""' 2>/dev/null)
      ok="true"
      if [[ -n "$exit_code" && "$exit_code" != "0" && "$exit_code" != "null" ]]; then ok="false"; fi
      _hook_emit "$session_id" "$(cc_jq -nc --arg evt post_tool --argjson at "$at" \
        --arg tool "$tool_name" --arg first_arg "$first_arg" --arg label "$label" \
        --arg agent_uuid "$parent_agent" --arg exit_code "$exit_code" \
        --argjson ok "$ok" \
        '{evt:$evt,at:$at,tool:$tool,first_arg:$first_arg,label:$label,agent_uuid:$agent_uuid,ok:$ok,exit_code:$exit_code}')"
      ;;

    PostToolUseFailure)
      local err
      err=$(printf '%s' "$payload" | cc_jq -r '.error // ""' 2>/dev/null)
      _hook_emit "$session_id" "$(cc_jq -nc --arg evt post_tool --argjson at "$at" \
        --arg tool "$tool_name" --argjson ok false --arg error "$err" \
        '{evt:$evt,at:$at,tool:$tool,ok:$ok,error:$error}')"
      ;;

    PermissionRequest)
      _hook_emit "$session_id" "$(cc_jq -nc --arg evt permission_request --argjson at "$at" \
        --arg tool "$tool_name" --argjson tool_input "$tool_input" \
        '{evt:$evt,at:$at,tool:$tool,tool_input:$tool_input}')"
      _bootstrap_render "$CMUX_WORKSPACE_ID"
      local short
      short="$(_short_input "$tool_input")"
      cc_notify_cross_workspace "🔐 Permission needed" \
        "📂 ${project} · ${tool_name}: ${short}" --rule "permission_request" || true
      ;;

    Stop)
      local reason
      reason=$(printf '%s' "$payload" | cc_jq -r '.stop_reason // "user_turn_complete"' 2>/dev/null)
      _hook_emit "$session_id" "$(cc_jq -nc --arg evt stop --argjson at "$at" \
        --arg stop_reason "$reason" '{evt:$evt,at:$at,stop_reason:$stop_reason}')"
      _bootstrap_render "$CMUX_WORKSPACE_ID"
      # Optional alert; gated by config.
      if _on_stop_notify_enabled; then
        cc_notify_cross_workspace "✅ ${project} done" "Claude Code finished a turn." --rule "stop_success" || true
      fi
      ;;

    StopFailure)
      local err
      err=$(printf '%s' "$payload" | cc_jq -r '.error // .message // ""' 2>/dev/null)
      _hook_emit "$session_id" "$(cc_jq -nc --arg evt stop --argjson at "$at" \
        --arg stop_reason error --arg error "$err" \
        '{evt:$evt,at:$at,stop_reason:$stop_reason,error:$error}')"
      _bootstrap_render "$CMUX_WORKSPACE_ID"
      cc_notify_cross_workspace "🔴 Error in ${project}" "$(cc_truncate_str 200 "$err")" --rule "stop_failure" || true
      ;;

    SubagentStart)
      local uuid agent_type counter
      uuid=$(printf '%s' "$payload" | cc_jq -r '.agent_id // .uuid // ""' 2>/dev/null)
      agent_type=$(printf '%s' "$payload" | cc_jq -r '.agent_type // ""' 2>/dev/null)
      counter="$(_subagent_counter_inc "$session_id" "$agent_type")"
      _hook_emit "$session_id" "$(cc_jq -nc --arg evt sub_start --argjson at "$at" \
        --arg uuid "$uuid" --arg agent_type "$agent_type" --argjson counter "$counter" \
        '{evt:$evt,at:$at,uuid:$uuid,agent_type:$agent_type,counter:$counter}')"
      _bootstrap_render "$CMUX_WORKSPACE_ID"
      ;;

    SubagentStop)
      local uuid
      uuid=$(printf '%s' "$payload" | cc_jq -r '.agent_id // .uuid // ""' 2>/dev/null)
      _hook_emit "$session_id" "$(cc_jq -nc --arg evt sub_stop --argjson at "$at" --arg uuid "$uuid" '{evt:$evt,at:$at,uuid:$uuid}')"
      _bootstrap_render "$CMUX_WORKSPACE_ID"
      ;;

    Notification)
      local title body
      title=$(printf '%s' "$payload" | cc_jq -r '.title // ""' 2>/dev/null)
      body=$(printf '%s' "$payload" | cc_jq -r '.body // .message // ""' 2>/dev/null)
      _hook_emit "$session_id" "$(cc_jq -nc --arg evt notify --argjson at "$at" \
        --arg title "$title" --arg body "$body" \
        '{evt:$evt,at:$at,title:$title,body:$body}')"
      cc_notify_cross_workspace "$title" "$body" --rule "notification" || true
      ;;

    SessionEnd)
      _hook_emit "$session_id" "$(cc_jq -nc --arg evt session_end --argjson at "$at" '{evt:$evt,at:$at}')"
      # Mark session dead by truncating its alive heartbeat to ancient mtime.
      local f="$CC_SSH_STATE_DIR/$CMUX_WORKSPACE_ID/$session_id.alive"
      if [[ -e "$f" ]]; then
        touch -t 200001010000.00 "$f" 2>/dev/null || true
      fi
      ;;

    PreCompact)
      local prior
      prior=$(_compute_phase_for_session "$session_id")
      _hook_emit "$session_id" "$(cc_jq -nc --arg evt compact_pre --argjson at "$at" --arg pre_compact_phase "$prior" '{evt:$evt,at:$at,pre_compact_phase:$pre_compact_phase}')"
      _bootstrap_render "$CMUX_WORKSPACE_ID"
      ;;

    PostCompact)
      _hook_emit "$session_id" "$(cc_jq -nc --arg evt compact_post --argjson at "$at" '{evt:$evt,at:$at}')"
      ;;

    TaskCompleted)
      local task_id
      task_id=$(printf '%s' "$payload" | cc_jq -r '.task_id // .task // ""' 2>/dev/null)
      _hook_emit "$session_id" "$(cc_jq -nc --arg evt task_completed --argjson at "$at" --arg task_id "$task_id" '{evt:$evt,at:$at,task_id:$task_id}')"
      ;;

    WorktreeCreate)
      local wt
      wt=$(printf '%s' "$payload" | cc_jq -r '.worktree_path // .path // ""' 2>/dev/null)
      _hook_emit "$session_id" "$(cc_jq -nc --arg evt worktree_create --argjson at "$at" --arg path "$wt" '{evt:$evt,at:$at,path:$path}')"
      ;;

    *)
      cc_log info "claude hook unknown event=$event"
      ;;
  esac

  return 0
}

# format_claude_tool_label <tool> <tool_input_json> — short label for credits-roll.
format_claude_tool_label() {
  local tool="$1" input="$2"
  case "$tool" in
    Bash)
      local cmd
      cmd=$(printf '%s' "$input" | cc_jq -r '.command // ""' 2>/dev/null | head -n 1)
      printf 'Bash %s' "$(cc_truncate_str 30 "$cmd")"
      ;;
    Read|Edit|Write|MultiEdit|NotebookEdit)
      local p
      p=$(printf '%s' "$input" | cc_jq -r '.file_path // .path // ""' 2>/dev/null)
      printf '%s %s' "$tool" "$(basename "$p" 2>/dev/null || printf '')"
      ;;
    Glob|Grep)
      local pat
      pat=$(printf '%s' "$input" | cc_jq -r '.pattern // ""' 2>/dev/null)
      printf '%s %s' "$tool" "$(cc_truncate_str 24 "$pat")"
      ;;
    WebFetch|WebSearch)
      local q
      q=$(printf '%s' "$input" | cc_jq -r '.url // .query // ""' 2>/dev/null)
      printf '%s %s' "$tool" "$(cc_truncate_str 24 "$q")"
      ;;
    Task|Agent)
      local desc
      desc=$(printf '%s' "$input" | cc_jq -r '.description // .subagent_type // ""' 2>/dev/null)
      printf '%s %s' "$tool" "$(cc_truncate_str 20 "$desc")"
      ;;
    *)
      if [[ "$tool" == mcp__* ]]; then
        local server name
        server="${tool#mcp__}"
        name="${server#*__}"
        server="${server%%__*}"
        printf 'mcp:%s/%s' "$server" "$name"
      else
        printf '%s' "$tool"
      fi
      ;;
  esac
}

# _first_arg_from_input <tool> <input_json> — extract a stable identifying arg.
_first_arg_from_input() {
  local tool="$1" input="$2"
  case "$tool" in
    Bash) printf '%s' "$input" | cc_jq -r '.command // ""' 2>/dev/null ;;
    Read|Edit|Write|MultiEdit|NotebookEdit) printf '%s' "$input" | cc_jq -r '.file_path // .path // ""' 2>/dev/null ;;
    Glob|Grep) printf '%s' "$input" | cc_jq -r '.pattern // ""' 2>/dev/null ;;
    WebFetch) printf '%s' "$input" | cc_jq -r '.url // ""' 2>/dev/null ;;
    WebSearch) printf '%s' "$input" | cc_jq -r '.query // ""' 2>/dev/null ;;
    *) printf '%s' "$input" | cc_jq -r 'if type == "object" then (.[] | tostring | tostring)? // "" else tostring end' 2>/dev/null | head -n 1 ;;
  esac
}

# _on_stop_notify_enabled — reads config.toml for `on_stop_notify = true`.
_on_stop_notify_enabled() {
  local cfg="$CC_SSH_HOME/config.toml"
  [[ -r "$cfg" ]] || return 1
  grep -E '^[[:space:]]*on_stop_notify[[:space:]]*=[[:space:]]*true' "$cfg" >/dev/null 2>&1
}

# _subagent_counter_inc <sid> <agent_type> -> echo new counter (1-based).
_subagent_counter_inc() {
  local sid="$1" atype="${2:-_anon}"
  local wid="${CMUX_WORKSPACE_ID:-}"
  [[ -z "$wid" ]] && { echo 0; return; }
  local f="$CC_SSH_STATE_DIR/$wid/$sid.subagent-counters"
  cc_ensure_dir "$(dirname "$f")"
  local key
  key="$(printf '%s' "$atype" | tr -c 'A-Za-z0-9_' '_')"
  local cur=0
  if [[ -r "$f" ]]; then
    cur="$(awk -v k="$key" '$1==k { print $2; exit }' "$f")"
    [[ -z "$cur" ]] && cur=0
  fi
  local new=$((cur + 1))
  if [[ -r "$f" ]]; then
    awk -v k="$key" -v n="$new" '
      BEGIN { found=0 }
      $1==k { print k, n; found=1; next }
      { print }
      END { if (!found) print k, n }
    ' "$f" >"$f.tmp"
    mv -f "$f.tmp" "$f"
  else
    printf '%s %s\n' "$key" "$new" >"$f"
  fi
  printf '%s' "$new"
}

# _compute_phase_for_session <sid> — used by PreCompact to record prior phase.
_compute_phase_for_session() {
  local sid="$1"
  local wid="${CMUX_WORKSPACE_ID:-}"
  local f="$CC_SSH_STATE_DIR/$wid/$sid.jsonl"
  [[ -r "$f" ]] || { printf 'ready'; return; }
  if declare -F compute_session_state >/dev/null 2>&1; then
    local s
    s="$(compute_session_state "$f" "claude" "$(cc_now_s)")"
    printf '%s' "$s" | cc_jq -r '.phase // "ready"' 2>/dev/null
  else
    printf 'ready'
  fi
}
