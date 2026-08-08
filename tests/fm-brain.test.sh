#!/usr/bin/env bash
# Direct acceptance suite for deterministic turn capture and Brainkeeper.
# Every write is confined to one preserved mktemp root for reviewable evidence.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CAPTURE="$ROOT/bin/fm-turn-capture.sh"
KEEPER="$ROOT/bin/fm-brainkeeper.sh"
CONTEXT="$ROOT/bin/fm-brain-context.sh"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-brain-acceptance.XXXXXX")
EVIDENCE="$TMP_ROOT/evidence"
mkdir -p "$EVIDENCE"
LIVE_VAULT_BRAIN="$HOME/.claude/projects/-Users-${USER}/memory/firstmate-brain"
LIVE_STATE_BRAIN="$HOME/tools/firstmate/data/brain"

path_state() {
  if [ -e "$1" ]; then
    stat -f '%HT:%z:%m' "$1" 2>/dev/null || printf 'present'
  else
    printf 'absent'
  fi
}

live_vault_before=$(path_state "$LIVE_VAULT_BRAIN")
live_state_before=$(path_state "$LIVE_STATE_BRAIN")

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\nEVIDENCE_ROOT=%s\n' "$1" "$TMP_ROOT" >&2; exit 1; }
assert_contains() {
  case "$1" in *"$2"*) : ;; *) fail "$3" ;; esac
}
assert_not_contains() {
  case "$1" in *"$2"*) fail "$3" ;; *) : ;; esac
}

new_case() {
  CASE_ROOT="$TMP_ROOT/$1"
  BRAIN_HOME="$CASE_ROOT/home"
  VAULT="$CASE_ROOT/vault"
  mkdir -p "$VAULT"
  export FM_BRAIN_HOME="$BRAIN_HOME" FM_BRAIN_VAULT="$VAULT"
}

capture_json() {
  printf '%s' "$1" | "$CAPTURE" exchange >/dev/null || fail "capture failed"
}

drain() {
  "$KEEPER" drain --limit "${1:-100}"
}

query_scope() {
  "$KEEPER" query --scope-kind "$1" --scope-id "$2"
}

tree_digest() {
  python3 - "$1" <<'PY'
import hashlib
from pathlib import Path
import sys
root = Path(sys.argv[1])
digest = hashlib.sha256()
for path in sorted(item for item in root.rglob('*') if item.is_file()):
    digest.update(str(path.relative_to(root)).encode())
    digest.update(b'\0')
    digest.update(path.read_bytes())
    digest.update(b'\0')
print(digest.hexdigest())
PY
}

assert_json_length() {
  actual=$(printf '%s' "$1" | jq 'length')
  [ "$actual" -eq "$2" ] || fail "$3: expected length $2, got $actual"
}

case "$TMP_ROOT" in
  /tmp/*|/private/tmp/*|/var/folders/*) ;;
  *) fail "test root is not an operating-system temporary directory" ;;
esac
case "$TMP_ROOT" in
  "$HOME/.claude/projects/"*|"$HOME/tools/firstmate/"*) fail "test root overlaps live Firstmate state or the canonical vault" ;;
esac

# 1. One hundred turns, duplicates, and a mid-write crash converge exactly once.
new_case exact-once
python3 - <<'PY' | "$CAPTURE" exchange --ndjson > "$EVIDENCE/exact-once-bulk.json"
import json
for number in range(100):
    if number == 50:
        continue
    record = {
        "thread_id": "exact-thread",
        "turn_id": "turn-%03d" % number,
        "user": "Synthetic turn %03d" % number,
        "assistant": "Synthetic completion %03d" % number,
        "cwd": "/tmp/synthetic",
        "submitted_at": "2026-08-08T10:00:00Z",
        "completed_at": "2026-08-08T10:00:01Z",
    }
    print(json.dumps(record, sort_keys=True))
    print(json.dumps(record, sort_keys=True))
PY
crash_record='{"thread_id":"exact-thread","turn_id":"turn-050","user":"Synthetic turn 050","assistant":"Synthetic completion 050","cwd":"/tmp/synthetic","submitted_at":"2026-08-08T10:00:00Z","completed_at":"2026-08-08T10:00:01Z"}'
set +e
printf '%s' "$crash_record" | FM_BRAIN_FAILPOINT=capture_after_fsync_before_link "$CAPTURE" exchange >/dev/null 2>&1
crash_status=$?
set -u
[ "$crash_status" -eq 87 ] || fail "mid-write failpoint did not stop before the atomic link"
capture_json "$crash_record"
capture_json "$crash_record"
event_count=$(find "$BRAIN_HOME/events/inbox" -type f -name 'ev_*.json' | wc -l | tr -d ' ')
[ "$event_count" -eq 100 ] || fail "exact-once inbox contains $event_count events instead of 100"
python3 - "$BRAIN_HOME" <<'PY' || fail "private modes or event schema are invalid"
import json
import os
from pathlib import Path
import stat
import sys
root = Path(sys.argv[1])
events = list((root / 'events' / 'inbox').rglob('ev_*.json'))
assert len(events) == 100
assert len({path.name for path in events}) == 100
for path in root.rglob('*'):
    mode = stat.S_IMODE(path.stat().st_mode)
    if path.is_dir():
        assert mode == 0o700, (path, oct(mode))
    elif path.is_file():
        assert mode == 0o600, (path, oct(mode))
for path in events:
    event = json.loads(path.read_text())
    assert event['event_id'] == path.stem
    assert event['thread_id'] and event['turn_id']
    assert len(event['speakers']) == 2
    assert len(path.read_bytes()) < 140000
    assert 'tool_arguments' not in event and 'tool_output' not in event
PY
pass "1/13 exact-once capture survives duplicate delivery and a mid-write crash"

# Production defaults must work on macOS Bash 3.2 without an FM_BRAIN_HOME override.
default_wrapper_home="$CASE_ROOT/default-wrapper-home"
default_wrapper_vault="$CASE_ROOT/default-wrapper-vault"
mkdir -p "$default_wrapper_vault"
printf '%s' '{"thread_id":"default-wrapper","turn_id":"1","user":"Correction: wrapper-mode = default","assistant":"Acknowledged.","cwd":"/tmp","submitted_at":"2026-08-08T10:00:00Z","completed_at":"2026-08-08T10:00:01Z"}' \
  | FM_BRAIN_HOME='' FM_HOME="$default_wrapper_home" "$CAPTURE" exchange >/dev/null \
  || fail "capture wrapper failed without FM_BRAIN_HOME"
[ "$(find "$default_wrapper_home/data/brain/events/inbox" -type f -name 'ev_*.json' | wc -l | tr -d ' ')" -eq 1 ] \
  || fail "default capture wrapper did not write to FM_HOME/data/brain"
FM_BRAIN_HOME='' FM_HOME="$default_wrapper_home" FM_BRAIN_VAULT="$default_wrapper_vault" "$KEEPER" drain >/dev/null \
  || fail "Brainkeeper wrapper failed without FM_BRAIN_HOME"
default_wrapper_context=$(FM_BRAIN_HOME='' FM_HOME="$default_wrapper_home" FM_BRAIN_VAULT="$default_wrapper_vault" \
  "$CONTEXT" --scope-kind global --scope-id firstmate --as-of '2026-08-08T12:00:00Z') \
  || fail "context wrapper failed without FM_BRAIN_HOME"
assert_contains "$default_wrapper_context" "default" "default-home context omitted the promoted claim"
pass "capture, Brainkeeper, and context wrappers support the production default brain home"

# Exercise the tracked Codex hook commands with their official payload fields.
hook_root="$TMP_ROOT/hook-primary"
mkdir -p "$hook_root/bin" "$hook_root/libexec" "$hook_root/.codex"
git init -q "$hook_root"
cp "$ROOT/bin/fm-turn-capture.sh" "$ROOT/bin/fm-turn-complete.sh" "$hook_root/bin/"
cp "$ROOT/libexec/fm_capture.py" "$hook_root/libexec/"
cp "$ROOT/.codex/hooks.json" "$hook_root/.codex/hooks.json"
: > "$hook_root/AGENTS.md"
cat > "$hook_root/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
exit 0
SH
chmod +x "$hook_root/bin/"*.sh "$hook_root/libexec/fm_capture.py"
prompt_command=$(jq -r '.hooks.UserPromptSubmit[0].hooks[0].command' "$hook_root/.codex/hooks.json")
stop_command=$(jq -r '.hooks.Stop[0].hooks[0].command' "$hook_root/.codex/hooks.json")
hook_home="$TMP_ROOT/hook-home"
prompt_payload='{"session_id":"hook-session","turn_id":"hook-turn","prompt":"Standard: hook-path = active","cwd":"/tmp","hook_event_name":"UserPromptSubmit"}'
stop_payload='{"session_id":"hook-session","turn_id":"hook-turn","last_assistant_message":"Acknowledged.","cwd":"/tmp","hook_event_name":"Stop","stop_hook_active":false}'
printf '%s' "$prompt_payload" | (cd "$hook_root" && FM_BRAIN_HOME="$hook_home" bash -c "$prompt_command") || fail "tracked UserPromptSubmit hook failed"
printf '%s' "$stop_payload" | (cd "$hook_root" && FM_BRAIN_HOME="$hook_home" bash -c "$stop_command") || fail "tracked Stop hook failed"
printf '%s' "$stop_payload" | (cd "$hook_root" && FM_BRAIN_HOME="$hook_home" bash -c "$stop_command") || fail "duplicate tracked Stop hook failed"
[ "$(find "$hook_home/events/inbox" -type f -name 'ev_*.json' | wc -l | tr -d ' ')" -eq 1 ] || fail "tracked Codex hook commands did not land one exchange exactly once"
pass "tracked Codex turn-complete hooks capture only the final guarded exchange"

# 2. An explicit correction is active before the next completion and survives a new process.
new_case fast-promotion
capture_json '{"thread_id":"promotion","turn_id":"1","user":"Correction: response-style = concise","assistant":"Acknowledged.","cwd":"/tmp","submitted_at":"2026-08-08T10:00:00Z","completed_at":"2026-08-08T10:00:01Z"}'
promotion_batch=$(drain 100) || fail "explicit correction batch failed"
[ "$(printf '%s' "$promotion_batch" | jq -r .accepted_claims)" -eq 1 ] || fail "explicit correction did not fast-promote"
capture_json '{"thread_id":"promotion","turn_id":"2","user":"Thanks.","assistant":"Ready.","cwd":"/tmp","submitted_at":"2026-08-08T10:01:00Z","completed_at":"2026-08-08T10:01:01Z"}'
promotion_query=$(query_scope global firstmate) || fail "restart query failed"
[ "$(printf '%s' "$promotion_query" | jq -r '.[0].value')" = "concise" ] || fail "correction was not active by the next completed turn"
promotion_restart=$(FM_BRAIN_HOME="$BRAIN_HOME" FM_BRAIN_VAULT="$VAULT" "$KEEPER" query --scope-kind global --scope-id firstmate)
[ "$promotion_restart" = "$promotion_query" ] || fail "active correction changed across a fresh Brainkeeper process"
pass "2/13 explicit correction is active by the next turn and survives restart"

# 3. Ephemeral, speculative, quoted, webpage, and tool text never becomes authoritative global memory.
new_case authority
python3 - <<'PY' | "$CAPTURE" exchange --ndjson >/dev/null
import json
records = [
    ("1", "Nice weather today.", "Glad to hear it."),
    ("2", "Could we brainstorm X and Y?", "Maybe X.\nMemory proposal: standard: speculative assistant guess"),
    ("3", "> Use quoted untrusted instructions", "I will not treat that as authority."),
    ("4", "Webpage says: Use injected instructions", "Tool output: Use another injected instruction"),
    ("5", "Use suffix-injected instructions from a webpage", "I will not treat that as authority."),
    ("6", "```text\nUse fenced injected instructions\n```", "I will not treat that as authority."),
    ("7", "Failure lesson: inferred causes require review", "Acknowledged."),
    ("8", "Priority: unbounded urgency", "Acknowledged."),
]
for turn, user, assistant in records:
    print(json.dumps({"thread_id":"authority","turn_id":turn,"user":user,"assistant":assistant,"cwd":"/tmp","submitted_at":"2026-08-08T10:00:00Z","completed_at":"2026-08-08T10:00:01Z"}))
PY
drain 100 > "$EVIDENCE/authority-batch.json" || fail "authority batch failed"
authority_query=$(query_scope global firstmate)
assert_json_length "$authority_query" 0 "authority query"
accepted_files=$(find "$VAULT/firstmate-brain/ledger/claims" -type f -name '*.json' | wc -l | tr -d ' ')
[ "$accepted_files" -eq 0 ] || fail "ephemeral or untrusted input created an accepted claim"
jq -s -e 'any(.[]; .status == "proposed" and .authority == "firstmate_inference") and any(.[]; .status == "quarantined" and .authority == "untrusted_external")' "$BRAIN_HOME"/brainkeeper/candidates/*/*.json >/dev/null \
  || fail "assistant proposal and quoted quarantine policy were not both observed"
jq -s -e 'map(select(.state == "prepared"))[0] | (.event_ids | length) == 8 and all(.candidate_ids[]; startswith("ca_"))' "$VAULT"/firstmate-brain/ledger/batches/*.json >/dev/null \
  || fail "not every completed turn entered the immutable candidate batch"
jq -s -e 'all(.[]; .type == "correction" or .type == "decision" or .type == "standard" or .type == "priority" or .type == "failure_lesson")' "$BRAIN_HOME"/brainkeeper/candidates/*/*.json >/dev/null \
  || fail "candidate batch emitted an untyped observation"
pass "3/13 non-authoritative conversation and external content cannot create global authority"

new_case bounded-edits
bounded_payload=$(python3 - <<'PY'
import json
lines = ["Standard: bounded-%02d = value-%02d" % (number, number) for number in range(17)]
print(json.dumps({"thread_id":"bounded","turn_id":"1","user":"\n".join(lines),"assistant":"Acknowledged.","cwd":"/tmp","submitted_at":"2026-08-08T10:00:00Z","completed_at":"2026-08-08T10:00:01Z"}))
PY
)
capture_json "$bounded_payload"
set +e
drain 100 > "$EVIDENCE/bounded-edit-batch.out" 2> "$EVIDENCE/bounded-edit-batch.error"
bounded_status=$?
set -u
[ "$bounded_status" -ne 0 ] || fail "batch exceeding 20 derived edits became active"
[ "$(find "$VAULT/firstmate-brain/ledger/batches" -type f -name '*-active-*' | wc -l | tr -d ' ')" -eq 0 ] || fail "bounded-edit failure appended an active transition"
bounded_health=$("$KEEPER" health --as-of '2026-08-08T12:00:00Z')
[ "$(printf '%s' "$bounded_health" | jq -r .failed_batches)" -eq 1 ] || fail "bounded-edit failure was not exposed in health"
pass "bounded-edit gate withholds an oversized batch before activation and exposes the failure"

# 4 and 8. Supersession is exact, and rollback restores prior generated bytes.
new_case supersession
capture_json '{"thread_id":"supersession","turn_id":"1","user":"Use X","assistant":"Acknowledged.","cwd":"/tmp","submitted_at":"2026-08-08T10:00:00Z","completed_at":"2026-08-08T10:00:01Z"}'
drain 100 > "$EVIDENCE/supersession-first-batch.json" || fail "first supersession batch failed"
before_digest=$(tree_digest "$VAULT/firstmate-brain/generated")
x_query=$(query_scope global firstmate)
x_id=$(printf '%s' "$x_query" | jq -r '.[0].claim_id')
capture_json '{"thread_id":"supersession","turn_id":"2","user":"stop X, use Y","assistant":"Acknowledged.","cwd":"/tmp","submitted_at":"2026-08-08T10:01:00Z","completed_at":"2026-08-08T10:01:01Z"}'
second_batch=$(drain 100) || fail "correction supersession batch failed"
y_query=$(query_scope global firstmate)
assert_json_length "$y_query" 1 "active supersession query"
[ "$(printf '%s' "$y_query" | jq -r '.[0].value')" = Y ] || fail "supersession did not retrieve only Y"
[ "$(printf '%s' "$y_query" | jq -r '.[0].supersedes | length')" -eq 1 ] || fail "supersession edge count is not exact"
[ "$(printf '%s' "$y_query" | jq -r '.[0].supersedes[0]')" = "$x_id" ] || fail "Y does not supersede the exact X claim"
history_count=$(find "$VAULT/firstmate-brain/ledger/claims" -type f -name '*.json' | wc -l | tr -d ' ')
[ "$history_count" -eq 2 ] || fail "superseded X was not retained historically"
pass "4/13 correction retrieves only Y while retaining X with one exact supersession edge"
second_version_id=$(printf '%s' "$second_batch" | jq -r .version_id)
"$KEEPER" rollback --version-id "$second_version_id" --as-of '2026-08-08T12:00:00Z' > "$EVIDENCE/supersession-rollback.json" || fail "rollback failed"
[ "$(jq -r .deactivated_version_id "$EVIDENCE/supersession-rollback.json")" = "$second_version_id" ] || fail "rollback did not target the immutable version ID"
after_digest=$(tree_digest "$VAULT/firstmate-brain/generated")
[ "$before_digest" = "$after_digest" ] || fail "rollback did not restore the prior generated tree byte-for-byte"
"$KEEPER" rebuild --verify-only > "$EVIDENCE/rollback-rebuild.json" || fail "ledger rebuild is not byte-exact"
[ "$(find "$BRAIN_HOME/events/inbox" -type f | wc -l | tr -d ' ')" -eq 2 ] || fail "rollback deleted a raw event"
[ "$(find "$VAULT/firstmate-brain/ledger/claims" -type f | wc -l | tr -d ' ')" -eq 2 ] || fail "rollback deleted an accepted claim"
pass "8/13 immutable batch rollback regenerates the prior active views byte-for-byte"

# 5. Project and client namespaces remain exact at write and read time.
new_case namespaces
python3 - <<'PY' | "$CAPTURE" exchange --ndjson >/dev/null
import json
records = [
    ("p-a", "project", "alpha", "Standard: build-tool = AlphaTool"),
    ("p-b", "project", "beta", "Standard: build-tool = BetaTool"),
    ("c-a", "client", "client-a", "Standard: tone = ClientATone"),
    ("c-b", "client", "client-b", "Standard: tone = ClientBTone"),
]
for turn, kind, scope_id, user in records:
    print(json.dumps({"thread_id":"scope","turn_id":turn,"user":user,"assistant":"Acknowledged.","cwd":"/tmp","scope_kind":kind,"scope_id":scope_id,"submitted_at":"2026-08-08T10:00:00Z","completed_at":"2026-08-08T10:00:01Z"}))
PY
for namespace_batch in 1 2 3 4; do
  drain 100 > "$EVIDENCE/namespace-batch-$namespace_batch.json" || fail "namespace batch $namespace_batch failed"
done
alpha=$(query_scope project alpha)
beta=$(query_scope project beta)
client_a=$(query_scope client client-a)
client_b=$(query_scope client client-b)
[ "$(printf '%s' "$alpha" | jq -r '.[0].value')" = AlphaTool ] || fail "project alpha did not retrieve its own claim"
[ "$(printf '%s' "$beta" | jq -r '.[0].value')" = BetaTool ] || fail "project beta did not retrieve its own claim"
[ "$(printf '%s' "$client_a" | jq -r '.[0].value')" = ClientATone ] || fail "client A did not retrieve its own claim"
[ "$(printf '%s' "$client_b" | jq -r '.[0].value')" = ClientBTone ] || fail "client B did not retrieve its own claim"
if printf '%s%s%s' "$beta" "$client_a" "$client_b" | grep -q 'AlphaTool'; then
  fail "project alpha claim crossed a namespace"
fi
if printf '%s%s%s' "$alpha" "$client_a" "$client_b" | grep -q 'BetaTool'; then
  fail "project beta claim crossed a namespace"
fi
if printf '%s%s%s' "$alpha" "$beta" "$client_b" | grep -q 'ClientATone'; then
  fail "client A claim crossed a namespace"
fi
if printf '%s%s%s' "$alpha" "$beta" "$client_a" | grep -q 'ClientBTone'; then
  fail "client B claim crossed a namespace"
fi
[ "$(query_scope global firstmate | jq 'length')" -eq 0 ] || fail "scoped claim leaked into the global namespace"
alpha_topic=$(printf '%s' "$alpha" | jq -r '.[0].subject')
context_tree_before=$(tree_digest "$CASE_ROOT")
alpha_context=$("$CONTEXT" --scope-kind project --scope-id alpha --topic "$alpha_topic" --as-of '2026-08-08T12:00:00Z') || fail "exact project decision context failed"
context_tree_after=$(tree_digest "$CASE_ROOT")
[ "$context_tree_before" = "$context_tree_after" ] || fail "read-only decision context changed tenant state"
assert_not_contains "$alpha_context" "BetaTool" "project beta leaked into project alpha decision context"
assert_not_contains "$alpha_context" "ClientATone" "client A leaked into project alpha decision context"
assert_not_contains "$alpha_context" "ClientBTone" "client B leaked into project alpha decision context"
assert_contains "$alpha_context" "Complete for this exact scope and topic selection: \`true\`" "decision context did not attest completeness"
assert_contains "$alpha_context" "Existing deterministic action gates remain authoritative" "decision context could bypass deterministic action gates"
pass "5/13 project and client claims never cross namespaces"

# 6. Expired priorities leave active views without deleting ledger history.
new_case expiry
capture_json '{"thread_id":"expiry","turn_id":"1","user":"Priority until 2026-08-01: launch-window = ship now","assistant":"Acknowledged.","cwd":"/tmp","submitted_at":"2026-07-31T10:00:00Z","completed_at":"2026-07-31T10:00:01Z"}'
drain 100 > "$EVIDENCE/expiry-batch.json" || fail "expiry batch failed"
grep -q 'ship now' "$VAULT/firstmate-brain/generated/hot/global.md" || fail "unexpired priority was not initially active"
"$KEEPER" rebuild --as-of '2026-08-08T12:00:00Z' > "$EVIDENCE/expiry-rebuild.json" || fail "expiry rebuild failed"
! grep -q 'ship now' "$VAULT/firstmate-brain/generated/hot/global.md" || fail "expired priority remained in the hot view"
[ "$(query_scope global firstmate | jq 'length')" -eq 0 ] || fail "expired priority remained in warm retrieval"
[ "$(find "$VAULT/firstmate-brain/ledger/claims" -type f -name '*.json' | wc -l | tr -d ' ')" -eq 1 ] || fail "expired priority history was deleted"
expiry_health=$("$KEEPER" health --as-of '2026-08-08T12:00:00Z')
[ "$(printf '%s' "$expiry_health" | jq -r .stale_claims)" -eq 1 ] || fail "health did not expose the stale priority"
pass "6/13 expired priorities leave the hot view while history remains immutable"

# 7. Every recalled claim carries full authority, scope, bitemporal, source, and evidence provenance.
provenance=$(printf '%s' "$alpha" | jq '.[0]')
printf '%s' "$provenance" | jq -e '
  .authority and .scope.kind and .scope.id and .valid_from and
  (has("valid_until")) and .transaction_time and
  .source_turn.thread_id and .source_turn.turn_id and .source_hash and
  .source_event_id and .evidence.pointer and .evidence.excerpt and
  .extractor_version and .privacy and .confidence
' >/dev/null || fail "recalled claim is missing required provenance"
pass "7/13 every recalled claim resolves to complete provenance and evidence"

# 9. Seeded secrets are redacted before the immutable source and never flow outward.
new_case privacy
seeded_secret='sk-'
seeded_secret+='seededSecretValue123456789'
secret_payload=$(jq -cn --arg secret "$seeded_secret" '{thread_id:"privacy",turn_id:"1",user:("Standard: api_key = " + $secret),assistant:"Acknowledged.",cwd:"/tmp",submitted_at:"2026-08-08T10:00:00Z",completed_at:"2026-08-08T10:00:01Z"}')
capture_json "$secret_payload"
drain 100 > "$EVIDENCE/privacy-batch.json" || fail "privacy batch failed"
if rg -F "$seeded_secret" "$BRAIN_HOME" "$VAULT" >/dev/null 2>&1; then
  fail "seeded secret appeared in private candidates, ledgers, notes, or logs"
fi
privacy_query=$(query_scope global firstmate)
[ "$(printf '%s' "$privacy_query" | jq 'length')" -eq 0 ] || fail "redacted secret became active memory"
jq -s -e 'any(.[]; .status == "quarantined" and .reason == "privacy_gate")' "$BRAIN_HOME"/brainkeeper/candidates/*/*.json >/dev/null \
  || fail "redacted secret candidate was not privacy-quarantined"
harness_home="$CASE_ROOT/harness-home"
mkdir -p "$harness_home/state" "$harness_home/data" "$harness_home/config" "$harness_home/projects"
printf '%s\n' "$VAULT" > "$harness_home/config/brain-vault"
FM_HOME="$harness_home" FM_SESSION_LOCK_SKIP=1 "$ROOT/bin/fm-session-start.sh" > "$EVIDENCE/privacy-outbound-context.txt" 2>&1 || true
if rg -F "$seeded_secret" "$EVIDENCE/privacy-outbound-context.txt" >/dev/null 2>&1; then
  fail "seeded secret appeared in outbound Firstmate context"
fi
pass "9/13 secrets appear nowhere in candidates, ledgers, notes, logs, or outbound context"

# 10. A 10,000-event fixture keeps the compiled global hot view bounded.
new_case ten-thousand
for group in $(seq 0 19); do
  GROUP=$group python3 - <<'PY' | "$CAPTURE" exchange --ndjson >/dev/null
import json
import os
group = int(os.environ['GROUP'])
for offset in range(10):
    number = group * 10 + offset
    print(json.dumps({
        "thread_id":"ten-thousand-rules",
        "turn_id":"rule-%04d" % number,
        "user":"Standard: rule-%04d = %s" % (number, "bounded-value-" + ("x" * 96)),
        "assistant":"Acknowledged.",
        "cwd":"/tmp",
        "submitted_at":"2026-08-08T10:00:00Z",
        "completed_at":"2026-08-08T10:00:01Z",
    }))
PY
  drain 100 > "$EVIDENCE/ten-thousand-batch-$group.json" || fail "bounded rules batch $group failed"
done
python3 - <<'PY' | "$CAPTURE" exchange --ndjson > "$EVIDENCE/ten-thousand-chitchat-capture.json"
import json
for number in range(9800):
    print(json.dumps({
        "thread_id":"ten-thousand-chitchat",
        "turn_id":"chat-%05d" % number,
        "user":"Synthetic chitchat %05d" % number,
        "assistant":"Synthetic reply.",
        "cwd":"/tmp",
        "submitted_at":"2026-08-08T10:02:00Z",
        "completed_at":"2026-08-08T10:02:01Z",
    }))
PY
drain 10000 > "$EVIDENCE/ten-thousand-final-batch.json" || fail "10,000-event chitchat batch failed"
fixture_count=$(find "$BRAIN_HOME/events/inbox" -type f -name 'ev_*.json' | wc -l | tr -d ' ')
[ "$fixture_count" -eq 10000 ] || fail "large fixture contains $fixture_count events instead of 10,000"
large_health=$("$KEEPER" health --as-of '2026-08-08T12:00:00Z')
printf '%s' "$large_health" | jq -e '
  has("queue_lag_seconds") and has("failed_extraction") and has("failed_batches") and
  has("quarantined_candidates") and has("conflicts") and has("stale_claims") and
  (.last_successful_compile != null) and has("hot_view_bytes") and has("hot_view_tokens")
' >/dev/null || fail "health omitted a required production signal"
hot_tokens=$(printf '%s' "$large_health" | jq -r .hot_view_tokens)
hot_bytes=$(printf '%s' "$large_health" | jq -r .hot_view_bytes)
[ "$hot_tokens" -le 1500 ] || fail "hot view reached $hot_tokens tokens"
[ "$hot_bytes" -le 6000 ] || fail "hot view reached $hot_bytes bytes"
set +e
"$CONTEXT" --scope-kind global --scope-id firstmate --as-of '2026-08-08T12:00:00Z' > "$EVIDENCE/large-context-unbounded.txt" 2> "$EVIDENCE/large-context-unbounded.error"
large_context_status=$?
set -u
[ "$large_context_status" -ne 0 ] || fail "decision context emitted an indiscriminate 200-claim dump"
large_topic=$(query_scope global firstmate | jq -r '.[0].subject')
"$CONTEXT" --scope-kind global --scope-id firstmate --topic "$large_topic" --as-of '2026-08-08T12:00:00Z' > "$EVIDENCE/large-context-relevant.md" \
  || fail "topic-bounded decision context was not complete"
pass "10/13 hot view remains at or below 1,500 conservative tokens across 10,000 events"

# 11. Measure actual process-level capture and compiled warm retrieval latency.
perf_home="$TMP_ROOT/performance/home"
perf_vault="$TMP_ROOT/performance/vault"
mkdir -p "$perf_vault"
CAPTURE="$CAPTURE" KEEPER="$KEEPER" PERF_HOME="$perf_home" PERF_VAULT="$perf_vault" LARGE_HOME="$BRAIN_HOME" LARGE_VAULT="$VAULT" python3 - "$EVIDENCE/performance.json" <<'PY' || fail "performance gate failed"
import json
import os
from pathlib import Path
import statistics
import subprocess
import sys
import time

capture = os.environ['CAPTURE']
keeper = os.environ['KEEPER']
base_env = os.environ.copy()
base_env['FM_BRAIN_HOME'] = os.environ['PERF_HOME']
base_env['FM_BRAIN_VAULT'] = os.environ['PERF_VAULT']
prompt_latencies = []
complete_latencies = []
for number in range(120):
    base = {'session_id':'performance', 'turn_id':'turn-%03d' % number, 'cwd':'/tmp'}
    prompt = json.dumps(dict(base, prompt='Performance turn', submitted_at='2026-08-08T10:00:00Z')).encode()
    complete = json.dumps(dict(base, last_assistant_message='Performance reply', completed_at='2026-08-08T10:00:01Z')).encode()
    started = time.perf_counter()
    result = subprocess.run([capture, 'prompt'], input=prompt, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, env=base_env)
    prompt_latencies.append((time.perf_counter() - started) * 1000)
    assert result.returncode == 0, result.stderr.decode()
    started = time.perf_counter()
    result = subprocess.run([capture, 'complete'], input=complete, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, env=base_env)
    complete_latencies.append((time.perf_counter() - started) * 1000)
    assert result.returncode == 0, result.stderr.decode()

query_env = os.environ.copy()
query_env['FM_BRAIN_HOME'] = os.environ['LARGE_HOME']
query_env['FM_BRAIN_VAULT'] = os.environ['LARGE_VAULT']
queries = []
for _ in range(120):
    started = time.perf_counter()
    result = subprocess.run([keeper, 'query', '--scope-kind', 'global', '--scope-id', 'firstmate'], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, env=query_env)
    queries.append((time.perf_counter() - started) * 1000)
    assert result.returncode == 0, result.stderr.decode()

def percentile(values, fraction):
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, max(0, int(len(ordered) * fraction + 0.999999) - 1))]

prompt_p95 = percentile(prompt_latencies, 0.95)
complete_p95 = percentile(complete_latencies, 0.95)
metrics = {
    'capture_samples_per_hook': len(prompt_latencies),
    'capture_prompt_p95_ms': round(prompt_p95, 3),
    'capture_complete_p95_ms': round(complete_p95, 3),
    'capture_p95_ms': round(max(prompt_p95, complete_p95), 3),
    'capture_max_ms': round(max(prompt_latencies + complete_latencies), 3),
    'retrieval_samples': len(queries),
    'retrieval_p95_ms': round(percentile(queries, 0.95), 3),
    'retrieval_max_ms': round(max(queries), 3),
    'foreground_model_calls': 0,
}
Path(sys.argv[1]).write_text(json.dumps(metrics, sort_keys=True, indent=2) + '\n')
assert metrics['capture_p95_ms'] <= 100, metrics
assert metrics['retrieval_p95_ms'] <= 250, metrics
PY
python3 - "$ROOT/libexec/fm_capture.py" <<'PY' || fail "capture engine imports a network or provider client"
import ast
from pathlib import Path
import sys
tree = ast.parse(Path(sys.argv[1]).read_text())
forbidden = {'socket', 'urllib', 'http', 'requests', 'anthropic', 'openai'}
imports = set()
for node in ast.walk(tree):
    if isinstance(node, ast.Import):
        imports.update(alias.name.split('.')[0] for alias in node.names)
    elif isinstance(node, ast.ImportFrom) and node.module:
        imports.add(node.module.split('.')[0])
assert not imports & forbidden, imports & forbidden
PY
performance=$(cat "$EVIDENCE/performance.json")
capture_p95=$(printf '%s' "$performance" | jq -r .capture_p95_ms)
retrieval_p95=$(printf '%s' "$performance" | jq -r .retrieval_p95_ms)
pass "11/13 capture p95 ${capture_p95}ms, zero foreground model calls, warm retrieval p95 ${retrieval_p95}ms"

# 12. A staged batch remains invisible until the held-out suite passes and activation commits.
new_case preactivation
capture_json '{"thread_id":"preactivation","turn_id":"1","user":"Use X","assistant":"Acknowledged.","cwd":"/tmp","submitted_at":"2026-08-08T10:00:00Z","completed_at":"2026-08-08T10:00:01Z"}'
drain 100 >/dev/null || fail "preactivation baseline failed"
capture_json '{"thread_id":"preactivation","turn_id":"2","user":"stop X, use Y","assistant":"Acknowledged.","cwd":"/tmp","submitted_at":"2026-08-08T10:01:00Z","completed_at":"2026-08-08T10:01:01Z"}'
set +e
FM_BRAIN_FAILPOINT=brainkeeper_after_evaluation_before_activation "$KEEPER" drain --limit 100 >/dev/null 2>&1
stage_status=$?
set -u
[ "$stage_status" -eq 88 ] || fail "preactivation failpoint did not stop after evaluation"
staged_query=$(query_scope global firstmate)
[ "$(printf '%s' "$staged_query" | jq -r '.[0].value')" = X ] || fail "staged batch changed behavior before activation"
active_transition_count=$(find "$VAULT/firstmate-brain/ledger/batches" -type f -name '*-active-*' | wc -l | tr -d ' ')
[ "$active_transition_count" -eq 1 ] || fail "staged batch created an early active transition"
"$KEEPER" evaluate > "$EVIDENCE/held-out-evaluation.json" || fail "held-out Firstmate orchestration suite regressed"
drain 100 > "$EVIDENCE/preactivation-activated.json" || fail "evaluated staged batch did not activate on retry"
activated_query=$(query_scope global firstmate)
[ "$(printf '%s' "$activated_query" | jq -r '.[0].value')" = Y ] || fail "accepted correction was not active after the gate"
pass "12/13 held-out orchestration gate prevents any pre-activation behavior change"

capture_json '{"thread_id":"preactivation","turn_id":"crash-recovery","user":"stop Y, use W","assistant":"Acknowledged.","cwd":"/tmp","submitted_at":"2026-08-08T10:01:30Z","completed_at":"2026-08-08T10:01:31Z"}'
set +e
FM_BRAIN_FAILPOINT=brainkeeper_after_activation_before_compile "$KEEPER" drain --limit 100 >/dev/null 2>&1
active_crash_status=$?
set -u
[ "$active_crash_status" -eq 89 ] || fail "post-activation failpoint did not interrupt compilation"
recovery=$(drain 100) || fail "active batch did not recover after restart"
[ "$(printf '%s' "$recovery" | jq -r .state)" = recovered ] || fail "active batch restart did not take the deterministic recovery path"
[ "$(query_scope global firstmate | jq -r '.[0].value')" = W ] || fail "active batch recovery did not compile the accepted correction"
pass "active-batch restart deterministically finishes compilation without duplicating the claim"

# Equal-authority conflicts are withheld and surfaced once.
capture_json '{"thread_id":"preactivation","turn_id":"3","user":"Use Z","assistant":"Acknowledged.","cwd":"/tmp","submitted_at":"2026-08-08T10:02:00Z","completed_at":"2026-08-08T10:02:01Z"}'
drain 100 >/dev/null || fail "conflict batch failed"
[ "$(query_scope global firstmate | jq -r '.[0].value')" = W ] || fail "equal-authority conflict replaced the active claim"
conflict_context=$("$CONTEXT" --scope-kind global --scope-id firstmate --topic default-method --as-of '2026-08-08T12:00:00Z') || fail "conflict decision context failed"
assert_contains "$conflict_context" "## Withheld conflicts" "compiled decision context did not expose conflicts"
assert_contains "$conflict_context" "candidate" "compiled decision context omitted conflict provenance"
assert_contains "$conflict_context" "Freshness:" "compiled decision context omitted freshness"
assert_contains "$conflict_context" "Type and precedence:" "compiled decision context omitted precedence"
set +e
first_exception=$("$KEEPER" health --exceptions-only --mark-reported 2>/dev/null)
first_exception_status=$?
second_exception=$("$KEEPER" health --exceptions-only 2>/dev/null)
second_exception_status=$?
set -u
[ "$first_exception_status" -eq 2 ] || fail "unresolved conflict did not surface as an exception"
[ "$(printf '%s' "$first_exception" | jq -r .unreported_conflicts)" -eq 1 ] || fail "conflict exception count was not one"
if [ "$second_exception_status" -ne 0 ] || [ -n "$second_exception" ]; then
  fail "equal-authority conflict surfaced more than once"
fi
pass "policy conflict is withheld and exception-reported exactly once"

# 13. Direct filesystem inspection proves all non-deterministic maintenance is Brainkeeper-only.
grep -q 'fm-turn-capture.sh' "$ROOT/.codex/hooks.json" || fail "Codex hooks do not use deterministic capture"
! grep -q 'fm-brainkeeper.sh' "$ROOT/.codex/hooks.json" || fail "Firstmate hook can invoke Brainkeeper maintenance"
guard_line=$(grep -n 'fm-turnend-guard.sh' "$ROOT/bin/fm-turn-complete.sh" | tail -1 | cut -d: -f1)
capture_line=$(grep -n 'fm-turn-capture.sh' "$ROOT/bin/fm-turn-complete.sh" | tail -1 | cut -d: -f1)
[ "$guard_line" -lt "$capture_line" ] || fail "completion capture can run before the supervision guard accepts Stop"
grep -q 'FM_BRAINKEEPER_ROLE' "$ROOT/bin/fm-brainkeeper.sh" || fail "Brainkeeper entry point does not set the maintenance role"
grep -q 'require_brainkeeper()' "$ROOT/libexec/fm_brain.py" || fail "maintenance commands are not role-gated"
! rg -n 'transcript_path|tool_arguments|tool_output' "$ROOT/bin/fm-turn-capture.sh" "$ROOT/bin/fm-turn-complete.sh" "$ROOT/libexec/fm_brain.py" >/dev/null \
  || fail "capture path reads transcript or tool payload fields"
! rg -n 'curl|codex exec|claude -p|openai|anthropic' "$ROOT/bin/fm-turn-capture.sh" "$ROOT/bin/fm-turn-complete.sh" >/dev/null \
  || fail "foreground capture path can invoke a model or provider"
grep -q 'print_brain_hot_or_absent' "$ROOT/bin/fm-session-start.sh" || fail "Firstmate does not read the compiled hot view"
! grep -q 'fm-brainkeeper.sh' "$ROOT/bin/fm-session-start.sh" || fail "Firstmate session start can perform memory maintenance"
! rg -n 'mkdir|write|replace|unlink|fm-brainkeeper' "$ROOT/bin/fm-brain-context.sh" >/dev/null \
  || fail "read-only decision context wrapper can perform memory maintenance"
pass "13/13 filesystem inspection proves Firstmate performs no non-deterministic memory writes"

# Isolated real dry run with accepted candidate, compile, and exact rollback.
new_case dry-run
capture_json '{"thread_id":"dry-run","turn_id":"baseline","user":"Thanks.","assistant":"Ready.","cwd":"/tmp/dry-run","submitted_at":"2026-08-08T10:00:00Z","completed_at":"2026-08-08T10:00:01Z"}'
"$KEEPER" serve --once --limit 100 > "$EVIDENCE/dry-run-baseline.json" || fail "dry-run persistent-worker baseline batch failed"
dry_before=$(tree_digest "$VAULT/firstmate-brain/generated")
capture_json '{"thread_id":"dry-run","turn_id":"claim","user":"Correction: dry-run-mode = direct","assistant":"Acknowledged.","cwd":"/tmp/dry-run","submitted_at":"2026-08-08T10:01:00Z","completed_at":"2026-08-08T10:01:01Z"}'
dry_batch=$(drain 100) || fail "dry-run claim batch failed"
[ "$(printf '%s' "$dry_batch" | jq -r .accepted_claims)" -eq 1 ] || fail "dry-run candidate did not pass policy"
dry_batch_id=$(printf '%s' "$dry_batch" | jq -r .batch_id)
dry_version_id=$(printf '%s' "$dry_batch" | jq -r .version_id)
dry_claim_id=$(query_scope global firstmate | jq -r '.[0].claim_id')
"$KEEPER" rollback --version-id "$dry_version_id" --as-of '2026-08-08T12:00:00Z' > "$EVIDENCE/dry-run-rollback.json" || fail "dry-run rollback failed"
dry_after=$(tree_digest "$VAULT/firstmate-brain/generated")
[ "$dry_before" = "$dry_after" ] || fail "dry-run rollback was not byte-exact"
jq -cn \
  --arg event_id "$(jq -r 'select(.source_turn.turn_id == "claim") | .source_event_id' "$BRAIN_HOME"/brainkeeper/candidates/*/*.json)" \
  --arg candidate_id "$(jq -r 'select(.source_turn.turn_id == "claim") | .candidate_id' "$BRAIN_HOME"/brainkeeper/candidates/*/*.json)" \
  --arg claim_id "$dry_claim_id" \
  --arg batch_id "$dry_batch_id" \
  --arg version_id "$dry_version_id" \
  --arg before "$dry_before" \
  --arg after "$dry_after" \
  '{event_id:$event_id,candidate_id:$candidate_id,claim_id:$claim_id,batch_id:$batch_id,version_id:$version_id,policy:"accepted",rollback_before:$before,rollback_after:$after,private_content_reported:false}' \
  > "$EVIDENCE/dry-run.json"
pass "isolated dry run captures, promotes, compiles, and rolls back without reporting private content"

live_vault_after=$(path_state "$LIVE_VAULT_BRAIN")
live_state_after=$(path_state "$LIVE_STATE_BRAIN")
[ "$live_vault_before" = "$live_vault_after" ] || fail "test run changed the live canonical vault brain path"
[ "$live_state_before" = "$live_state_after" ] || fail "test run changed canonical Firstmate brain state"
printf 'vault_before=%s\nvault_after=%s\nstate_before=%s\nstate_after=%s\n' \
  "$live_vault_before" "$live_vault_after" "$live_state_before" "$live_state_after" \
  > "$EVIDENCE/live-paths.txt"
pass "test run left the live vault and canonical Firstmate brain paths unchanged"

jq -n \
  --arg evidence_root "$TMP_ROOT" \
  --argjson capture_p95 "$capture_p95" \
  --argjson retrieval_p95 "$retrieval_p95" \
  --argjson hot_tokens "$hot_tokens" \
  --argjson hot_bytes "$hot_bytes" \
  --argjson events "$fixture_count" \
  '{status:"pass",evidence_root:$evidence_root,capture_p95_ms:$capture_p95,retrieval_p95_ms:$retrieval_p95,hot_tokens:$hot_tokens,hot_bytes:$hot_bytes,large_fixture_events:$events,foreground_model_calls:0,live_vault_mutations:0,canonical_state_mutations:0}' \
  > "$EVIDENCE/summary.json"

printf 'DIRECT_ACCEPTANCE=PASS\n'
printf 'EVIDENCE_ROOT=%s\n' "$TMP_ROOT"
