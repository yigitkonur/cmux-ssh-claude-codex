# hook-codex.sh — Codex CLI hook handler. Reads stdin JSON, emits a one-line
# decision to stdout when policy / stop-block fires, appends to the jsonl, and
# exits 0. Always fail-open (never block Codex).
#
# Codex emits 6 hook events: SessionStart, UserPromptSubmit, PreToolUse,
# PermissionRequest, PostToolUse, Stop.
# Session ids on disk are prefixed `codex-<sid>` to avoid collision with Claude.

[[ -n "${_CC_SSH_HOOK_CODEX_SOURCED:-}" ]] && return 0
_CC_SSH_HOOK_CODEX_SOURCED=1

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
if ! declare -F policy_decide >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  . "$(dirname "${BASH_SOURCE[0]}")/policy.sh" 2>/dev/null || true
fi
if ! declare -F stop_block_decide >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  . "$(dirname "${BASH_SOURCE[0]}")/stop-block.sh" 2>/dev/null || true
fi
if ! declare -F ensure_renderer >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  . "$(dirname "${BASH_SOURCE[0]}")/render-loop.sh" 2>/dev/null || true
fi

# format_codex_tool_label <tool> <input_json> -> short tile label
format_codex_tool_label() {
  local tool="$1" input="$2"
  case "$tool" in
    Bash|shell)
      local cmd
      cmd=$(printf '%s' "$input" | cc_jq -r '.command // .cmd // ""' 2>/dev/null | head -n 1)
      printf 'Bash %s' "$(cc_truncate_str 30 "$cmd")"
      ;;
    apply_patch|Edit|Write|MultiEdit)
      local p
      p=$(printf '%s' "$input" | cc_jq -r '.path // .file_path // ""' 2>/dev/null)
      printf '%s %s' "$tool" "$(basename "$p" 2>/dev/null || printf '')"
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

_codex_first_arg_from_input() {
  local tool="$1" input="$2"
  case "$tool" in
    Bash|shell) printf '%s' "$input" | cc_jq -r '.command // .cmd // ""' 2>/dev/null ;;
    apply_patch|Edit|Write|MultiEdit) printf '%s' "$input" | cc_jq -r '.path // .file_path // ""' 2>/dev/null ;;
    *) printf '%s' "$input" | cc_jq -r 'if type == "object" then (.[] | tostring)? // "" else tostring end' 2>/dev/null | head -n 1 ;;
  esac
}

# handle_codex_hook <event> — main dispatcher.
handle_codex_hook() {
  local event="${1:-}"
  if [[ -z "${CMUX_WORKSPACE_ID:-}" ]]; then
    return 0
  fi
  local payload
  payload="$(cat)"
  if [[ -z "$payload" ]]; then
    return 0
  fi

  trap 'cc_log warn "codex hook ${event} encountered an error"; return 0' ERR

  local raw_sid sid model cwd tool_name tool_input matcher
  raw_sid=$(printf '%s' "$payload" | cc_jq -r '.session_id // .sessionId // ""' 2>/dev/null)
  [[ -z "$raw_sid" ]] && raw_sid="default"
  sid="codex-${raw_sid}"
  model=$(printf '%s' "$payload" | cc_jq -r '.model // ""' 2>/dev/null)
  cwd=$(printf '%s' "$payload" | cc_jq -r '.cwd // ""' 2>/dev/null)
  tool_name=$(printf '%s' "$payload" | cc_jq -r '.tool_name // ""' 2>/dev/null)
  tool_input=$(printf '%s' "$payload" | cc_jq -c '.tool_input // null' 2>/dev/null)
  matcher=$(printf '%s' "$payload" | cc_jq -r '.matcher // ""' 2>/dev/null)

  state_init "$sid" "codex" || return 0

  local at project
  at="$(cc_now_s)"
  if [[ -n "$cwd" ]]; then project="$(basename "$cwd")"; else project="workspace"; fi
  POLICY_CWD="$cwd" export POLICY_CWD

  case "$event" in
    SessionStart)
      if [[ "$matcher" == "clear" ]]; then
        state_truncate_jsonl "$sid"
      fi
      _codex_emit "$sid" "$(cc_jq -nc --arg evt start --arg kind codex --argjson at "$at" \
        --arg model "$model" --arg cwd "$cwd" --arg project "$project" --arg matcher "$matcher" \
        '{evt:$evt,kind:$kind,at:$at,model:$model,cwd:$cwd,project:$project,matcher:$matcher}')"
      ensure_renderer "$CMUX_WORKSPACE_ID"
      ;;

    UserPromptSubmit)
      local user_prompt
      user_prompt=$(printf '%s' "$payload" | cc_jq -r '.user_prompt // .prompt // ""' 2>/dev/null)
      _codex_emit "$sid" "$(cc_jq -nc --arg evt user_prompt_submit --argjson at "$at" \
        --arg prompt "$(cc_truncate_str 200 "$user_prompt")" \
        '{evt:$evt,at:$at,prompt:$prompt}')"
      declare -F policy_touch_presence >/dev/null 2>&1 && policy_touch_presence
      _codex_clear_notifications_if_configured
      ensure_renderer "$CMUX_WORKSPACE_ID"
      ;;

    PreToolUse)
      local first_arg label
      first_arg=$(_codex_first_arg_from_input "$tool_name" "$tool_input")
      label=$(format_codex_tool_label "$tool_name" "$tool_input")

      # Build a synthetic event the policy engine understands.
      local pol_event decision action reason rule
      pol_event=$(cc_jq -nc --arg t "$tool_name" --argjson ti "$tool_input" \
        --arg cwd "$cwd" --arg sk codex \
        '{hook_event_name:"PreToolUse",tool_name:$t,tool_input:$ti,cwd:$cwd,session_kind:$sk}')
      if declare -F policy_decide >/dev/null 2>&1; then
        decision="$(policy_decide "$pol_event")"
      else
        decision='{"action":"passthrough"}'
      fi
      action=$(printf '%s' "$decision" | cc_jq -r '.action // "passthrough"')
      reason=$(printf '%s' "$decision" | cc_jq -r '.reason // ""')
      rule=$(printf '%s' "$decision" | cc_jq -r '.rule // ""')

      _codex_emit "$sid" "$(cc_jq -nc --arg evt pre_tool --argjson at "$at" \
        --arg tool "$tool_name" --arg first_arg "$first_arg" --arg label "$label" \
        --arg decision "$action" --arg reason "$reason" --arg rule "$rule" \
        '{evt:$evt,at:$at,tool:$tool,first_arg:$first_arg,label:$label,decision:$decision,reason:$reason,rule:$rule}')"

      case "$action" in
        deny)
          cc_jq -nc --arg r "$reason" '{permissionDecision:"deny",reason:$r}'
          ;;
        allow)
          cc_jq -nc '{permissionDecision:"allow"}'
          ;;
        *)
          : ;; # passthrough — emit nothing
      esac
      ensure_renderer "$CMUX_WORKSPACE_ID"
      ;;

    PermissionRequest)
      local first_arg label
      first_arg=$(_codex_first_arg_from_input "$tool_name" "$tool_input")
      label=$(format_codex_tool_label "$tool_name" "$tool_input")
      _codex_emit "$sid" "$(cc_jq -nc --arg evt permission_request --argjson at "$at" \
        --arg tool "$tool_name" --arg first_arg "$first_arg" --arg label "$label" \
        '{evt:$evt,at:$at,tool:$tool,first_arg:$first_arg,label:$label}')"
      # Optional auto-deny when idle.
      local pol_event decision action reason
      pol_event=$(cc_jq -nc --arg t "$tool_name" --argjson ti "$tool_input" \
        --arg cwd "$cwd" --arg sk codex \
        '{hook_event_name:"PermissionRequest",tool_name:$t,tool_input:$ti,cwd:$cwd,session_kind:$sk}')
      if declare -F policy_permission_alert >/dev/null 2>&1; then
        policy_permission_alert "$pol_event" || true
      fi
      # Default cross-workspace alert.
      local short
      short="$(cc_truncate_str 60 "$first_arg")"
      cc_notify_cross_workspace "Codex permission needed" \
        "${project} · ${tool_name}: ${short}" --rule "codex_permission_request" || true
      ensure_renderer "$CMUX_WORKSPACE_ID"
      ;;

    PostToolUse)
      local first_arg label exit_code err ok
      first_arg=$(_codex_first_arg_from_input "$tool_name" "$tool_input")
      label=$(format_codex_tool_label "$tool_name" "$tool_input")
      exit_code=$(printf '%s' "$payload" | cc_jq -r '.tool_response.exit_code // .exit_code // ""' 2>/dev/null)
      err=$(printf '%s' "$payload" | cc_jq -r '.tool_response.error // ""' 2>/dev/null)
      ok="true"
      if [[ -n "$exit_code" && "$exit_code" != "0" && "$exit_code" != "null" ]]; then ok="false"; fi
      [[ -n "$err" && "$err" != "null" ]] && ok="false"
      _codex_emit "$sid" "$(cc_jq -nc --arg evt post_tool --argjson at "$at" \
        --arg tool "$tool_name" --arg first_arg "$first_arg" --arg label "$label" \
        --arg exit_code "$exit_code" --argjson ok "$ok" --arg error "$err" \
        '{evt:$evt,at:$at,tool:$tool,first_arg:$first_arg,label:$label,ok:$ok,exit_code:$exit_code,error:$error}')"
      ;;

    Stop)
      local stop_reason err
      stop_reason=$(printf '%s' "$payload" | cc_jq -r '.stop_reason // "user_turn_complete"' 2>/dev/null)
      err=$(printf '%s' "$payload" | cc_jq -r '.error // ""' 2>/dev/null)
      _codex_emit "$sid" "$(cc_jq -nc --arg evt stop --argjson at "$at" \
        --arg stop_reason "$stop_reason" --arg error "$err" \
        '{evt:$evt,at:$at,stop_reason:$stop_reason,error:$error}')"
      if [[ "$stop_reason" == "error" ]]; then
        cc_notify_cross_workspace "Codex error in ${project}" \
          "$(cc_truncate_str 200 "$err")" --rule "codex_stop_error" || true
        return 0
      fi
      # Try stop-block.
      if declare -F stop_block_decide >/dev/null 2>&1 && stop_block_enabled; then
        local sb decision_action sb_reason sb_count
        sb="$(stop_block_decide "$CMUX_WORKSPACE_ID" "$sid")"
        decision_action=$(printf '%s' "$sb" | cc_jq -r '.action // "none"')
        if [[ "$decision_action" == "block" ]]; then
          sb_reason=$(printf '%s' "$sb" | cc_jq -r '.reason')
          cc_jq -nc --arg r "$sb_reason" '{decision:"block",reason:$r}'
        else
          sb_count=$(printf '%s' "$sb" | cc_jq -r '.reason // ""')
          if [[ "$sb_count" =~ (max iterations|dedup|idle gate) ]]; then
            local kind="cap"
            [[ "$sb_count" =~ idle ]] && kind="idle"
            [[ "$sb_count" =~ dedup ]] && kind="dedup"
            stop_block_alert "$CMUX_WORKSPACE_ID" "$sid" "$kind" "$sb_count" || true
          fi
        fi
      fi
      ensure_renderer "$CMUX_WORKSPACE_ID"
      ;;

    *)
      cc_log info "codex hook unknown event=$event"
      ;;
  esac
  return 0
}

_codex_emit() {
  local sid="$1" line="$2"
  state_append_jsonl "$sid" "$line"
  state_touch_alive "$sid"
}

_codex_clear_notifications_if_configured() {
  local cfg="$CC_SSH_HOME/config.toml"
  [[ -r "$cfg" ]] || return 0
  if grep -E '^[[:space:]]*clear_notifications_on_prompt[[:space:]]*=[[:space:]]*true' "$cfg" >/dev/null 2>&1; then
    cc_have cmux && cmux rpc notification.clear '{}' >/dev/null 2>&1 || true
  fi
}
