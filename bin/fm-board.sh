#!/usr/bin/env bash
# fm-board.sh - read-only visual fleet board: one line per in-flight task,
# grouped by project, with a progress bar, a stage label, and an age.
#
# Entries need no manual lifecycle: every render reads live state/*.meta and
# state/*.status straight off disk, so a task appears the moment it is spawned
# and disappears the moment fm-teardown.sh removes its meta - nothing here is
# written or cached.
#
# Stage model (cheapest-first; fm-crew-state.sh is consulted only for the
# genuinely ambiguous cases - a "working" verb (implementing vs. an active
# no-mistakes run) or a "needs-decision"/"blocked" verb (possibly stale) -
# never re-deriving run-step logic that script already owns):
#   spawned    - meta exists, no status lines yet.
#   working    - a "working" status line, not a review note, not a run.
#   review     - the last "working" note mentions a line-review/fable review.
#   validating - fm-crew-state.sh reports state=working source=run-step (an
#                active no-mistakes run for this branch).
#   PR open    - meta records pr= (set once fm-pr-check.sh sees the PR).
#   gated      - fm-crew-state.sh's CURRENT state is parked/blocked, checked
#                only when the log's last verb was needs-decision/blocked
#                (the log is an append-only event log and goes stale the
#                moment a resolved gate lets the crew resume).
#   paused     - fm-crew-state.sh's CURRENT state is paused (a declared
#                external wait, not a captain-decision gate - not counted in
#                the gated-on-you footer).
#   done / failed - the log's last verb, or fm-crew-state.sh's reconciled
#                current state for a verb that turned out to be ambiguous.
# kind=secondmate tasks are excluded: they are persistent supervisors with no
# spawn-to-done lifecycle, not fleet work with a progress bar to show.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

usage() {
  cat <<'EOF'
usage: fm-board.sh [--watch]

Render the fleet board once to stdout, popup-friendly.
--watch re-renders every FM_BOARD_WATCH_INTERVAL seconds (default 3) until
ctrl-c or 'q'. Read-only; never mutates fleet state.
EOF
}

WATCH=0
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --watch) WATCH=1 ;;
  "") ;;
  *) usage >&2; exit 2 ;;
esac

BAR_WIDTH=10
CS_SEP=' · '

# Portable mtime/birth-time. macOS (BSD) stat uses -f, Linux (GNU) stat uses
# -c. Birth time (st_birthtime, -f %B) is stable across later meta appends
# (e.g. fm-pr-check.sh adding pr=) so it is the better spawn-age proxy on
# Darwin; Linux classic stat has no reliable birth time, so mtime is the best
# effort there.
if [ "$(uname)" = Darwin ]; then
  stat_mtime() { stat -f %m "$1" 2>/dev/null; }
  stat_birth() { stat -f %B "$1" 2>/dev/null; }
else
  stat_mtime() { stat -c %Y "$1" 2>/dev/null; }
  stat_birth() { stat -c %W "$1" 2>/dev/null; }
fi

spawn_epoch() {  # <meta-file>
  local b
  b=$(stat_birth "$1")
  case "$b" in
    ''|0|*[!0-9]*) stat_mtime "$1" ;;
    *) printf '%s' "$b" ;;
  esac
}

meta_get() {  # <meta-file> <key>
  [ -f "$1" ] || return 0
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# Mirrors fm-crew-state.sh's log_verb_of/log_note_of exactly (small local
# duplicate rather than sourcing that script, which runs its own main flow
# top-to-bottom and is not written as a library).
verb_of() {  # <status-line>
  local v=${1%%:*}
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  printf '%s' "$v"
}
note_of() {  # <status-line>
  case "$1" in
    *:*) local n=${1#*:}; printf '%s' "${n#"${n%%[![:space:]]*}"}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# crew_current_state: the one place this script shells out to fm-crew-state.sh.
# Prints "state|source" (e.g. "working|run-step"); "unknown|none" on any
# failure. FM_BOARD_NM_TIMEOUT bounds the no-mistakes CLI call tighter than
# fm-crew-state.sh's own 10s default, since a --watch popup re-renders every
# few seconds and must stay snappy.
crew_current_state() {  # <id>
  local id=$1 raw rest state source
  raw=$(FM_ROOT_OVERRIDE="$FM_ROOT" FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
        FM_CREW_STATE_NM_TIMEOUT="${FM_BOARD_NM_TIMEOUT:-4}" \
        "$SCRIPT_DIR/fm-crew-state.sh" "$id" 2>/dev/null) || raw=""
  raw=$(printf '%s\n' "$raw" | head -1)
  state=unknown
  source=none
  case "$raw" in
    "state: "*)
      rest=${raw#state: }
      state=${rest%%"$CS_SEP"*}
      rest=${rest#*"$CS_SEP"}
      case "$rest" in
        "source: "*)
          rest=${rest#source: }
          source=${rest%%"$CS_SEP"*}
          ;;
      esac
      ;;
  esac
  printf '%s|%s' "$state" "$source"
}

# detect_stage prints "<stage>|<slow>" where slow=1 iff this call consulted
# fm-crew-state.sh (0 for a stage decided purely from cheap, static file
# content). The caller uses that flag to decide how long a cached result may
# be trusted: a slow=1 result can go stale with NO local file change at all
# (e.g. the captain answers a gate and the crew resumes silently - see the
# needs-decision/blocked branch below), so it must expire on a short TTL
# rather than being cached indefinitely on mtimes alone.
detect_stage() {  # <id> <meta-file> <status-log>
  local id=$1 meta=$2 log=$3
  local pr last_line last_verb last_note base cs cs_state cs_source

  pr=$(meta_get "$meta" pr)
  last_line=""
  if [ -s "$log" ]; then
    last_line=$(grep -v '^[[:space:]]*$' "$log" 2>/dev/null | tail -1)
  fi
  last_verb=$(verb_of "$last_line")
  last_note=$(note_of "$last_line")

  # A live needs-decision/blocked gate overrides everything else, even an
  # already-open PR: an ask-user finding during CI monitor, or a post-PR
  # blocked: (rebase wall, credential gap), must surface as gated - not a
  # falsely-serene "PR open". This entire verb is decided and returned HERE,
  # ahead of (and never falling through into) the pr= shortcut below - an
  # earlier version let a resolved-but-unknown read fall through into the
  # pr= check and silently show "PR open" for a task the log says is gated.
  # The log verb alone is not trusted (it may already be stale - the captain
  # answered the gate and the crew resumed), so this reconciles via
  # fm-crew-state.sh once: parked/blocked confirms the gate is still live;
  # paused is a declared external wait (not a captain-decision gate, so it is
  # not counted as gated); done/failed/working map to the reconciled state;
  # anything else (unknown, none - a torn-down or unreadable target) fails
  # toward gated rather than silently dropping the one signal the captain has
  # that this task wants attention.
  if [ "$last_verb" = needs-decision ] || [ "$last_verb" = blocked ]; then
    cs=$(crew_current_state "$id")
    cs_state=${cs%%|*}
    cs_source=${cs#*|}
    case "$cs_state" in
      parked|blocked) base=gated ;;
      paused) base=paused ;;
      "done") base="done" ;;
      failed) base=failed ;;
      working)
        if [ "$cs_source" = run-step ]; then base=validating; else base=working; fi
        ;;
      *) base=gated ;;
    esac
    printf '%s|1' "$base"
    return
  fi

  if [ "$last_verb" = failed ]; then
    base=failed
  elif [ -n "$pr" ]; then
    base="PR open"
  elif [ "$last_verb" = "done" ]; then
    base="done"
  elif [ -z "$last_verb" ]; then
    base=spawned
  elif [ "$last_verb" = working ] || [ "$last_verb" = paused ]; then
    # "line-review" alone, not a bare "fable" match: this fleet runs Fable
    # everywhere, so a note like "fable crew planning approach" would
    # false-positive on "fable" alone. Misclassifying here only costs a bar
    # fraction (working 3/10 vs review 5/10), never a gate or an escalation.
    if printf '%s' "$last_note" | grep -qiE 'line-review'; then
      base=review
    else
      cs=$(crew_current_state "$id")
      cs_state=${cs%%|*}
      cs_source=${cs#*|}
      case "$cs_state" in
        parked|blocked) base=gated ;;
        paused) base=paused ;;
        "done") base="done" ;;
        failed) base=failed ;;
        working)
          if [ "$cs_source" = run-step ]; then base=validating; else base=working; fi
          ;;
        *) base=working ;;
      esac
      printf '%s|1' "$base"
      return
    fi
  else
    base=working
  fi

  printf '%s|0' "$base"
}

repeat_char() {  # <char> <count>
  local c=$1 n=$2 out='' i=0
  while [ "$i" -lt "$n" ]; do out="$out$c"; i=$((i + 1)); done
  printf '%s' "$out"
}

bar_for_stage() {  # <stage>
  local n filled empty
  case "$1" in
    spawned) n=1 ;;
    working) n=3 ;;
    review) n=5 ;;
    validating) n=7 ;;
    "PR open") n=9 ;;
    "done") n=$BAR_WIDTH ;;
    gated) printf '[%s]' "$(repeat_char '!' "$BAR_WIDTH")"; return ;;
    paused) printf '[%s]' "$(repeat_char '~' "$BAR_WIDTH")"; return ;;
    failed) printf '[%s]' "$(repeat_char 'x' "$BAR_WIDTH")"; return ;;
    *) n=0 ;;
  esac
  filled=$(repeat_char '#' "$n")
  empty=$(repeat_char '.' $((BAR_WIDTH - n)))
  printf '[%s%s]' "$filled" "$empty"
}

format_age() {  # <epoch-seconds>
  local now t d
  now=$(date +%s)
  t=$1
  case "$t" in
    ''|*[!0-9]*) printf 'age?'; return ;;
  esac
  d=$((now - t))
  [ "$d" -lt 0 ] && d=0
  if [ "$d" -lt 60 ]; then
    printf '%ds' "$d"
  elif [ "$d" -lt 3600 ]; then
    printf '%dm' $((d / 60))
  elif [ "$d" -lt 86400 ]; then
    printf '%dh%dm' $((d / 3600)) $(((d % 3600) / 60))
  else
    printf '%dd%dh' $((d / 86400)) $(((d % 86400) / 3600))
  fi
}

group_of() {  # <meta-file>
  local proj wt
  proj=$(meta_get "$1" project)
  if [ -n "$proj" ]; then
    basename "$proj"
    return
  fi
  wt=$(meta_get "$1" worktree)
  if [ -n "$wt" ]; then
    basename "$wt"
    return
  fi
  printf '(unknown)'
}

# gated_count_for: count of rendered tasks currently at the "gated" stage.
# Forward-compatible with a future bin/fm-decisions.sh: if it exists and
# prints a bare integer for --count, prefer it; otherwise fall back to the
# coarse count this render already computed.
gated_count_override() {
  local bin=$SCRIPT_DIR/fm-decisions.sh d
  [ -x "$bin" ] || return 1
  d=$(FM_ROOT_OVERRIDE="$FM_ROOT" FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
      FM_DATA_OVERRIDE="$DATA" "$bin" --count 2>/dev/null) || return 1
  case "$d" in
    ''|*[!0-9]*) return 1 ;;
    *) printf '%s' "$d"; return 0 ;;
  esac
}

# Stage cache, keyed on (id, meta mtime, status-log mtime): --watch re-renders
# every few seconds, and detect_stage's ambiguous branches shell out to the
# no-mistakes CLI (several seconds each). Neither file's mtime can change
# without a genuinely captain-relevant event (a new status append, pr= being
# recorded), so re-detecting only on a real mtime change turns the steady-
# state watch loop into pure cheap reads instead of hammering the CLI every
# cycle. Global (process-lifetime) so it persists across render_once calls in
# the --watch loop below; a bash-3.2-safe stand-in for an associative array
# via one "id<TAB>meta_mtime<TAB>status_mtime<TAB>stage<TAB>slow<TAB>stored_epoch"
# line per task.
#
# slow=1 entries additionally expire on FM_BOARD_CACHE_TTL: a "gated" or
# "validating" classification came from fm-crew-state.sh reconciling state
# that can change with NO local file write at all (the captain answers a
# needs-decision gate via `no-mistakes axi respond`, and the crew resumes
# silently - no new status append, no meta change). Caching that result on
# mtimes alone would make a resolved gate read as "gated on you" forever;
# the TTL re-checks it periodically instead. slow=0 entries (spawned, a
# done/failed/PR-open verdict read straight off the log or meta, a review
# keyword match) are derived purely from the two files already in the cache
# key, so they are valid until either mtime changes - no TTL needed.
BOARD_CACHE=""

cache_lookup() {  # <id> <meta_mtime> <status_mtime> <now_epoch> -> stage on a hit, else exit 1
  local id=$1 mm=$2 sm=$3 now=$4 line cmm csm cstage cslow cstored age
  line=$(printf '%s\n' "$BOARD_CACHE" | grep "^$id$(printf '\t')" | tail -1)
  [ -n "$line" ] || return 1
  cmm=$(printf '%s' "$line" | cut -d "$(printf '\t')" -f2)
  csm=$(printf '%s' "$line" | cut -d "$(printf '\t')" -f3)
  cstage=$(printf '%s' "$line" | cut -d "$(printf '\t')" -f4)
  cslow=$(printf '%s' "$line" | cut -d "$(printf '\t')" -f5)
  cstored=$(printf '%s' "$line" | cut -d "$(printf '\t')" -f6)
  [ "$cmm" = "$mm" ] && [ "$csm" = "$sm" ] || return 1
  if [ "$cslow" = 1 ]; then
    case "$cstored" in ''|*[!0-9]*) return 1 ;; esac
    age=$((now - cstored))
    [ "$age" -lt "${FM_BOARD_CACHE_TTL:-15}" ] || return 1
  fi
  printf '%s' "$cstage"
}

cache_store() {  # <id> <meta_mtime> <status_mtime> <stage> <slow> <now_epoch>
  BOARD_CACHE=$(printf '%s\n' "$BOARD_CACHE" | grep -v "^$1$(printf '\t')")
  BOARD_CACHE="$BOARD_CACHE
$1	$2	$3	$4	$5	$6"
}

render_once() {
  local meta id kind proj log stage epoch age bar rows in_flight=0 gated=0
  local prev_group='' group override meta_mtime status_mtime cached now_epoch
  local raw_stage slow

  now_epoch=$(date +%s)
  rows=""
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    id=$(basename "$meta" .meta)
    kind=$(meta_get "$meta" kind)
    [ -n "$kind" ] || kind=ship
    [ "$kind" = secondmate ] && continue

    log="$STATE/$id.status"
    meta_mtime=$(stat_mtime "$meta")
    status_mtime=$(stat_mtime "$log" 2>/dev/null)
    [ -n "$status_mtime" ] || status_mtime=none
    if cached=$(cache_lookup "$id" "$meta_mtime" "$status_mtime" "$now_epoch"); then
      stage=$cached
    else
      raw_stage=$(detect_stage "$id" "$meta" "$log")
      stage=${raw_stage%|*}
      slow=${raw_stage##*|}
      cache_store "$id" "$meta_mtime" "$status_mtime" "$stage" "$slow" "$now_epoch"
    fi
    epoch=$(spawn_epoch "$meta")
    group=$(group_of "$meta")

    in_flight=$((in_flight + 1))
    [ "$stage" = gated ] && gated=$((gated + 1))

    rows="$rows$group"$'\t'"$id"$'\t'"$stage"$'\t'"$epoch"$'\n'
  done

  printf 'FIRSTMATE FLEET BOARD  (%s)\n' "$(date '+%H:%M:%S')"

  if [ "$in_flight" -eq 0 ]; then
    printf '\nFleet idle - no in-flight tasks.\n'
  else
    printf '%s' "$rows" | sort -t "$(printf '\t')" -k1,1 -k2,2 | while IFS=$'\t' read -r group id stage epoch; do
      [ -n "$group" ] || continue
      if [ "$group" != "$prev_group" ]; then
        [ -n "$prev_group" ] && printf '\n'
        printf '## %s\n' "$group"
        prev_group=$group
      fi
      bar=$(bar_for_stage "$stage")
      age=$(format_age "$epoch")
      printf '  %-20s %s  %-11s %s\n' "$id" "$bar" "$stage" "$age"
    done
  fi

  override=$(gated_count_override) || override=$gated
  printf '\n---\n%d in flight - %d gated on you\n' "$in_flight" "$override"
}

if [ "$WATCH" = 1 ]; then
  trap 'exit 0' INT TERM
  # A tmux popup gives this a real pty, so `read -t` genuinely waits and a
  # keypress can break the loop early. Without a terminal on stdin (piped,
  # redirected, or /dev/null - `read` hits EOF and returns immediately
  # instead of waiting out the timeout), fall back to a plain `sleep` so a
  # non-interactive run paces itself instead of busy-spinning.
  INTERACTIVE=0
  [ -t 0 ] && INTERACTIVE=1
  while :; do
    clear
    render_once
    printf '\n(ctrl-c or q to close)\n'
    if [ "$INTERACTIVE" = 1 ]; then
      read -r -t "${FM_BOARD_WATCH_INTERVAL:-3}" -n 1 key 2>/dev/null
      case "${key:-}" in
        q|Q) break ;;
      esac
    else
      sleep "${FM_BOARD_WATCH_INTERVAL:-3}"
    fi
  done
else
  render_once
fi
