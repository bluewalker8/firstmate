#!/usr/bin/env bash
# Lint a crewmate brief before it is used to launch a task, so a malformed
# brief (hand-written or scaffold-bug output) never launches a blind
# crewmate. Ship and scout briefs only; secondmate launch prompts are
# charters and are exempt (see AGENTS.md project management).
# Usage: fm-brief-lint.sh <task-id> [--scout]
#   HARD FAIL (prints one actionable line per failure to stderr, exit 1):
#     - brief file missing
#     - an unreplaced {TASK} placeholder
#     - the exact absolute $STATE/<task-id>.status path does not appear
#       anywhere in the brief (a relative state/<task-id>.status mention
#       instead is the specific pattern this catches: the incident this
#       lint exists for is a relative path that let a crewmate create
#       state/ INSIDE its own project worktree, so the watcher never saw a
#       status write and the file got committed into the project). This is
#       a presence check, not a parse of the append instruction itself.
#   WARN (prints to stderr, exit 0):
#     - missing worktree-isolation assertion (ship briefs only)
#     - missing a definition-of-done section
#     - missing a status-protocol section
# Respects FM_HOME/FM_ROOT_OVERRIDE/FM_DATA_OVERRIDE/FM_STATE_OVERRIDE exactly
# like sibling scripts (bin/fm-brief.sh).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

SCOUT=0
POS=()
for a in "$@"; do
  case "$a" in
    --scout) SCOUT=1 ;;
    *) POS+=("$a") ;;
  esac
done
ID=${POS[0]:-}
[ -n "$ID" ] || { echo "usage: fm-brief-lint.sh <task-id> [--scout]" >&2; exit 1; }

BRIEF="$DATA/$ID/brief.md"
STATUS_ABS="$STATE/$ID.status"

FAIL=0
fail() { echo "brief-lint: FAIL: $1" >&2; FAIL=1; }
warn() { echo "brief-lint: WARN: $1" >&2; }

if [ ! -f "$BRIEF" ]; then
  fail "brief missing: $BRIEF"
  exit 1
fi

if grep -qF -- '{TASK}' "$BRIEF"; then
  fail "unreplaced {TASK} placeholder in $BRIEF - fill in the task description before spawning"
fi

if grep -qF -- "$STATUS_ABS" "$BRIEF"; then
  :
elif grep -qF -- "state/$ID.status" "$BRIEF"; then
  fail "status-protocol append target in $BRIEF is a relative path (state/$ID.status) instead of the exact absolute $STATUS_ABS - a relative path lets the crewmate create state/ INSIDE its own project worktree, invisible to the watcher"
else
  fail "status-protocol append target missing in $BRIEF - the exact absolute path $STATUS_ABS does not appear anywhere in the brief; state the append target as that exact absolute path"
fi

[ "$FAIL" -eq 0 ] || exit 1

if [ "$SCOUT" -eq 0 ]; then
  if ! grep -qiF -- "primary checkout" "$BRIEF" || ! grep -qiF -- "isolated worktree" "$BRIEF"; then
    warn "no worktree-isolation assertion found in $BRIEF - a ship brief should have the crewmate verify it is not in the primary checkout before branching"
  fi
fi

if ! grep -qiF -- "definition of done" "$BRIEF"; then
  warn "no definition-of-done section found in $BRIEF"
fi

if ! grep -qiF -- "status protocol" "$BRIEF" && ! grep -qF -- "Report status by appending" "$BRIEF"; then
  warn "no status-protocol section found in $BRIEF"
fi

exit 0
