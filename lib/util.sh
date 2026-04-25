# util.sh — small shared helpers (PATH bootstrap, log, jq fallback, atomic
# writes). Sourced by every cc-ssh subcommand.

# Guard against double-source.
[[ -n "${_CC_SSH_UTIL_SOURCED:-}" ]] && return 0
_CC_SSH_UTIL_SOURCED=1

CC_SSH_HOME="${CC_SSH_HOME:-$HOME/.cc-ssh}"
CC_SSH_STATE_DIR="$CC_SSH_HOME/state"
CC_SSH_LOG_DIR="$CC_SSH_HOME/log"
CC_SSH_LOG_FILE="$CC_SSH_LOG_DIR/current.log"

# cc_log <level> <msg...> — append a line to the log; never fails the caller.
cc_log() {
  local lvl="$1"; shift
  mkdir -p "$CC_SSH_LOG_DIR" 2>/dev/null || return 0
  printf '%s [%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$lvl" "$*" \
    >>"$CC_SSH_LOG_FILE" 2>/dev/null || return 0
}

# cc_have <cmd> — true if a command is on PATH.
cc_have() { command -v "$1" >/dev/null 2>&1; }

# cc_now_ms — milliseconds since epoch.
cc_now_ms() {
  if cc_have python3; then
    python3 -c 'import time; print(int(time.time()*1000))'
  else
    # macOS date supports %N as literal; gdate (coreutils) supports it.
    if cc_have gdate; then
      gdate +%s%3N
    else
      printf '%s000\n' "$(date +%s)"
    fi
  fi
}

# cc_now_s — seconds since epoch.
cc_now_s() { date +%s; }

# cc_ensure_dir <path> — mkdir -p with permissive-on-failure semantics.
cc_ensure_dir() { mkdir -p "$1" 2>/dev/null || true; }

# cc_atomic_write <path> <content> — write content via a tmp file + rename.
cc_atomic_write() {
  local path="$1" content="$2"
  local tmp="${path}.tmp.$$"
  cc_ensure_dir "$(dirname "$path")"
  printf '%s' "$content" >"$tmp" || return 1
  mv -f "$tmp" "$path" || { rm -f "$tmp"; return 1; }
}

# cc_jq — wraps jq; falls back to python3 -m json.tool for parse-only ops.
# When jq is absent we emit a one-time warning. Most cc-ssh paths require jq;
# the hooks only need it for stdin parsing, which we shim below.
cc_jq() {
  if cc_have jq; then
    jq "$@"
  else
    cc_log warn "jq not found; using python3 fallback (slower)"
    cc_jq_fallback "$@"
  fi
}

# cc_jq_fallback — handle the small subset of jq we use in the hot path:
#   `-r '.field'`   -> python json read
#   `-c .`          -> python compact dump
# Anything more complex returns empty + warns.
cc_jq_fallback() {
  if ! cc_have python3; then
    cc_log error "neither jq nor python3 available; cannot parse JSON"
    return 1
  fi
  python3 - "$@" <<'PY'
import sys, json
args = sys.argv[1:]
raw = sys.stdin.read()
try:
    obj = json.loads(raw) if raw.strip() else None
except Exception:
    obj = None
raw_mode = False
filt = "."
i = 0
while i < len(args):
    a = args[i]
    if a == "-r":
        raw_mode = True
    elif a == "-c":
        pass
    elif a.startswith("-"):
        pass
    else:
        filt = a
        break
    i += 1

def walk(o, path):
    cur = o
    for part in path:
        if cur is None:
            return None
        if isinstance(cur, dict):
            cur = cur.get(part)
        elif isinstance(cur, list):
            try: cur = cur[int(part)]
            except Exception: return None
        else:
            return None
    return cur

if filt in ("", "."):
    if raw_mode and isinstance(obj, str):
        print(obj)
    else:
        print(json.dumps(obj))
    sys.exit(0)

# Support .a.b.c style paths and "// default"
default = None
if "//" in filt:
    left, right = filt.split("//", 1)
    filt = left.strip()
    right = right.strip()
    try:
        default = json.loads(right)
    except Exception:
        default = right.strip('"')

parts = [p for p in filt.lstrip(".").split(".") if p]
val = walk(obj, parts)
if val is None and default is not None:
    val = default
if raw_mode and isinstance(val, str):
    print(val)
else:
    print(json.dumps(val) if val is not None else "null")
PY
}

# cc_truncate_str <max> <text> — truncate to <max> bytes with a trailing ellipsis.
cc_truncate_str() {
  local max="$1" s="$2"
  if (( ${#s} <= max )); then
    printf '%s' "$s"
  else
    printf '%s…' "${s:0:max-1}"
  fi
}

# cc_get_workspace_id — echo $CMUX_WORKSPACE_ID or empty.
cc_get_workspace_id() { printf '%s' "${CMUX_WORKSPACE_ID:-}"; }

# cc_state_workspace_dir <wid> — echo state path for a workspace.
cc_state_workspace_dir() {
  local wid="${1:-${CMUX_WORKSPACE_ID:-}}"
  printf '%s/%s' "$CC_SSH_STATE_DIR" "$wid"
}
