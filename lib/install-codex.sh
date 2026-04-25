# install-codex.sh — write marker-bracketed `[[hooks.<event>]]` block into
# `~/.codex/config.toml` (or `<repo>/.codex/config.toml`) and ensure
# `[features] codex_hooks = true` is set.

[[ -n "${_CC_SSH_INSTALL_CODEX_SOURCED:-}" ]] && return 0
_CC_SSH_INSTALL_CODEX_SOURCED=1

if ! declare -F cc_have >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  . "$(dirname "${BASH_SOURCE[0]}")/util.sh" 2>/dev/null || true
fi

CODEX_EVENTS=(SessionStart UserPromptSubmit PreToolUse PermissionRequest PostToolUse Stop)

# _codex_requirements_paths — print every requirements.toml path the platform
# might use, one per line. Codex consults requirements.toml at platform-specific
# locations (macOS Application Support, Linux XDG_CONFIG_HOME); hooks declared
# there are mandated for every Codex session and don't need (and shouldn't be)
# duplicated in user config. Override via $CC_SSH_CODEX_REQUIREMENTS_FILE for
# tests.
_codex_requirements_paths() {
  if [[ -n "${CC_SSH_CODEX_REQUIREMENTS_FILE:-}" ]]; then
    printf '%s\n' "$CC_SSH_CODEX_REQUIREMENTS_FILE"
    return 0
  fi
  case "$(uname -s)" in
    Darwin)
      printf '%s\n' "$HOME/Library/Application Support/com.openai.codex/requirements.toml"
      printf '%s\n' "$HOME/Library/Application Support/com.anthropic.codex/requirements.toml"
      ;;
    *)
      printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/codex/requirements.toml"
      ;;
  esac
  printf '%s\n' "/etc/codex/requirements.toml"
}

# _codex_requirements_events — print the set of hook events that any
# requirements.toml mandates (one event per line). Looks for `[[hooks.X]]`
# array-of-tables headers; if the same X appears in our CODEX_EVENTS list,
# we skip writing it to user config. Returns nothing when no requirements
# file exists.
_codex_requirements_events() {
  local p
  while IFS= read -r p; do
    [[ -r "$p" ]] || continue
    grep -E '^[[:space:]]*\[\[[[:space:]]*hooks\.[A-Za-z]+[[:space:]]*\]\]' "$p" \
      | sed -E 's/^[[:space:]]*\[\[[[:space:]]*hooks\.([A-Za-z]+)[[:space:]]*\]\].*/\1/' \
      | awk 'NF'
  done < <(_codex_requirements_paths)
}

_codex_config_path() {
  local repo="$1"
  if [[ "$repo" == "1" ]]; then
    cc_ensure_dir ".codex"
    printf '.codex/config.toml'
  else
    cc_ensure_dir "$HOME/.codex"
    printf '%s/.codex/config.toml' "$HOME"
  fi
}

_codex_render_block() {
  local bin="$1"
  local out="# BEGIN cc-ssh hooks"
  local e
  # Capture mandated events once (cheap; does I/O on requirements.toml paths).
  local mandated
  mandated="$(_codex_requirements_events 2>/dev/null | sort -u)"
  for e in "${CODEX_EVENTS[@]}"; do
    if [[ -n "$mandated" ]] && grep -qx "$e" <<<"$mandated"; then
      out+=$'\n# '"$e"' is mandated by requirements.toml; cc-ssh skipped it.'
      continue
    fi
    out+=$'\n[[hooks.'"$e"$']]\ncommand = "'"$bin"' codex-hook '"$e"$'"'
  done
  out+=$'\n# END cc-ssh hooks'
  printf '%s' "$out"
}

_codex_chezmoi_warning() {
  local p="$1"
  [[ -r "$p" ]] || return 0
  if grep -q 'chezmoi' "$p" 2>/dev/null; then
    printf 'WARNING: %s is chezmoi-managed.\n' "$p"
    printf '  Direct edits will be overwritten on the next `chezmoi apply`.\n'
    printf '  Add the cc-ssh hooks block to ~/.local/share/chezmoi/dot_codex/private_config.toml.tmpl\n'
    printf '  and re-run `chezmoi apply` instead.\n'
  fi
}

_codex_validate_toml() {
  local f="$1"
  if cc_have taplo; then
    taplo validate "$f" >/dev/null 2>&1
    return $?
  fi
  # Tiny sanity check: only allow lines that start with `#`, `[`, or `<key> = ...`.
  awk '
    BEGIN { ok = 1 }
    /^[[:space:]]*$/ { next }
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*\[/ { next }
    /^[[:space:]]*[A-Za-z0-9_.-]+[[:space:]]*=/ { next }
    /^[[:space:]]*"/ { next }
    /^[[:space:]]*}/ { next }
    /^[[:space:]]*]/ { next }
    /^[[:space:]]*[0-9]/ { next }
    { ok = 0 }
    END { exit (ok ? 0 : 1) }
  ' "$f"
}

# _codex_ensure_feature_flag <file>
_codex_ensure_feature_flag() {
  local f="$1"
  if grep -E '^[[:space:]]*codex_hooks[[:space:]]*=[[:space:]]*true' "$f" >/dev/null 2>&1; then
    return 0
  fi
  if grep -E '^[[:space:]]*codex_hooks[[:space:]]*=[[:space:]]*false' "$f" >/dev/null 2>&1; then
    sed -i.bak -E 's/^([[:space:]]*codex_hooks[[:space:]]*=[[:space:]]*)false/\1true/' "$f"
    rm -f "${f}.bak"
    return 0
  fi
  if grep -E '^\[features\]' "$f" >/dev/null 2>&1; then
    awk '
      /^\[features\]/ { print; print "codex_hooks = true"; injected=1; next }
      { print }
      END { if (!injected) print "" }
    ' "$f" >"${f}.tmp"
    mv -f "${f}.tmp" "$f"
  else
    printf '\n[features]\ncodex_hooks = true\n' >>"$f"
  fi
}

install_codex() {
  local repo=0 yes=0 dry=0
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --repo) repo=1; shift ;;
      --yes|-y) yes=1; shift ;;
      --dry-run|-n) dry=1; shift ;;
      *) shift ;;
    esac
  done

  if ! cc_have codex; then
    printf 'Codex binary not found in PATH. Install Codex first.\n' >&2
    return 1
  fi

  local bin
  bin="$(command -v cc-ssh 2>/dev/null || printf '%s' "$HOME/.cc-ssh/bin/cc-ssh")"
  [[ ! -x "$bin" ]] && bin="$HOME/.cc-ssh/bin/cc-ssh"

  local target
  target="$(_codex_config_path "$repo")"
  cc_ensure_dir "$(dirname "$target")"

  if [[ -s "$target" ]] && ! _codex_validate_toml "$target"; then
    printf 'cc-ssh install --codex: %s has TOML errors; refusing to modify.\n' "$target" >&2
    return 1
  fi

  _codex_chezmoi_warning "$target"

  local block
  block="$(_codex_render_block "$bin")"
  local new_content
  if [[ -s "$target" ]] && grep -q '# BEGIN cc-ssh hooks' "$target"; then
    local block_file="${target}.cc-ssh.block.tmp.$$"
    printf '%s\n' "$block" >"$block_file"
    new_content="$(awk -v bf="$block_file" '
      BEGIN { in_block = 0 }
      /^# BEGIN cc-ssh hooks/ {
        while ((getline line < bf) > 0) print line
        close(bf)
        in_block = 1
        next
      }
      /^# END cc-ssh hooks/ { in_block = 0; next }
      !in_block { print }
    ' "$target")"
    rm -f "$block_file"
  else
    if [[ -s "$target" ]]; then
      new_content="$(cat "$target")"
      new_content+=$'\n'"$block"$'\n'
    else
      new_content="$block"$'\n'
    fi
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

  cp -f "$target" "${target}.cc-ssh.bak.$(date +%s)" 2>/dev/null || true
  printf '%s\n' "$new_content" >"${target}.tmp"
  mv -f "${target}.tmp" "$target"
  _codex_ensure_feature_flag "$target"
  printf '✓ Installed cc-ssh hooks into %s.\n' "$target"
  printf '  Verified [features] codex_hooks = true.\n'
  local mandated
  mandated="$(_codex_requirements_events 2>/dev/null | sort -u)"
  if [[ -n "$mandated" ]]; then
    printf '  Skipped events mandated by requirements.toml:\n'
    while IFS= read -r evt; do
      [[ -z "$evt" ]] && continue
      printf '    · %s\n' "$evt"
    done <<<"$mandated"
  fi
  printf '  Run `cc-ssh doctor` to verify.\n'
}

uninstall_codex() {
  local repo=0 yes=0 remove_flag=0
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --repo) repo=1; shift ;;
      --yes|-y) yes=1; shift ;;
      --remove-feature-flag) remove_flag=1; shift ;;
      *) shift ;;
    esac
  done
  local target
  target="$(_codex_config_path "$repo")"
  if [[ ! -r "$target" ]] || ! grep -q '# BEGIN cc-ssh hooks' "$target" 2>/dev/null; then
    printf 'cc-ssh uninstall --codex: nothing to uninstall (no marker block in %s)\n' "$target"
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
    /^# BEGIN cc-ssh hooks/ { in_block = 1; next }
    /^# END cc-ssh hooks/ { in_block = 0; next }
    !in_block { print }
  ' "$target" >"${target}.tmp"
  mv -f "${target}.tmp" "$target"
  if (( remove_flag == 1 )); then
    sed -i.bak -E '/^[[:space:]]*codex_hooks[[:space:]]*=[[:space:]]*true[[:space:]]*$/d' "$target"
    rm -f "${target}.bak"
  fi
  printf '✓ Removed cc-ssh hooks block from %s.\n' "$target"
}
