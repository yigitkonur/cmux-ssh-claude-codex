#!/usr/bin/env bats
# Golden-output tests for lib/install-codex.sh.

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  export CC_SSH_HOME="$HOME/.cc-ssh"
  export CC_SSH_LOG_FILE="$CC_SSH_HOME/log/current.log"
  export CC_SSH_BIN_DIR="${BATS_TEST_DIRNAME}/../../bin"
  mkdir -p "$HOME" "$BATS_TEST_TMPDIR/stubs"
  cat >"$BATS_TEST_TMPDIR/stubs/codex" <<'EOF'
#!/usr/bin/env bash
echo "codex stub"
EOF
  chmod +x "$BATS_TEST_TMPDIR/stubs/codex"
  export PATH="$BATS_TEST_TMPDIR/stubs:$PATH"
  # shellcheck disable=SC1091
  . "${BATS_TEST_DIRNAME}/../../lib/util.sh"
  # shellcheck disable=SC1091
  . "${BATS_TEST_DIRNAME}/../../lib/install-codex.sh"
}

teardown() { rm -rf "$BATS_TEST_TMPDIR/home" "$BATS_TEST_TMPDIR/stubs"; }

@test "refuses to install when codex binary missing" {
  # Reset PATH entirely so neither the stub nor any system codex is reachable.
  PATH="/usr/empty" run install_codex --yes
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'Codex binary not found'
}

@test "first install creates config.toml with marker block" {
  install_codex --yes >/dev/null
  [ -f "$HOME/.codex/config.toml" ]
  grep -q '# BEGIN cc-ssh hooks' "$HOME/.codex/config.toml"
  grep -q '# END cc-ssh hooks' "$HOME/.codex/config.toml"
}

@test "first install registers all 6 events" {
  install_codex --yes >/dev/null
  for e in SessionStart UserPromptSubmit PreToolUse PermissionRequest PostToolUse Stop; do
    grep -q "\\[\\[hooks.$e\\]\\]" "$HOME/.codex/config.toml" || { echo "missing event: $e"; false; }
  done
}

@test "first install ensures [features] codex_hooks = true" {
  install_codex --yes >/dev/null
  grep -q '\[features\]' "$HOME/.codex/config.toml"
  grep -q 'codex_hooks = true' "$HOME/.codex/config.toml"
}

@test "feature flag set to false is updated to true" {
  mkdir -p "$HOME/.codex"
  cat >"$HOME/.codex/config.toml" <<'EOF'
model = "gpt-5"

[features]
codex_hooks = false
EOF
  install_codex --yes >/dev/null
  grep -q 'codex_hooks = true' "$HOME/.codex/config.toml"
  ! grep -q 'codex_hooks = false' "$HOME/.codex/config.toml"
}

@test "second install replaces marker block in place" {
  install_codex --yes >/dev/null
  install_codex --yes >/dev/null
  local n
  n="$(grep -c '# BEGIN cc-ssh hooks' "$HOME/.codex/config.toml")"
  [ "$n" -eq 1 ]
}

@test "preserves user-added settings outside markers" {
  mkdir -p "$HOME/.codex"
  cat >"$HOME/.codex/config.toml" <<'EOF'
model = "gpt-5"
sandbox_mode = "danger-full-access"
EOF
  install_codex --yes >/dev/null
  grep -q 'sandbox_mode' "$HOME/.codex/config.toml"
  grep -q 'model = "gpt-5"' "$HOME/.codex/config.toml"
  grep -q 'BEGIN cc-ssh hooks' "$HOME/.codex/config.toml"
}

@test "uninstall removes marker block keeping feature flag" {
  install_codex --yes >/dev/null
  uninstall_codex --yes >/dev/null
  ! grep -q 'BEGIN cc-ssh hooks' "$HOME/.codex/config.toml"
  grep -q 'codex_hooks = true' "$HOME/.codex/config.toml"
}

@test "uninstall --remove-feature-flag also removes the flag" {
  install_codex --yes >/dev/null
  uninstall_codex --yes --remove-feature-flag >/dev/null
  ! grep -q 'codex_hooks = true' "$HOME/.codex/config.toml"
}

@test "dry-run prints without writing" {
  install_codex --yes --dry-run >/dev/null
  [ ! -f "$HOME/.codex/config.toml" ]
}

@test "--repo writes to .codex/config.toml under cwd" {
  cd "$BATS_TEST_TMPDIR"
  install_codex --repo --yes >/dev/null
  [ -f "$BATS_TEST_TMPDIR/.codex/config.toml" ]
}

@test "skips events mandated by requirements.toml" {
  export CC_SSH_CODEX_REQUIREMENTS_FILE="$BATS_TEST_TMPDIR/req.toml"
  cat >"$CC_SSH_CODEX_REQUIREMENTS_FILE" <<'EOF'
[[hooks.PreToolUse]]
command = "/opt/corp/codex-pretool"

[[hooks.Stop]]
command = "/opt/corp/codex-stop"
EOF
  run install_codex --yes
  [ "$status" -eq 0 ]
  # PreToolUse and Stop must NOT appear as our blocks.
  ! grep -q '^\[\[hooks.PreToolUse\]\]' "$HOME/.codex/config.toml"
  ! grep -q '^\[\[hooks.Stop\]\]' "$HOME/.codex/config.toml"
  # Skip-comment must appear inside the marker block.
  grep -q 'PreToolUse is mandated by requirements.toml' "$HOME/.codex/config.toml"
  grep -q 'Stop is mandated by requirements.toml' "$HOME/.codex/config.toml"
  # Other 4 events must still appear.
  for e in SessionStart UserPromptSubmit PermissionRequest PostToolUse; do
    grep -q "\[\[hooks.$e\]\]" "$HOME/.codex/config.toml"
  done
  # Stdout notice should list the skipped events.
  echo "$output" | grep -q 'PreToolUse'
  echo "$output" | grep -q 'Stop'
}

@test "no requirements.toml → all 6 events written" {
  unset CC_SSH_CODEX_REQUIREMENTS_FILE
  # Force the path to a file that doesn't exist.
  export CC_SSH_CODEX_REQUIREMENTS_FILE="$BATS_TEST_TMPDIR/nope.toml"
  install_codex --yes >/dev/null
  for e in SessionStart UserPromptSubmit PreToolUse PermissionRequest PostToolUse Stop; do
    grep -q "\[\[hooks.$e\]\]" "$HOME/.codex/config.toml"
  done
}
