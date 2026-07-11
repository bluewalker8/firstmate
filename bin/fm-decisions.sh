#!/usr/bin/env bash
# fm-decisions.sh - read-only pending-decisions board for this firstmate home.
#
# Answers "what is waiting on the captain right now" from two sources:
#
#   1. Live tasks: for every state/<id>.meta whose status log's last non-empty
#      line has verb needs-decision or blocked, reconcile through
#      bin/fm-crew-state.sh <id> before listing it. A crew's status log is an
#      append-only EVENT log (see fm-crew-state.sh's own header), so a
#      needs-decision/blocked line that the run-step has since moved past is
#      stale - the gate resolved and the crew silently resumed. A needs-
#      decision line whose current state is genuinely "parked", or a blocked
#      line whose current state is genuinely "blocked", is listed as-is. This
#      mirrors the pending_decision/blocked_event fields fm-fleet-snapshot.sh
#      already computes the same way. When the reconciler cannot resolve a
#      verdict at all (a dead/torn-down worktree, an fm-crew-state.sh failure,
#      or a cross-branch attribution miss - all documented in its own header
#      as "unknown"/empty), the gate is NOT assumed resolved: it is still
#      listed, tagged "(unconfirmed)", so a genuinely pending decision can
#      never silently vanish just because its current state could not be read.
#      Only a verdict that positively resolves to something other than the
#      expected gate (working/done/failed/paused) is dropped as resolved.
#   2. data/backlog.md: any In-flight or Queued line (Done rows are already
#      resolved and are skipped, tracking the "## " section headers) carrying
#      an explicit captain-waiting marker (case-insensitive: "awaiting
#      captain", "captain decision", "captain open" - which also match the
#      "captain decisions:" and "awaiting captain discard OK" phrasings seen
#      in practice; plus the structural "hold-kind: captain" tag that
#      `tasks-axi hold <id> --kind captain` renders into the line, per
#      AGENTS.md section 10's captain-gated-thread convention). A checked
#      `[x]` row is also skipped regardless of section, since a marker phrase
#      in its own closed-out summary text (e.g. "captain decision recorded and
#      closed") is not a currently pending decision. Parsed coarsely: no
#      attempt to be clever about free-form prose.
#
# Age comes from a file mtime (the status log for a live task) or a "since
# <date>" / "added <date>" token in the backlog line; "?" when neither is
# available. Output is one line per item, oldest first, plus a footer count.
#
# Read-only: never writes, touches, or mutates state/, data/, or any watcher
# internals. Bounded runtime: fm-crew-state.sh runs only for a task whose last
# status line is already a needs-decision/blocked candidate, never once per
# task in state/.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
BACKLOG="$DATA/backlog.md"
CREW_STATE_BIN="${FM_CREW_STATE_BIN:-$SCRIPT_DIR/fm-crew-state.sh}"

usage() {
  cat <<'EOF'
usage: fm-decisions.sh

Print a read-only pending-decisions board for this firstmate home: every live
task genuinely parked at a needs-decision/blocked gate (reconciled via
fm-crew-state.sh, so a resolved-and-resumed gate is never listed), plus every
data/backlog.md line carrying an explicit captain-waiting marker. One line per
item, oldest first, with a one-line footer count.
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "") ;;
  *) usage >&2; exit 2 ;;
esac

NOW=$(date +%s)

# --- portable mtime / date-to-epoch (Darwin bsd vs Linux gnu) ---------------

path_mtime() {  # <path> -> epoch seconds, or empty on failure
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

date_to_epoch() {  # <YYYY-MM-DD> -> epoch seconds at midnight, or empty on failure
  if [ "$(uname)" = Darwin ]; then
    # Anchor explicitly at midnight: `date -j -f '%Y-%m-%d'` alone fills the
    # time-of-day from the current clock instead of 00:00:00, which would
    # otherwise skew ages (and cross-platform sort order near day boundaries)
    # by up to a day relative to Linux's `date -d`, which defaults to midnight.
    date -j -f '%Y-%m-%d %H:%M:%S' "$1 00:00:00" '+%s' 2>/dev/null
  else
    date -d "$1" '+%s' 2>/dev/null
  fi
}

# Compact age label; secs < 0 (the "unknown" sentinel) prints "?".
age_label() {  # <secs>
  local s=$1
  case "$s" in ''|*[!0-9-]*) printf '?'; return ;; esac
  if [ "$s" -lt 0 ]; then
    printf '?'
  elif [ "$s" -lt 60 ]; then
    printf '%ss' "$s"
  elif [ "$s" -lt 3600 ]; then
    printf '%sm' $((s / 60))
  elif [ "$s" -lt 86400 ]; then
    printf '%sh' $((s / 3600))
  else
    printf '%sd' $((s / 86400))
  fi
}

# --- status-line parsing (same shape as fm-crew-state.sh's own helpers) -----

trim() {
  local s=${1:-}
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

last_status_line() {  # <file>
  [ -f "$1" ] || return 1
  grep -v '^[[:space:]]*$' "$1" 2>/dev/null | tail -1
}

status_verb() {  # <line>
  trim "${1%%:*}"
}

status_note() {  # <line>
  case "$1" in
    *:*) trim "${1#*:}" ;;
    *) trim "$1" ;;
  esac
}

# Current authoritative state word (working/parked/done/blocked/paused/failed/
# unknown) read from fm-crew-state.sh's one-line contract:
#   state: <s> · source: <src> · <detail>
# Empty on any failure so callers treat it as "not resolvable" (never listed).
crew_current_state() {  # <id>
  local id=$1 line
  line=$(FM_ROOT_OVERRIDE="$FM_ROOT" FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    "$CREW_STATE_BIN" "$id" 2>/dev/null) || true
  case "$line" in
    state:\ *) ;;
    *) printf ''; return ;;
  esac
  line=${line#state: }
  printf '%s' "${line%% *}"
}

# --- backlog row parsing: coarse and honest, no prose cleverness -----------

FM_DECISIONS_MARKER_RE="${FM_DECISIONS_MARKER_RE:-awaiting captain|captain decision|captain open|hold-kind:[[:space:]]*captain}"

backlog_row_id() {  # <line> -> id, or empty for a free-form/comment line
  local line=$1 out
  out=$(printf '%s' "$line" | grep -oE '^[-*][[:space:]]+\[[ xX]\][[:space:]]+[^[:space:]]+' | grep -oE '[^[:space:]]+$')
  if [ -z "$out" ]; then
    out=$(printf '%s' "$line" | sed -nE 's/^[-*][[:space:]]+\*\*([^*]+)\*\*.*/\1/p')
  fi
  printf '%s' "$out"
}

backlog_row_summary() {  # <line> -> one-line prose with the row's own prefix stripped
  local line=$1 rest
  rest=$(printf '%s' "$line" | sed -E 's/^[-*][[:space:]]+\[[ xX]\][[:space:]]+[^[:space:]]+[[:space:]]+-[[:space:]]+//')
  if [ "$rest" = "$line" ]; then
    rest=$(printf '%s' "$line" | sed -E 's/^[-*][[:space:]]+\*\*[^*]+\*\*[[:space:]]+-[[:space:]]+//')
  fi
  if [ "$rest" = "$line" ]; then
    rest=$(printf '%s' "$line" | sed -E 's/^[[:space:]]*[#*-]+[[:space:]]*//')
  fi
  trim "$rest"
}

backlog_row_date() {  # <line> -> YYYY-MM-DD from a since/added token, or empty
  printf '%s' "$1" \
    | grep -oiE '(since|added)[[:space:]]+[0-9]{4}-[0-9]{2}-[0-9]{2}' \
    | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1
}

# --- collect: RECORDS[] entries are "<secs-or--1>\t<source>\t<summary>" ----

RECORDS=()

add_record() {  # <secs-or-empty> <source> <summary>
  local secs=${1:-} src=$2 summary=$3
  case "$secs" in ''|*[!0-9]*) secs=-1 ;; esac
  RECORDS+=("$secs"$'\t'"$src"$'\t'"$summary")
}

# 1. Live tasks, gated-only, reconciled through fm-crew-state.sh.
for meta in "$STATE"/*.meta; do
  [ -e "$meta" ] || continue
  id=$(basename "$meta" .meta)
  status_log="$STATE/$id.status"
  line=$(last_status_line "$status_log") || continue
  [ -n "$line" ] || continue
  verb=$(status_verb "$line")
  case "$verb" in
    needs-decision) want=parked ;;
    blocked)        want=blocked ;;
    *)              continue ;;
  esac
  current=$(crew_current_state "$id")
  case "$current" in
    "$want") src="task:$id" ;;
    ""|unknown) src="task:$id (unconfirmed)" ;;
    *) continue ;;
  esac
  mtime=$(path_mtime "$status_log")
  secs=""
  if [ -n "$mtime" ]; then
    secs=$((NOW - mtime))
    [ "$secs" -lt 0 ] && secs=0
  fi
  add_record "$secs" "$src" "$(status_note "$line")"
done

# 2. Backlog lines carrying an explicit captain-waiting marker, skipping the
# Done section (and any individually checked row) since that work is already
# resolved even if its own summary text happens to contain marker phrasing.
if [ -f "$BACKLOG" ]; then
  section=""
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "##"*)
        section=$(printf '%s' "$line" | sed -E 's/^#+[[:space:]]*//; s/[[:space:]]+$//' | tr '[:upper:]' '[:lower:]')
        continue
        ;;
    esac
    [ "$section" = "done" ] && continue
    printf '%s' "$line" | grep -qE '^[-*][[:space:]]+\[[xX]\][[:space:]]' && continue
    printf '%s' "$line" | grep -qiE "$FM_DECISIONS_MARKER_RE" || continue
    bid=$(backlog_row_id "$line")
    bdate=$(backlog_row_date "$line")
    bsecs=""
    if [ -n "$bdate" ]; then
      bepoch=$(date_to_epoch "$bdate")
      if [ -n "$bepoch" ]; then
        bsecs=$((NOW - bepoch))
        [ "$bsecs" -lt 0 ] && bsecs=0
      fi
    fi
    add_record "$bsecs" "backlog:${bid:--}" "$(backlog_row_summary "$line")"
  done < "$BACKLOG"
fi

# --- render: sorted oldest first, unknown age ("?", sentinel -1) last ------

if [ "${#RECORDS[@]}" -eq 0 ]; then
  echo "nothing pending - no decisions waiting on the captain."
  exit 0
fi

printf '%s\n' "${RECORDS[@]}" | sort -t "$(printf '\t')" -k1,1nr \
  | while IFS=$'\t' read -r secs src summary; do
      printf '%s %s %s\n' "$(age_label "$secs")" "$src" "$summary"
    done

printf '%s pending decision(s).\n' "${#RECORDS[@]}"
