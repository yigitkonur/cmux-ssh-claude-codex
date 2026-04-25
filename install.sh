#!/usr/bin/env bash
# install.sh — convenience wrapper around `make install` and `cc-ssh install`.
#
# Usage:
#   ./install.sh                   install bin + libs to ~/.cc-ssh
#   ./install.sh --with-hooks      also run cc-ssh install --claude --codex
#   ./install.sh --system          symlink ~/.cc-ssh/bin/cc-ssh into /usr/local/bin

set -euo pipefail

WITH_HOOKS=0
SYSTEM=0
for arg in "$@"; do
  case "$arg" in
    --with-hooks) WITH_HOOKS=1 ;;
    --system)     SYSTEM=1 ;;
    -h|--help)
      sed -n '1,8p' "$0" | sed 's/^# *//'
      exit 0 ;;
    *)
      echo "install.sh: unknown flag: $arg" >&2
      exit 2 ;;
  esac
done

cd "$(dirname "$0")"
make install

if [[ "$SYSTEM" -eq 1 ]]; then
  if [[ -w /usr/local/bin ]]; then
    ln -sf "$HOME/.cc-ssh/bin/cc-ssh" /usr/local/bin/cc-ssh
    echo "Symlinked /usr/local/bin/cc-ssh -> ~/.cc-ssh/bin/cc-ssh"
  else
    echo "install.sh: /usr/local/bin not writable; rerun with sudo if you want --system" >&2
  fi
fi

if [[ "$WITH_HOOKS" -eq 1 ]]; then
  "$HOME/.cc-ssh/bin/cc-ssh" install --claude --codex
fi

echo
echo "Done. Run 'cc-ssh doctor' to verify."
