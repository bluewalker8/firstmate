#!/usr/bin/env bash
# Deterministic capture entry point.  It never performs memory maintenance.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
ENGINE="$FM_ROOT/libexec/fm_capture.py"

command -v python3 >/dev/null 2>&1 || exit 0
[ -f "$ENGINE" ] || exit 0

command_name=${1:-}
[ -n "$command_name" ] || exit 64
shift

case "$command_name" in
  prompt|complete)
    # Tracked hooks exist in every linked task worktree and secondmate home.
    # Only the primary checkout may capture Blue and Firstmate turns.
    [ -f "$FM_ROOT/.fm-secondmate-home" ] && exit 0
    git_dir=$(git -C "$FM_ROOT" rev-parse --git-dir 2>/dev/null) || exit 0
    common_dir=$(git -C "$FM_ROOT" rev-parse --git-common-dir 2>/dev/null) || exit 0
    [ "$git_dir" = "$common_dir" ] || exit 0
    [ -f "$FM_ROOT/AGENTS.md" ] || exit 0
    ;;
  exchange)
    ;;
  *)
    printf 'usage: fm-turn-capture.sh {prompt|complete|exchange} [arguments]\n' >&2
    exit 64
    ;;
esac

case "$command_name" in
  prompt) engine_command=capture-prompt ;;
  complete) engine_command=capture-complete ;;
  exchange) engine_command=capture-exchange ;;
esac

if [ -n "${FM_BRAIN_HOME:-}" ]; then
  exec python3 "$ENGINE" --home "$FM_BRAIN_HOME" "$engine_command" "$@"
fi
exec python3 "$ENGINE" "$engine_command" "$@"
