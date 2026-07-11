#!/usr/bin/env bash
# fm-board-bind.sh - idempotent installer that binds a tmux key to pop up the
# fleet board (bin/fm-board.sh --watch), hidden until pressed.
#
# Binds prefix+F by default. If prefix+F is already bound to something else
# (not our own board command), falls back to prefix+B and warns. Re-running is
# a no-op when the binding already points at our board command: tmux bind-key
# always holds exactly one command per key, so there is no way for repeat runs
# to "stack" bindings - the risk this guards is silently overwriting a
# binding that belongs to something else, not duplication.
#
# Runtime-only: this binds the key on the CURRENT tmux server via `tmux
# bind-key`, never edits ~/.tmux.conf. It prints the equivalent .tmux.conf
# line so the captain can make it permanent. Never fatal: every failure mode
# (no tmux server, both keys taken) exits 0 with an explanatory line.
#
# FM_BOARD_BIND_TMUX_ARGS lets a caller target a specific tmux server (e.g.
# "-L fmboardtest" for an isolated test server) instead of the ambient one.
# Without it, this only acts when actually inside a live tmux client ($TMUX
# set) - the "skipped when not inside tmux" contract bin/fm-bootstrap.sh's
# best-effort call relies on.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOARD_SH="$SCRIPT_DIR/fm-board.sh"

usage() {
  cat <<'EOF'
usage: fm-board-bind.sh

Bind prefix+F (fallback prefix+B) on the current tmux server to a hidden
fleet-board popup. Idempotent; never fatal. Prints the ~/.tmux.conf line to
make the binding permanent.
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "") ;;
  *) usage >&2; exit 2 ;;
esac

# shellcheck disable=SC2206  # intentional word-splitting: "-L name" etc.
TMUX_ARGS=(${FM_BOARD_BIND_TMUX_ARGS:-})

if [ ${#TMUX_ARGS[@]} -eq 0 ] && [ -z "${TMUX:-}" ]; then
  echo "fm-board-bind: not inside tmux, skipping" >&2
  exit 0
fi

tmux_cmd() { tmux "${TMUX_ARGS[@]}" "$@"; }

if ! tmux_cmd list-sessions >/dev/null 2>&1; then
  echo "fm-board-bind: no reachable tmux server, skipping" >&2
  exit 0
fi

POPUP_CMD=(display-popup -E -w 80% -h 70% "$BOARD_SH --watch")

# key_binding_line <key>: the current `bind-key -T prefix <key> ...` line, or
# empty if unbound.
key_binding_line() {
  tmux_cmd list-keys -T prefix 2>/dev/null \
    | grep -E "^bind-key[[:space:]]+-T[[:space:]]+prefix[[:space:]]+$1[[:space:]]" \
    | tail -1
}

is_our_binding() {  # <line>
  case "$1" in
    *fm-board.sh*) return 0 ;;
    *) return 1 ;;
  esac
}

bind_key() {  # <key>
  tmux_cmd bind-key -T prefix "$1" "${POPUP_CMD[@]}"
}

print_permanent_line() {  # <key>
  printf 'fm-board-bind: to make this permanent, add to ~/.tmux.conf:\n'
  printf '  bind %s display-popup -E -w 80%% -h 70%% "%s --watch"\n' "$1" "$BOARD_SH"
}

TARGET_KEY=""
existing_f=$(key_binding_line F)
if [ -n "$existing_f" ]; then
  if is_our_binding "$existing_f"; then
    exit 0
  fi
  existing_b=$(key_binding_line B)
  if [ -n "$existing_b" ]; then
    if is_our_binding "$existing_b"; then
      exit 0
    fi
    echo "fm-board-bind: prefix+F and prefix+B are both bound to something else; not overriding either. Bind a key manually, e.g.: tmux bind-key -T prefix <key> display-popup -E -w 80% -h 70% '$BOARD_SH --watch'" >&2
    exit 0
  fi
  TARGET_KEY=B
  echo "fm-board-bind: prefix+F already bound to something else, using prefix+B instead" >&2
else
  TARGET_KEY=F
fi

bind_key "$TARGET_KEY"
print_permanent_line "$TARGET_KEY"
