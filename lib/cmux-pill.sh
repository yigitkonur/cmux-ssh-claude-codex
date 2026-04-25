# cmux-pill — sidebar pill emulation via workspace.action verbs.
#
# This file is the single chokepoint for cmux RPC primitives across cc-ssh.
# Every other module reaches the daemon via `cmux-pill` or
# `cc_notify_cross_workspace` (cmux-notify.sh).
#
# Forward-compat: when cmux ships first-class `set_status`, `log`, or
# `set_progress` verbs, this file is the only place that changes. Replace
# the description-stacking trick with the native verb and the rest of the
# codebase keeps working. The seven primitives we use today (rename,
# set_color/clear_color, set_description/clear_description,
# notification.create) are the only ones verified working on the current
# nightly — see README.md § "What this tool does NOT depend on".
#
# Source this file (or copy the function) from your shell init. Requires `jq` and
# `cmux` on PATH.
#
# Usage:
#   cmux-pill set    [--ws WS] "title"  ["description"]   ["#hex"]
#   cmux-pill title  [--ws WS] "title"
#   cmux-pill desc   [--ws WS] "description"|""
#   cmux-pill color  [--ws WS] "#hex"|""|clear
#   cmux-pill clear  [--ws WS]
#
# Notes:
#   - WS defaults to $CMUX_WORKSPACE_ID (auto-set inside cmux-managed shells).
#   - Description is rendered as a stacked multi-line list inside the workspace
#     tile. Use $'line1\nline2\nline3' (Bash $'…' or printf) to embed newlines.
#   - Title is auto-overwritten by cmux when the running process re-titles itself
#     (e.g. shell prompt, agent's task title). Set the pill *just before* you need
#     it; the auto stop-hook notification will snapshot it ~3-4s after rename.
#   - Color and description survive process re-titles. Only `rename` is volatile.
#   - clear_color / clear_description (used internally) are the canonical revert
#     verbs — `set_color ""`/`set_description ""` are rejected by the daemon.

cmux-pill() {
  local sub="$1"; shift || { echo "usage: cmux-pill {set|title|desc|color|clear} [--ws WS] args" >&2; return 2; }
  local ws="$CMUX_WORKSPACE_ID"
  if [[ "$1" == "--ws" ]]; then ws="$2"; shift 2; fi
  if [[ -z "$ws" ]]; then
    echo "cmux-pill: no workspace id (set --ws or run inside a cmux shell)" >&2
    return 2
  fi

  _cmux_pill_act() {
    cmux rpc workspace.action \
      "$(jq -n --arg w "$ws" --argjson p "$1" '$p + {workspace_id:$w}')" >/dev/null
  }

  case "$sub" in
    title)
      _cmux_pill_act "$(jq -n --arg t "$1" '{action:"rename",title:$t}')"
      ;;
    desc)
      if [[ -z "$1" ]]; then
        _cmux_pill_act '{"action":"clear_description"}'
      else
        _cmux_pill_act "$(jq -n --arg d "$1" '{action:"set_description",description:$d}')"
      fi
      ;;
    color)
      if [[ -z "$1" || "$1" == clear ]]; then
        _cmux_pill_act '{"action":"clear_color"}'
      else
        _cmux_pill_act "$(jq -n --arg c "$1" '{action:"set_color",color:$c}')"
      fi
      ;;
    set)
      [[ -n "$1" ]] && _cmux_pill_act "$(jq -n --arg t "$1" '{action:"rename",title:$t}')"
      [[ -n "$2" ]] && _cmux_pill_act "$(jq -n --arg d "$2" '{action:"set_description",description:$d}')"
      [[ -n "$3" ]] && _cmux_pill_act "$(jq -n --arg c "$3" '{action:"set_color",color:$c}')"
      ;;
    clear)
      _cmux_pill_act '{"action":"clear_color"}'
      _cmux_pill_act '{"action":"clear_description"}'
      ;;
    *)
      echo "usage: cmux-pill {set|title|desc|color|clear} [--ws WS] args" >&2
      return 2
      ;;
  esac
}

# cmux-notify — cross-workspace desktop alert helper.
#
# Usage:
#   cmux-notify [--ws WS] "title" ["body"] ["subtitle"]
#
# Picks a non-active workspace by default (so the alert isn't suppressed). Pass
# --ws WS to target a specific one. Subtitle is stored but not rendered on this
# nightly — put secondary info in the body for visibility.
cmux-notify() {
  local ws=""
  if [[ "$1" == "--ws" ]]; then ws="$2"; shift 2; fi
  local title="$1" body="${2:-}" subtitle="${3:-}"
  if [[ -z "$ws" ]]; then
    ws=$(cmux list-workspaces --json |
      jq -r ".workspaces[] | select(.id != \"$CMUX_WORKSPACE_ID\") | .id" | head -1)
  fi
  if [[ -z "$ws" ]]; then
    echo "cmux-notify: no other workspace to target; falling back to active (will be suppressed)" >&2
    ws="$CMUX_WORKSPACE_ID"
  fi
  cmux rpc notification.create \
    "$(jq -n --arg w "$ws" --arg t "$title" --arg b "$body" --arg s "$subtitle" \
        '{workspace_id:$w, title:$t, body:$b, subtitle:$s}')" >/dev/null
}
