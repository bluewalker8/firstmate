#!/usr/bin/env bash
# Behavior tests for bin/fm-decisions.sh - the read-only pending-decisions board.
#
# Covers:
#   (a) a needs-decision task whose run-step is STILL parked -> listed
#   (b) a needs-decision task whose run-step has moved on (resumed) -> NOT listed
#   (c) a blocked task whose current state is still blocked -> listed
#   (d) a blocked task whose current state has moved on -> NOT listed
#   bounded runtime: fm-crew-state.sh is reconciled per GATED task only
#   backlog markers: each of the marker forms named in the deliverable
#   backlog age: from a since/added date when present, "?" otherwise
#   sort order: oldest first
#   an empty home prints a clean "nothing pending" line
#   the script never writes/touches state/ or data/
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DECISIONS="$ROOT/bin/fm-decisions.sh"
TMP_ROOT=$(fm_test_tmproot fm-decisions)

new_case() {  # <name> -> echoes case dir with empty state/ and data/
  local d="$TMP_ROOT/$1"
  mkdir -p "$d/state" "$d/data"
  printf '%s\n' "$d"
}

# A fake fm-crew-state.sh driven by FM_FAKE_STATE_<id-with-underscores> env
# vars, so each test controls exactly what "current state" the reconciler
# reports per task id without a real no-mistakes/tmux install. Also appends one
# line per invocation to $FM_FAKE_CALLS_LOG (when set), so a test can assert
# the bounded-runtime contract: reconciliation runs only for a gated task,
# never once per state/*.meta.
make_fake_crew_state() {  # <dir> -> echoes fake script path
  local dir=$1 f="$1/fake-crew-state.sh"
  cat > "$f" <<'SH'
#!/usr/bin/env bash
set -u
id=${1:-}
[ -n "${FM_FAKE_CALLS_LOG:-}" ] && printf '%s\n' "$id" >> "$FM_FAKE_CALLS_LOG"
var="FM_FAKE_STATE_${id//-/_}"
state="${!var:-unknown}"
printf 'state: %s · source: test-stub · fixture\n' "$state"
SH
  chmod +x "$f"
  printf '%s\n' "$f"
}

run_decisions() {  # <case-dir> [args...]
  local d=$1
  shift
  FM_STATE_OVERRIDE="$d/state" FM_DATA_OVERRIDE="$d/data" FM_CREW_STATE_BIN="$d/fake-crew-state.sh" "$DECISIONS" "$@"
}

# Snapshot of every file under the given dirs, used to prove the script under
# test writes/touches/mutates nothing. Combines mtime (catches a bare touch
# that leaves content unchanged) with a content checksum (catches an in-place
# rewrite). mtime alone is second-granularity, so callers must backdate
# fixtures with backdate_files (below) before the first snapshot: a fixture
# created and snapshotted within the same wall-clock second would otherwise
# make a same-second touch invisible to both signals at once.
snapshot_files() {  # <dir> ...
  local dir f
  for dir in "$@"; do
    find "$dir" -type f | sort | while IFS= read -r f; do
      if [ "$(uname)" = Darwin ]; then printf '%s %s ' "$f" "$(stat -f %m "$f")"; else printf '%s %s ' "$f" "$(stat -c %Y "$f")"; fi
      cksum "$f"
    done
  done
}

# Backdate every file under the given dirs to a fixed, long-past mtime, so a
# real touch by the script under test moves mtime by years and is caught by
# snapshot_files regardless of how fast the test itself runs (the test's own
# fixture-write -> snapshot -> run -> snapshot sequence otherwise completes
# well inside one wall-clock second, which would make a same-second touch
# indistinguishable from no touch at all under mtime's second granularity).
backdate_files() {  # <dir> ...
  local dir
  for dir in "$@"; do
    find "$dir" -type f -exec touch -t 202001010000 {} +
  done
}

# (a) a gated task whose run-step STILL shows the gate must be listed.
test_needs_decision_still_parked_is_listed() {
  local d; d=$(new_case parked)
  make_fake_crew_state "$d" >/dev/null
  printf 'needs-decision: pick A or B\n' > "$d/state/feat-a.status"
  : > "$d/state/feat-a.meta"
  local out; out=$(FM_FAKE_STATE_feat_a=parked run_decisions "$d")
  assert_contains "$out" "task:feat-a" "still-parked gate is listed"
  assert_contains "$out" "pick A or B" "listed item carries the gate note"
  pass "needs-decision task whose run-step is still parked is listed"
}

# (b) a gated status line whose run has moved on must NOT be listed.
test_needs_decision_resumed_not_listed() {
  local d; d=$(new_case resumed)
  make_fake_crew_state "$d" >/dev/null
  printf 'needs-decision: pick A or B\n' > "$d/state/feat-b.status"
  : > "$d/state/feat-b.meta"
  local out; out=$(FM_FAKE_STATE_feat_b=working run_decisions "$d")
  assert_not_contains "$out" "task:feat-b" "resumed gate must not be listed"
  assert_contains "$out" "nothing pending" "no other items -> clean nothing-pending line"
  pass "needs-decision whose run has moved on (resumed) is not listed"
}

# (c) a blocked task whose current state is still blocked must be listed.
test_blocked_still_blocked_is_listed() {
  local d; d=$(new_case blocked)
  make_fake_crew_state "$d" >/dev/null
  printf 'blocked: waiting on review answer\n' > "$d/state/feat-c.status"
  : > "$d/state/feat-c.meta"
  local out; out=$(FM_FAKE_STATE_feat_c=blocked run_decisions "$d")
  assert_contains "$out" "task:feat-c" "still-blocked task is listed"
  assert_contains "$out" "waiting on review answer" "listed item carries the blocked note"
  pass "blocked task whose current state is still blocked is listed"
}

# (d) a blocked task whose current state has moved on must NOT be listed.
test_blocked_resolved_not_listed() {
  local d; d=$(new_case blocked-resolved)
  make_fake_crew_state "$d" >/dev/null
  printf 'blocked: worktree dirty\n' > "$d/state/feat-d.status"
  : > "$d/state/feat-d.meta"
  local out; out=$(FM_FAKE_STATE_feat_d="done" run_decisions "$d")
  assert_not_contains "$out" "task:feat-d" "resolved blocked task must not be listed"
  pass "blocked task whose current state has moved to done is not listed"
}

# Regression: a gated task whose reconciler verdict is unresolvable (dead
# worktree, fm-crew-state.sh failure, cross-branch attribution miss - all
# reported as "unknown" or empty per fm-crew-state.sh's own header) must NEVER
# be silently dropped from the board just because its current state could not
# be confirmed. It is listed with an explicit "(unconfirmed)" tag instead.
test_needs_decision_unresolvable_is_listed_unconfirmed() {
  local d; d=$(new_case unresolvable)
  make_fake_crew_state "$d" >/dev/null
  printf 'needs-decision: pick rollout A or B\n' > "$d/state/feat-u.status"
  : > "$d/state/feat-u.meta"
  local out; out=$(FM_FAKE_STATE_feat_u=unknown run_decisions "$d")
  assert_contains "$out" "task:feat-u (unconfirmed)" "unresolvable gate is listed, tagged unconfirmed"
  assert_contains "$out" "pick rollout A or B" "unconfirmed listing still carries the gate note"
  pass "a gated task whose current state cannot be resolved is listed, not dropped"
}

test_blocked_unresolvable_is_listed_unconfirmed() {
  local d; d=$(new_case blocked-unresolvable)
  make_fake_crew_state "$d" >/dev/null
  printf 'blocked: waiting on review answer\n' > "$d/state/feat-v.status"
  : > "$d/state/feat-v.meta"
  local out; out=$(run_decisions "$d")
  assert_contains "$out" "task:feat-v (unconfirmed)" "unresolvable blocked gate is listed, tagged unconfirmed"
  pass "a blocked task whose current state cannot be resolved is listed, not dropped"
}

# Bounded runtime: the reconciler runs ONLY for gated tasks, never once per
# state/*.meta.
test_reconciler_runs_only_for_gated_tasks() {
  local d; d=$(new_case bounded)
  make_fake_crew_state "$d" >/dev/null
  local calls="$d/calls.log"
  : > "$calls"
  printf 'needs-decision: pick one\n' > "$d/state/gated-a.status"; : > "$d/state/gated-a.meta"
  printf 'blocked: stuck\n' > "$d/state/gated-b.status"; : > "$d/state/gated-b.meta"
  printf 'done: shipped\n' > "$d/state/plain-c.status"; : > "$d/state/plain-c.meta"
  printf 'working: mid-flight\n' > "$d/state/plain-d.status"; : > "$d/state/plain-d.meta"
  printf 'failed: broke\n' > "$d/state/plain-e.status"; : > "$d/state/plain-e.meta"
  FM_FAKE_STATE_gated_a=parked FM_FAKE_STATE_gated_b=blocked FM_FAKE_CALLS_LOG="$calls" \
    run_decisions "$d" >/dev/null
  local n; n=$(wc -l < "$calls" | tr -d ' ')
  [ "$n" = 2 ] || fail "expected fm-crew-state invoked exactly twice (gated tasks only), got $n"
  pass "fm-crew-state is reconciled per gated task only, not per task in state/"
}

# --- backlog markers ---------------------------------------------------

test_backlog_marker_awaiting_captain() {
  local d; d=$(new_case backlog-awaiting)
  cat > "$d/data/backlog.md" <<'EOF'
## In flight
- [ ] lloyd-silence-k9 - TEARDOWN BLOCKED: findings delivered; awaiting captain discard OK (repo: sellbychat-website, since 2026-07-08)
EOF
  local out; out=$(run_decisions "$d")
  assert_contains "$out" "backlog:lloyd-silence-k9" "awaiting-captain marker line is listed with its id"
  assert_contains "$out" "awaiting captain discard OK" "awaiting-captain marker line keeps its summary"
  pass "backlog awaiting-captain marker is listed"
}

test_backlog_marker_captain_decisions() {
  local d; d=$(new_case backlog-decisions)
  cat > "$d/data/backlog.md" <<'EOF'
## In flight
- [ ] factory-run-bar-k9 - OVERNIGHT VERDICT: captain decisions: frazer corpus + hand-read chris losses (repo: sellbychat-website, since 2026-07-07)
EOF
  local out; out=$(run_decisions "$d")
  assert_contains "$out" "backlog:factory-run-bar-k9" "captain-decisions marker line is listed with its id"
  pass "backlog captain-decisions marker is listed"
}

# Regression: `tasks-axi hold <id> --reason "<r>" --kind captain` (the
# AGENTS.md section 10 captain-gated-thread convention) renders no "awaiting
# captain"/"captain decision"/"captain open" phrasing at all - only a
# structural "(hold-kind: captain)" tag (verified against the real installed
# tasks-axi 0.2.2 CLI). This must still be caught.
test_backlog_marker_hold_kind_captain() {
  local d; d=$(new_case backlog-hold-kind)
  cat > "$d/data/backlog.md" <<'EOF'
## In flight
- [ ] decide-board-q9 - bin/fm-decisions.sh pending-decisions board (repo: firstmate) (kind: ship) (since 2026-07-10) (hold: frazer corpus call needs captain word) (hold-kind: captain)
EOF
  local out; out=$(run_decisions "$d")
  assert_contains "$out" "backlog:decide-board-q9" "tasks-axi hold --kind captain rendering is listed with its id"
  pass "backlog hold-kind: captain structural tag is listed"
}

test_backlog_marker_captain_open() {
  local d; d=$(new_case backlog-open)
  cat > "$d/data/backlog.md" <<'EOF'
# CAPTAIN OPEN (carried): rescue the 9 ghosted n8n-drop prospects?
## In flight
EOF
  local out; out=$(run_decisions "$d")
  assert_contains "$out" "backlog:-" "a free-form CAPTAIN OPEN line has no parseable id"
  assert_contains "$out" "rescue the 9 ghosted n8n-drop prospects" "CAPTAIN OPEN line keeps its summary"
  pass "backlog CAPTAIN OPEN comment line is listed"
}

test_backlog_non_marker_line_not_listed() {
  local d; d=$(new_case backlog-plain)
  cat > "$d/data/backlog.md" <<'EOF'
## In flight
- [ ] normal-task - nothing special here (repo: firstmate, since 2026-07-10)
EOF
  local out; out=$(run_decisions "$d")
  assert_not_contains "$out" "normal-task" "a line without a captain-waiting marker is not listed"
  assert_contains "$out" "nothing pending" "no markers anywhere -> clean nothing-pending line"
  pass "backlog line without a captain-waiting marker is not listed"
}

# Regression: a Done-section row is already resolved and must not resurface
# as pending, even if its own closed-out summary text happens to contain
# marker phrasing (a plausible occurrence, e.g. "captain decision recorded").
test_backlog_done_section_marker_line_not_listed() {
  local d; d=$(new_case backlog-done)
  cat > "$d/data/backlog.md" <<'EOF'
## In flight

## Done
- [x] lloyd-cert-h7 - relayed cert findings, captain decision recorded and closed - data/lloyd-cert-h7/report.md (reported 2026-07-04)
EOF
  local out; out=$(run_decisions "$d")
  assert_not_contains "$out" "lloyd-cert-h7" "a Done-section row is not listed even with marker phrasing"
  assert_contains "$out" "nothing pending" "Done-only backlog -> clean nothing-pending line"
  pass "a Done-section backlog row is not listed regardless of its own wording"
}

# Regression: a "## Done" header with trailing whitespace (e.g. a stray space
# from an editor pass, or a CRLF-tainted line) must still suppress its section
# for an UNCHECKED free-form row - the checked-row safety net only catches
# canonical `- [x]` rows, so this is the scenario that actually closes the gap.
test_backlog_done_header_trailing_whitespace_not_listed() {
  local d; d=$(new_case backlog-done-trailing-ws)
  {
    printf '## In flight\n'
    printf '\n'
    printf '## Done \n'
    printf -- '- old-note - captain decision recorded, already resolved (reported 2026-07-01)\n'
  } > "$d/data/backlog.md"
  local out; out=$(run_decisions "$d")
  assert_not_contains "$out" "old-note" "a Done header with trailing whitespace must still suppress its section"
  pass "a ## Done header with trailing whitespace still skips its section"
}

# A checked [x] row is skipped regardless of section, as a second safety net.
test_backlog_checked_row_not_listed() {
  local d; d=$(new_case backlog-checked)
  cat > "$d/data/backlog.md" <<'EOF'
## In flight
- [x] closed-item - captain decision recorded (repo: alpha, since 2026-07-01)
EOF
  local out; out=$(run_decisions "$d")
  assert_not_contains "$out" "closed-item" "a checked row is not listed even carrying a marker"
  pass "a checked backlog row is not listed regardless of section"
}

test_backlog_age_from_since_date() {
  local d; d=$(new_case backlog-since)
  cat > "$d/data/backlog.md" <<'EOF'
## In flight
- [ ] old-item - awaiting captain word on old-item (repo: alpha, since 2020-01-01)
EOF
  local out; out=$(run_decisions "$d")
  assert_contains "$out" "backlog:old-item" "since-dated marker line is listed"
  assert_not_contains "$out" "? backlog:old-item" "a parseable since date must not report an unknown age"
  pass "backlog age is computed from a since <date> token"
}

test_backlog_unknown_age_is_question_mark() {
  local d; d=$(new_case backlog-noage)
  cat > "$d/data/backlog.md" <<'EOF'
## In flight
- [ ] no-date-item - captain decision needed, no date recorded (repo: alpha)
EOF
  local out; out=$(run_decisions "$d")
  assert_contains "$out" "? backlog:no-date-item" "a marker line with no since/added date reports age ?"
  pass "backlog line with no since/added date reports age as ?"
}

test_sorted_oldest_first() {
  local d; d=$(new_case sorted)
  cat > "$d/data/backlog.md" <<'EOF'
## In flight
- [ ] recent-item - awaiting captain word (repo: alpha, since 2026-07-09)
- [ ] old-item - awaiting captain word (repo: alpha, since 2020-01-01)
EOF
  local out; out=$(run_decisions "$d")
  local line_old line_recent
  line_old=$(printf '%s\n' "$out" | grep -n 'old-item' | cut -d: -f1)
  line_recent=$(printf '%s\n' "$out" | grep -n 'recent-item' | cut -d: -f1)
  if [ -z "$line_old" ] || [ -z "$line_recent" ]; then
    fail "both fixture rows must appear in the output"
  fi
  [ "$line_old" -lt "$line_recent" ] || fail "the older item must sort before the more recent one"
  pass "items are sorted oldest first"
}

# (empty home) prints a clean "nothing pending" line.
test_empty_home_prints_nothing_pending() {
  local d; d=$(new_case empty)
  local out; out=$(run_decisions "$d")
  [ "$out" = "nothing pending - no decisions waiting on the captain." ] \
    || fail "an empty home must print a single clean nothing-pending line, got: $out"
  pass "an empty home prints a clean nothing-pending line"
}

test_read_only_never_mutates_state() {
  local d; d=$(new_case readonly)
  make_fake_crew_state "$d" >/dev/null
  printf 'needs-decision: pick one\n' > "$d/state/feat-r.status"
  : > "$d/state/feat-r.meta"
  cat > "$d/data/backlog.md" <<'EOF'
## In flight
- [ ] r-item - awaiting captain word (repo: alpha, since 2026-07-01)
EOF
  backdate_files "$d/state" "$d/data"
  local before after
  before=$(snapshot_files "$d/state" "$d/data")
  FM_FAKE_STATE_feat_r=parked run_decisions "$d" >/dev/null
  after=$(snapshot_files "$d/state" "$d/data")
  [ "$before" = "$after" ] || fail "fm-decisions.sh must never write/touch state/ or data/"
  pass "fm-decisions.sh never mutates state/ or data/"
}

test_help_exits_zero() {
  local rc
  "$DECISIONS" --help >/dev/null 2>&1; rc=$?
  expect_code 0 "$rc" "--help exits 0"
  pass "--help exits 0"
}

test_bad_arg_exits_two() {
  local rc
  "$DECISIONS" bogus-arg >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "an unrecognized argument exits 2"
  pass "an unrecognized argument exits 2"
}

test_needs_decision_still_parked_is_listed
test_needs_decision_resumed_not_listed
test_blocked_still_blocked_is_listed
test_blocked_resolved_not_listed
test_needs_decision_unresolvable_is_listed_unconfirmed
test_blocked_unresolvable_is_listed_unconfirmed
test_reconciler_runs_only_for_gated_tasks
test_backlog_marker_awaiting_captain
test_backlog_marker_captain_decisions
test_backlog_marker_hold_kind_captain
test_backlog_marker_captain_open
test_backlog_non_marker_line_not_listed
test_backlog_done_section_marker_line_not_listed
test_backlog_done_header_trailing_whitespace_not_listed
test_backlog_checked_row_not_listed
test_backlog_age_from_since_date
test_backlog_unknown_age_is_question_mark
test_sorted_oldest_first
test_empty_home_prints_nothing_pending
test_read_only_never_mutates_state
test_help_exits_zero
test_bad_arg_exits_two

echo "all fm-decisions tests passed"
