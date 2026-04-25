# install-claude.sh — write cc-ssh hook entries into ~/.claude/settings.json
# (or .claude/settings.local.json with --repo). Idempotent; re-runs replace
# our entries in place. We identify "our" hooks by command shape — any entry
# whose command matches `<bin>/cc-ssh hook <EVENT>` — instead of by text
# markers. Output is strict JSON (Claude Code v2 rejects JSONC).

[[ -n "${_CC_SSH_INSTALL_CLAUDE_SOURCED:-}" ]] && return 0
_CC_SSH_INSTALL_CLAUDE_SOURCED=1

if ! declare -F cc_have >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  . "$(dirname "${BASH_SOURCE[0]}")/util.sh" 2>/dev/null || true
fi

CLAUDE_EVENTS=(
  SessionStart UserPromptSubmit PreToolUse PostToolUse PostToolUseFailure
  PermissionRequest Stop StopFailure SubagentStart SubagentStop
  Notification SessionEnd TaskCompleted PreCompact PostCompact WorktreeCreate
)

# _claude_settings_path <repo?> -> echo target file path; create dir if needed.
_claude_settings_path() {
  local repo="$1"
  if [[ "$repo" == "1" ]]; then
    cc_ensure_dir ".claude"
    printf '.claude/settings.local.json'
  else
    cc_ensure_dir "$HOME/.claude"
    printf '%s/.claude/settings.json' "$HOME"
  fi
}

# _claude_chezmoi_warning <path> — warn if path is chezmoi-managed.
_claude_chezmoi_warning() {
  local p="$1"
  [[ -r "$p" ]] || return 0
  if grep -q 'chezmoi' "$p" 2>/dev/null; then
    printf 'WARNING: %s appears to be chezmoi-managed.\n' "$p"
    printf '  Direct edits will be overwritten on the next `chezmoi apply`.\n'
    printf '  Edit the chezmoi templates `hooks` object directly\n'
    printf '  (e.g., ~/.local/share/chezmoi/dot_claude/settings.json.tmpl).\n'
    return 0
  fi
  if [[ -L "$p" ]] || [[ -d "$HOME/.local/share/chezmoi/dot_claude" ]]; then
    printf 'NOTE: %s is in a chezmoi-managed tree.\n' "$p"
    printf '  Consider editing the chezmoi template instead of the rendered file.\n'
    return 0
  fi
  return 0
}

# _claude_strip_legacy_markers — read stdin and drop `// BEGIN/END cc-ssh hooks`
# lines so legacy JSONC files (from older cc-ssh installers) parse as strict JSON.
_claude_strip_legacy_markers() {
  sed -E '/^[[:space:]]*\/\/ (BEGIN|END) cc-ssh hooks[[:space:]]*$/d'
}

# _claude_apply_hooks <existing-content> <bin> <mode>
# mode: install | uninstall. Prints the resulting JSON to stdout.
# For each event in CLAUDE_EVENTS:
#   - drop existing entries whose command matches `/cc-ssh hook <Event>$`
#   - in install mode, append a fresh entry with the current bin path
# Empty event arrays and an empty .hooks object are pruned.
_claude_apply_hooks() {
  local input="$1" bin="$2" mode="$3"
  local events_json
  events_json="$(printf '%s\n' "${CLAUDE_EVENTS[@]}" \
    | cc_jq -R -s 'split("\n") | map(select(length>0))')"

  printf '%s' "$input" | cc_jq \
    --argjson events "$events_json" \
    --arg bin "$bin" \
    --arg mode "$mode" '
    def is_ours:
      .hooks // []
      | map((.command // "")
            | (if type == "string" then . else "" end)
            | test("/cc-ssh hook [A-Za-z]+$"))
      | any;
    .hooks = (.hooks // {} | if type == "object" then . else {} end)
    | reduce $events[] as $e (
        .;
        .hooks[$e] = (
          ((.hooks[$e] // []) | map(select(is_ours | not)))
          + (if $mode == "install"
             then [{ hooks: [{ type: "command", command: ($bin + " hook " + $e) }] }]
             else [] end)
        )
        | (if (.hooks[$e] | length) == 0 then del(.hooks[$e]) else . end)
      )
    | (if (.hooks | length) == 0 then del(.hooks) else . end)
  '
}

# install_claude [--repo] [--yes] [--dry-run]
install_claude() {
  cc_have jq || {
    printf 'cc-ssh install --claude requires jq (brew install jq).\n' >&2
    return 1
  }

  local repo=0 yes=0 dry=0
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --repo) repo=1; shift ;;
      --yes|-y) yes=1; shift ;;
      --dry-run|-n) dry=1; shift ;;
      *) shift ;;
    esac
  done

  local bin
  bin="$(command -v cc-ssh 2>/dev/null || printf '%s' "$HOME/.cc-ssh/bin/cc-ssh")"
  if [[ ! -x "$bin" ]]; then
    bin="$HOME/.cc-ssh/bin/cc-ssh"
  fi

  local target
  target="$(_claude_settings_path "$repo")"
  cc_ensure_dir "$(dirname "$target")"

  local existing
  if [[ -s "$target" ]]; then
    existing="$(_claude_strip_legacy_markers <"$target")"
  else
    existing='{}'
  fi

  if ! printf '%s' "$existing" | cc_jq empty >/dev/null 2>&1; then
    printf 'cc-ssh install --claude: %s is not valid JSON; refusing to modify.\n' "$target" >&2
    return 1
  fi

  if printf '%s' "$existing" | grep -E 'cmux-claude-(pro|code)' >/dev/null 2>&1; then
    printf 'NOTE: cmux-claude-pro/cmux-claude-code hook entries detected; coexisting (preserved).\n'
  fi

  _claude_chezmoi_warning "$target"

  local new_content
  new_content="$(_claude_apply_hooks "$existing" "$bin" install)" || {
    printf 'cc-ssh install --claude: failed to render new settings.\n' >&2
    return 1
  }

  if ! printf '%s' "$new_content" | cc_jq empty >/dev/null 2>&1; then
    printf 'cc-ssh install --claude: rendered settings did not parse as JSON; aborting.\n' >&2
    return 1
  fi

  if (( dry == 1 )); then
    printf '\n=== dry-run: would write the following to %s ===\n' "$target"
    printf '%s\n' "$new_content"
    return 0
  fi

  if (( yes == 0 )) && [[ -t 0 ]]; then
    printf 'About to write %s. Continue? [y/N] ' "$target"
    local ans
    read -r ans
    case "$ans" in y|Y|yes) ;; *) printf 'aborted\n'; return 1 ;; esac
  fi

  local tmp="$target.tmp.$$"
  # shellcheck disable=SC2064
  trap "rm -f '$tmp'" RETURN

  if [[ -f "$target" ]]; then
    cp -p "$target" "$target.cc-ssh.bak.$(cc_now_s)" 2>/dev/null || true
  fi
  printf '%s\n' "$new_content" >"$tmp" || return 1
  mv -f "$tmp" "$target" || return 1

  printf '✓ Installed cc-ssh hooks into %s (binary: %s).\n' "$target" "$bin"
  printf '  Run `cc-ssh doctor` to verify.\n'
}

# uninstall_claude [--repo] [--yes]
uninstall_claude() {
  cc_have jq || {
    printf 'cc-ssh uninstall --claude requires jq.\n' >&2
    return 1
  }

  local repo=0 yes=0
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --repo) repo=1; shift ;;
      --yes|-y) yes=1; shift ;;
      *) shift ;;
    esac
  done

  local target
  target="$(_claude_settings_path "$repo")"
  if [[ ! -r "$target" ]]; then
    printf 'cc-ssh uninstall --claude: nothing to uninstall (no settings file at %s)\n' "$target"
    return 0
  fi

  local existing
  existing="$(_claude_strip_legacy_markers <"$target")"
  if ! printf '%s' "$existing" | cc_jq empty >/dev/null 2>&1; then
    printf 'cc-ssh uninstall --claude: %s is not valid JSON; refusing to modify.\n' "$target" >&2
    return 1
  fi

  if ! printf '%s' "$existing" \
    | cc_jq -e '[.. | .command? | strings | select(test("/cc-ssh hook "))] | length > 0' \
    >/dev/null 2>&1; then
    printf 'cc-ssh uninstall --claude: nothing to uninstall (no cc-ssh entries in %s)\n' "$target"
    return 0
  fi

  if (( yes == 0 )) && [[ -t 0 ]]; then
    printf 'About to remove cc-ssh hooks from %s. Continue? [y/N] ' "$target"
    local ans
    read -r ans
    case "$ans" in y|Y|yes) ;; *) printf 'aborted\n'; return 1 ;; esac
  fi

  local bin
  bin="$(command -v cc-ssh 2>/dev/null || printf '%s' "$HOME/.cc-ssh/bin/cc-ssh")"

  local new_content
  new_content="$(_claude_apply_hooks "$existing" "$bin" uninstall)" || return 1

  local tmp="$target.tmp.$$"
  # shellcheck disable=SC2064
  trap "rm -f '$tmp'" RETURN

  cp -p "$target" "$target.cc-ssh.bak.$(cc_now_s)" 2>/dev/null || true
  printf '%s\n' "$new_content" >"$tmp" || return 1
  mv -f "$tmp" "$target" || return 1

  printf '✓ Removed cc-ssh hooks from %s.\n' "$target"
}
