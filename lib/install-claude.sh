# install-claude.sh — write marker-bracketed cc-ssh hook block into
# `~/.claude/settings.json` (or `<repo>/.claude/settings.local.json`).
# Idempotent: re-runs replace the block in place. Uninstall is symmetric.
#
# Marker format: lines `// BEGIN cc-ssh hooks` and `// END cc-ssh hooks`
# (JSONC comments). Claude Code accepts JSONC since v1.0.

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

# _claude_render_block <abs_bin_path> -> JSONC block (without surrounding {}).
_claude_render_block() {
  local bin="$1"
  local out="    // BEGIN cc-ssh hooks"
  local first=1 e
  for e in "${CLAUDE_EVENTS[@]}"; do
    if (( first == 1 )); then
      out+=$'\n    "'"$e"'": [{ "hooks": [{ "type": "command", "command": "'"$bin"' hook '"$e"'" }] }]'
      first=0
    else
      out+=$',\n    "'"$e"'": [{ "hooks": [{ "type": "command", "command": "'"$bin"' hook '"$e"'" }] }]'
    fi
  done
  out+=$'\n    // END cc-ssh hooks'
  printf '%s' "$out"
}

# _claude_chezmoi_warning <path> — return a warning string if path is chezmoi-managed.
_claude_chezmoi_warning() {
  local p="$1"
  [[ -r "$p" ]] || return 0
  if grep -q 'chezmoi' "$p" 2>/dev/null; then
    printf 'WARNING: %s appears to be chezmoi-managed.\n' "$p"
    printf '  Direct edits will be overwritten on the next `chezmoi apply`.\n'
    printf '  Add the cc-ssh hooks block to ~/.local/share/chezmoi/dot_claude/settings.json.tmpl\n'
    printf '  and re-run `chezmoi apply` instead.\n'
    return 0
  fi
  if [[ -L "$p" ]] || [[ -d "$HOME/.local/share/chezmoi/dot_claude" ]]; then
    printf 'NOTE: %s is in a chezmoi-managed tree.\n' "$p"
    printf '  Consider editing the chezmoi template instead of the rendered file.\n'
    return 0
  fi
  return 0
}

# install_claude [--repo] [--yes] [--dry-run]
install_claude() {
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

  # Pre-flight: if file exists and has content, validate JSON (allow JSONC by stripping `//` comments).
  if [[ -s "$target" ]]; then
    if ! _claude_validate_jsonc "$target"; then
      printf 'cc-ssh install --claude: %s is not valid JSON/JSONC; refusing to modify.\n' "$target" >&2
      return 1
    fi
    # Detect coexisting cmux-claude-pro entries.
    if grep -E 'cmux-claude-(pro|code)' "$target" >/dev/null 2>&1; then
      printf 'NOTE: cmux-claude-pro/cmux-claude-code hook entries detected; coexisting (preserved).\n'
    fi
  fi

  _claude_chezmoi_warning "$target"

  local block
  block="$(_claude_render_block "$bin")"

  local new_content
  new_content="$(_claude_splice_block "$target" "$block")"

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

  cp -f "$target" "${target}.cc-ssh.bak.$(date +%s)" 2>/dev/null || true
  printf '%s\n' "$new_content" >"${target}.tmp"
  mv -f "${target}.tmp" "$target"
  printf '✓ Installed cc-ssh hooks into %s (binary: %s).\n' "$target" "$bin"
  printf '  Run `cc-ssh doctor` to verify.\n'
}

# _claude_validate_jsonc <file> — strip line comments and validate JSON.
_claude_validate_jsonc() {
  local f="$1"
  # Remove `//` line comments (simple — won't handle // inside strings).
  sed -E 's://[^"]*$::' "$f" | cc_jq empty >/dev/null 2>&1
}

# _claude_splice_block <existing_file> <block> -> emit new content to stdout.
# If the existing file has the marker block, replace it in place. Otherwise
# inject a top-level "hooks" object holding the block.
_claude_splice_block() {
  local f="$1" block="$2"
  local existing=""
  if [[ -s "$f" ]]; then
    existing="$(cat "$f")"
  else
    existing="{}"
  fi

  if grep -q '// BEGIN cc-ssh hooks' "$f" 2>/dev/null; then
    # awk -v can't take multi-line strings on macOS BSD awk; pipe block via fd 3.
    local block_file="${f}.cc-ssh.block.tmp.$$"
    printf '%s\n' "$block" >"$block_file"
    awk -v bf="$block_file" '
      BEGIN { in_block = 0 }
      /\/\/ BEGIN cc-ssh hooks/ {
        while ((getline line < bf) > 0) print line
        close(bf)
        in_block = 1
        next
      }
      /\/\/ END cc-ssh hooks/ {
        in_block = 0
        next
      }
      !in_block { print }
    ' "$f"
    rm -f "$block_file"
    return
  fi

  # Need to insert. If the file is empty/{} or has no `"hooks"` key, we wrap a
  # fresh hooks object using JSONC (Claude Code supports comments).
  if [[ "$existing" =~ ^[[:space:]]*\{[[:space:]]*\}[[:space:]]*$ ]] || [[ -z "$existing" ]]; then
    printf '{\n  "hooks": {\n%s\n  }\n}\n' "$block"
    return
  fi

  # File has content. Inject a `"hooks": { ... }` key before the closing brace.
  # Strategy: locate the LAST `}` and insert before it. This is brittle for
  # deeply nested objects; we keep it simple and document the contract: we
  # treat the file as JSONC with a single top-level object.
  local without_last_brace
  without_last_brace="$(printf '%s' "$existing" | awk '
    BEGIN { lastline = 0 }
    /^[[:space:]]*\}[[:space:]]*$/ { lastline = NR }
    { lines[NR] = $0 }
    END {
      for (i = 1; i <= NR; i++) {
        if (i == lastline) continue
        print lines[i]
      }
    }
  ')"
  # Detect existing hooks object.
  if grep -q '"hooks"[[:space:]]*:' "$f"; then
    local block_file="${f}.cc-ssh.block.tmp.$$"
    printf '%s\n' "$block" >"$block_file"
    awk -v bf="$block_file" '
      BEGIN { in_hooks = 0; injected = 0 }
      {
        line = $0
        if (!injected && in_hooks && line ~ /^[[:space:]]*}[[:space:]]*,?[[:space:]]*$/) {
          print "    ,"
          while ((getline bline < bf) > 0) print bline
          close(bf)
          injected = 1
        }
        if (line ~ /"hooks"[[:space:]]*:[[:space:]]*\{/) { in_hooks = 1 }
        print line
      }
    ' "$f"
    rm -f "$block_file"
  else
    # No existing hooks key: append `"hooks": { <block> }` before final `}`.
    printf '%s' "$without_last_brace"
    # If file ended without a trailing comma on prev key, we need one.
    printf ',\n  "hooks": {\n%s\n  }\n}\n' "$block"
  fi
}

# uninstall_claude [--repo] [--yes]
uninstall_claude() {
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
  if [[ ! -r "$target" ]] || ! grep -q '// BEGIN cc-ssh hooks' "$target" 2>/dev/null; then
    printf 'cc-ssh uninstall --claude: nothing to uninstall (no marker block in %s)\n' "$target"
    return 0
  fi
  if (( yes == 0 )) && [[ -t 0 ]]; then
    printf 'About to remove cc-ssh hooks block from %s. Continue? [y/N] ' "$target"
    local ans
    read -r ans
    case "$ans" in y|Y|yes) ;; *) printf 'aborted\n'; return 1 ;; esac
  fi
  cp -f "$target" "${target}.cc-ssh.bak.$(date +%s)" 2>/dev/null || true
  awk '
    BEGIN { in_block = 0 }
    /\/\/ BEGIN cc-ssh hooks/ { in_block = 1; next }
    /\/\/ END cc-ssh hooks/ { in_block = 0; next }
    !in_block { print }
  ' "$target" >"${target}.tmp"
  mv -f "${target}.tmp" "$target"
  printf '✓ Removed cc-ssh hooks block from %s.\n' "$target"
}
