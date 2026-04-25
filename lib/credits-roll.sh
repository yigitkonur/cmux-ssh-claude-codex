# credits-roll.sh — fixed 5-lane tile formatter (1 title + 4 desc + footer)
# with cycling middle 3 rows.

[[ -n "${_CC_SSH_CREDITS_ROLL_SOURCED:-}" ]] && return 0
_CC_SSH_CREDITS_ROLL_SOURCED=1

if ! declare -F cc_have >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  . "$(dirname "${BASH_SOURCE[0]}")/util.sh" 2>/dev/null || true
fi

ROLL_PERIOD_MS="${ROLL_PERIOD_MS:-1000}"

# phase_color <phase> [<tick_ms>] — sidebar-toned palette anchored on #323343.
# Active phases (working/thinking/compacting) cycle through 8 closely-spaced
# shades to give a subtle "breathing" effect during long operations; static
# states stay on a single hue so the eye can rest. tick_ms drives the cycle
# index — pass cc_now_ms() (or any monotonic ms) to advance once per period.
phase_color() {
  local phase="$1" tick_ms="${2:-0}"
  case "$phase" in
    working|thinking|compacting)
      local cycle=( "#2d2e3d" "#323343" "#37384a" "#3d3e51" "#34344a" "#272840" "#1c1d37" "#0e0f2b" )
      local period_ms="${PHASE_CYCLE_PERIOD_MS:-${ROLL_PERIOD_MS:-1000}}"
      local idx=$(( (tick_ms / period_ms) % ${#cycle[@]} ))
      (( idx < 0 )) && idx=0
      echo "${cycle[$idx]}"
      ;;
    waiting|error)  echo "#3C3243" ;;  # warning / attention — sidebar-toned red
    done)           echo "#323F43" ;;  # completed — sidebar-toned teal
    ready|*)        echo "#323343" ;;  # sidebar base
  esac
}

# Phase priority union: error > waiting > working > thinking > compacting > ready > done
phase_priority() {
  case "$1" in
    error) echo 7 ;;
    waiting) echo 6 ;;
    working) echo 5 ;;
    thinking) echo 4 ;;
    compacting) echo 3 ;;
    ready) echo 2 ;;
    done) echo 1 ;;
    *) echo 0 ;;
  esac
}

phase_max() {
  local a="$1" b="$2"
  local pa pb
  pa="$(phase_priority "$a")"
  pb="$(phase_priority "$b")"
  if (( pa >= pb )); then echo "$a"; else echo "$b"; fi
}

# format_elapsed <seconds> — "Xs" / "XmYs" / "XhYm".
format_elapsed() {
  local s="$1"
  if (( s < 60 )); then printf '%ds' "$s"
  elif (( s < 3600 )); then printf '%dm%02ds' $((s/60)) $((s%60))
  else printf '%dh%02dm' $((s/3600)) $(((s%3600)/60))
  fi
}

# format_credits_roll <state-json> <tick_ms> — print one JSON
# {title, desc, color} where desc joins desc1..5 with newlines.
format_credits_roll() {
  local state="$1" tick_ms="${2:-0}"

  local project session_count subagent_count ops branch dirty phase elapsed
  local current_tool auto_continue bypass lanes_count
  project=$(printf '%s' "$state" | cc_jq -r '.project // "workspace"')
  session_count=$(printf '%s' "$state" | cc_jq -r '.session_count // 0')
  subagent_count=$(printf '%s' "$state" | cc_jq -r '.subagent_count // 0')
  ops=$(printf '%s' "$state" | cc_jq -r '.ops // 0')
  branch=$(printf '%s' "$state" | cc_jq -r '.git_branch // ""')
  dirty=$(printf '%s' "$state" | cc_jq -r '.git_dirty // false')
  phase=$(printf '%s' "$state" | cc_jq -r '.phase // "ready"')
  elapsed=$(printf '%s' "$state" | cc_jq -r '.elapsed_s // 0')
  current_tool=$(printf '%s' "$state" | cc_jq -r '.current_tool // ""')
  auto_continue=$(printf '%s' "$state" | cc_jq -r '.auto_continue // ""')
  bypass=$(printf '%s' "$state" | cc_jq -r '.bypass_remaining // ""')
  lanes_count=$(printf '%s' "$state" | cc_jq -r '.cycling_lanes | length // 0')

  # Title.
  local title="$project"
  if [[ "$session_count" =~ ^[0-9]+$ ]] && (( session_count >= 2 )); then
    title="$title · ${session_count} sessions"
  fi
  if [[ "$subagent_count" =~ ^[0-9]+$ ]] && (( subagent_count >= 1 )); then
    local agent_label="agents"
    (( subagent_count == 1 )) && agent_label="agent"
    title="$title · ${subagent_count} ${agent_label}"
  fi
  title="$title · ${ops} ops"
  if [[ -n "$branch" && "$branch" != "main" && "$branch" != "master" && "$branch" != "null" ]]; then
    local star=""
    [[ "$dirty" == "true" ]] && star="*"
    title="$title · git:${branch}${star}"
  fi

  # desc-1.
  local desc1=""
  if [[ -n "$current_tool" && "$current_tool" != "null" ]]; then
    desc1="$(cc_truncate_str 40 "$current_tool")"
  fi

  # desc-2/3/4 — cycling rules.
  local desc2="" desc3="" desc4=""
  if [[ "$lanes_count" =~ ^[0-9]+$ ]] && (( lanes_count > 0 )); then
    local i0 i1 i2
    if (( lanes_count <= 3 )); then
      i0=0; i1=1; i2=2
    else
      local off=$(( (tick_ms / ROLL_PERIOD_MS) % lanes_count ))
      i0=$off
      i1=$(( (off + 1) % lanes_count ))
      i2=$(( (off + 2) % lanes_count ))
    fi
    desc2=$(printf '%s' "$state" | cc_jq -r ".cycling_lanes[$i0] // \"\"")
    desc3=$(printf '%s' "$state" | cc_jq -r ".cycling_lanes[$i1] // \"\"")
    desc4=$(printf '%s' "$state" | cc_jq -r ".cycling_lanes[$i2] // \"\"")
  fi
  desc2=$(cc_truncate_str 40 "$desc2")
  desc3=$(cc_truncate_str 40 "$desc3")
  desc4=$(cc_truncate_str 40 "$desc4")

  # desc-5 footer.
  local color
  color=$(phase_color "$phase" "$tick_ms")
  local elapsed_str
  elapsed_str=$(format_elapsed "${elapsed:-0}")
  local desc5="${elapsed_str} · ${phase}"
  if [[ -n "$auto_continue" && "$auto_continue" != "null" ]]; then
    desc5="${desc5} · (auto-continue ${auto_continue})"
  fi
  if [[ -n "$bypass" && "$bypass" != "null" ]]; then
    desc5="${desc5} · bypass: ${bypass}"
  fi
  desc5=$(cc_truncate_str 60 "$desc5")

  # Combine desc rows.
  local desc
  desc="${desc1}"$'\n'"${desc2}"$'\n'"${desc3}"$'\n'"${desc4}"$'\n'"${desc5}"

  cc_jq -n --arg t "$title" --arg d "$desc" --arg c "$color" \
    '{title:$t, desc:$d, color:$c}'
}

# format_subagent_row <uuid> <agent_type> <counter> <tool> <arg>
# -> "· <short_id> → <tool> <arg>"
format_subagent_row() {
  local uuid="$1" atype="$2" counter="$3" tool="$4" arg="$5"
  local short_id
  if [[ -n "$atype" && "$atype" != "null" ]]; then
    local lc
    lc=$(printf '%s' "$atype" | tr '[:upper:]' '[:lower:]')
    short_id="${lc}-${counter}"
  else
    # Last 7 hex chars, stripped of dashes.
    local hex
    hex=$(printf '%s' "$uuid" | tr -d '-')
    short_id="${hex: -7}"
  fi
  local row="· ${short_id} → ${tool}"
  if [[ -n "$arg" && "$arg" != "null" ]]; then
    row="${row} ${arg}"
  fi
  printf '%s' "$row"
}

# format_codex_row <age_seconds> <tool> <first_arg>
# -> "· <age> <tool> <arg>"
format_codex_row() {
  local age_s="$1" tool="$2" arg="$3"
  local age_str
  if (( age_s < 60 )); then
    age_str="${age_s}s"
  elif (( age_s < 3600 )); then
    age_str="$((age_s/60))m$((age_s%60))s"
  else
    age_str="$((age_s/3600))h$(((age_s%3600)/60))m"
  fi
  local row="· ${age_str} ${tool}"
  if [[ -n "$arg" && "$arg" != "null" ]]; then
    row="${row} ${arg}"
  fi
  printf '%s' "$row"
}
