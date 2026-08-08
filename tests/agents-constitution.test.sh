#!/usr/bin/env bash
# Direct contract tests for the thin Firstmate instruction architecture.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AGENTS="$ROOT/AGENTS.md"
REF_ROOT="$ROOT/docs/agents"

test_size_bound() {
  local lines bytes
  lines=$(wc -l < "$AGENTS" | tr -d ' ')
  bytes=$(wc -c < "$AGENTS" | tr -d ' ')
  [ "$lines" -le 300 ] || fail "AGENTS.md has $lines lines; thin constitution limit is 300"
  [ "$bytes" -lt 30000 ] || fail "AGENTS.md has $bytes bytes; expected a genuinely thin instruction surface"
  pass "AGENTS.md stays within the thin constitution bounds"
}

test_authority_and_safety_invariants() {
  assert_grep "The active user's current instruction has highest authority" "$AGENTS" "active-user precedence disappeared"
  assert_grep 'Evidence outranks intention.' "$AGENTS" "evidence invariant disappeared"
  assert_grep "No PR is merged without the captain's literal merge authorization for that PR in the active conversation." "$AGENTS" "literal merge authority disappeared"
  assert_grep 'Never tear down a ship worktree until `bin/fm-teardown.sh` proves the work landed.' "$AGENTS" "teardown invariant disappeared"
  assert_grep 'Never perform a destructive or irreversible action without explicit current captain authorization.' "$AGENTS" "destructive-action boundary disappeared"
  assert_grep 'Never deploy or mutate production without explicit current captain authorization' "$AGENTS" "production boundary disappeared"
  assert_grep 'Never make a security-sensitive or client-money-touching decision without explicit current captain authorization.' "$AGENTS" "security or money boundary disappeared"
  assert_grep 'Captain-specific state, secrets, project clones, reports, and local configuration remain untracked.' "$AGENTS" "privacy boundary disappeared"
  pass "authority, merge, teardown, evidence, production, money, security, and privacy invariants remain"
}

test_role_selection_prevents_recursion() {
  assert_grep 'Repository location never assigns identity.' "$AGENTS" "path-independent identity rule disappeared"
  assert_grep 'If the active task is a bounded crewmate or scout assignment, execute that assignment directly in the assigned worktree.' "$AGENTS" "bounded-worker identity disappeared"
  assert_grep 'A bounded worker must not run `bin/fm-session-start.sh`' "$AGENTS" "bounded-worker session-start prohibition disappeared"
  assert_grep 'A bounded worker does not become Firstmate merely because its checkout contains this repository.' "$AGENTS" "Firstmate checkout recursion guard disappeared"
  assert_no_grep 'You are the first mate.' "$AGENTS" "unconditional Firstmate identity returned"
  assert_no_grep 'This file is your entire job description.' "$AGENTS" "checkout-wide job identity returned"
  assert_no_grep 'Address the user as "captain" at least once in every response.' "$AGENTS" "unqualified captain address rule returned"
  assert_no_grep 'run at every session start' "$AGENTS" "unqualified recursive session-start rule returned"
  pass "bounded workers cannot recursively promote themselves from the checkout path"
}

test_validation_mode_is_not_mandatory() {
  local count
  assert_grep 'No validation framework, including `no-mistakes`, is mandatory by repository default.' "$AGENTS" "live validation-mode rule disappeared"
  assert_grep "Validation mode follows the captain's live instruction and the active task brief." "$AGENTS" "validation precedence disappeared"
  count=$(grep -Fc 'no-mistakes' "$AGENTS")
  [ "$count" -eq 1 ] || fail "AGENTS.md contains $count no-mistakes references; expected only the non-mandatory rule"
  pass "no-mistakes is not a mandatory repository-wide instruction"
}

test_direct_references_exist_and_do_not_chain() {
  local refs ref expected
  expected='docs/agents/harness-and-runtime.md
docs/agents/merge-and-teardown.md
docs/agents/operations.md
docs/agents/secondmates.md
docs/agents/state-and-privacy.md
docs/agents/task-lifecycle.md
docs/agents/x-mode.md'
  refs=$(sed -n 's/.*](\(docs\/agents\/[^)]*\.md\)).*/\1/p' "$AGENTS" | sort -u)
  [ "$refs" = "$expected" ] || fail "root reference map differs from the seven direct references"
  while IFS= read -r ref; do
    [ -f "$ROOT/$ref" ] || fail "missing referenced file: $ref"
    assert_grep 'Load when:' "$ROOT/$ref" "$ref has no explicit load trigger"
    assert_grep 'Fresh sources:' "$ROOT/$ref" "$ref has no freshness and source attribution"
  done <<< "$refs"
  if find "$REF_ROOT" -mindepth 2 -type f -print -quit | grep -q .; then
    fail "docs/agents contains a nested reference"
  fi
  if rg -n 'docs/agents/' "$REF_ROOT" >/dev/null; then
    fail "an on-demand reference chains to another docs/agents reference"
  fi
  pass "all on-demand references are present, direct, triggered, and source-attributed"
}

test_referenced_repository_paths_exist() {
  local path
  while IFS= read -r path; do
    [ -e "$ROOT/$path" ] || [ -L "$ROOT/$path" ] || fail "referenced repository path does not exist: $path"
  done < <(
    rg --no-filename -o '`(bin|docs|\.agents/skills)/[A-Za-z0-9._/-]+' "$AGENTS" "$REF_ROOT"/*.md \
      | sed 's/^`//' \
      | sort -u
  )
  [ -L "$ROOT/CLAUDE.md" ] || fail "CLAUDE.md is not a symlink"
  [ "$(readlink "$ROOT/CLAUDE.md")" = 'AGENTS.md' ] || fail "CLAUDE.md does not point relatively to AGENTS.md"
  pass "all referenced commands and files exist and CLAUDE.md still aliases AGENTS.md"
}

test_size_bound
test_authority_and_safety_invariants
test_role_selection_prevents_recursion
test_validation_mode_is_not_mandatory
test_direct_references_exist_and_do_not_chain
test_referenced_repository_paths_exist
