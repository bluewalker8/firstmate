# Obsidian turn brain

This is the smallest production v1 for turn-by-turn Firstmate memory.
It captures completed Codex primary turns with no model call, processes them asynchronously through one persistent Brainkeeper secondmate, and compiles bounded Obsidian views from immutable ledgers.

## Trust boundary

Firstmate has two memory capabilities.
It may deterministically capture a completed exchange through `bin/fm-turn-capture.sh`, read `firstmate-brain/generated/hot/global.md` during session start, and request a read-only exact-scope decision context through `bin/fm-brain-context.sh`.
It cannot run extraction, promotion, compilation, query, health mutation, or rollback because those operations require the role-gated `bin/fm-brainkeeper.sh` entry point.

The tracked Codex `UserPromptSubmit` hook stages the user prompt by stable `session_id` and `turn_id`.
The tracked Codex `Stop` hook invokes `bin/fm-turn-complete.sh`.
That wrapper first preserves the existing supervision guard outcome, then captures only after the guard accepts the final response.
Capture never reads the unstable transcript file.
It stores neither tool arguments nor tool output.

Capture writes under `${FM_BRAIN_HOME:-${FM_HOME}/data/brain}`.
Every directory is mode `0700` and every file is mode `0600`.
Completed source events are physically partitioned into hashed global, project, and client inbox directories before Brainkeeper sees them.
The final event ID is a stable digest of schema, thread, and turn.
The implementation writes a bounded, redacted event to a same-directory temporary file, fsyncs it, then creates the immutable inbox path with an atomic hard link.
A retry either creates the one final path or observes the same final path.
A crash before the link leaves no visible event.

## Brainkeeper pipeline

One persistent Brainkeeper secondmate runs `bin/fm-brainkeeper.sh serve` or repeated bounded `drain` calls.
No per-turn agent is created.
The project-less persistent charter template is [`docs/examples/brainkeeper-charter.md`](examples/brainkeeper-charter.md).
The v1 extractor is deliberately deterministic and local because this release is not authorized to call a provider.
The extractor emits only `correction`, `decision`, `standard`, `priority`, or `failure_lesson` candidates.
Every completed turn is appended to one immutable candidate batch, including turns whose typed candidate list is empty.
This preserves the full observation stream without pretending that chitchat is canonical truth.

Every candidate records its source event, source turn, content hash, speaker, exact scope, authority, validity interval, transaction time, confidence, privacy classification, extractor version, evidence pointer, and proposed supersession edges.
Candidate and claim records are physically separated into hashed global, project, and client namespace directories.
One Brainkeeper batch contains events from exactly one namespace, so its immutable batch record and review cannot mix tenants.
Explicit Blue corrections, decisions, standards, and time-bounded priorities may fast-promote only after all gates pass.
Failure lessons remain proposed in v1 because they need a reviewed promotion path.
Assistant inferences remain proposed.
External or quoted instructions are quarantined.
Redacted-secret candidates are quarantined.
Equal-authority conflicts are withheld and reported once.
Accepted corrections append a new claim with exact `supersedes` claim IDs.

The held-out orchestration fixture runs before a batch receives its immutable `active` transition.
Until that transition exists, staged claim records are invisible to query and compile.
Each batch writes a bounded hash-level review before activation.

## Vault layout

Brainkeeper requires an existing vault through `FM_BRAIN_VAULT`, `config/brain-vault`, or the existing canonical Claude project-memory vault discovered from the current home path.
It never creates a competing vault.
Tests always provide a disposable existing directory explicitly.

```text
firstmate-brain/
  schema/                   JSON schemas
  ledger/
    claims/                 immutable accepted claim records
    batches/                immutable prepared, evaluated, active, and deactivated records
  reviews/                  bounded per-batch review records
  generated/
    active-index.json       compiled warm retrieval index
    index.md                Obsidian topic catalog
    log.md                  deterministic active-batch log
    hot/global.md           global Firstmate rules, at most 1,500 conservative tokens
    topics/                 exact project, client, and global namespaces
  derived-archive/          recoverable displaced generated files
```

The immutable claims and batch transitions are the only compilation inputs.
Topic notes cite accepted claim IDs, source turns, source hashes, authority, scope, valid time, transaction time, and evidence pointers.
The compiler computes the complete desired view but writes only changed files and refuses a batch that would edit more than 20 generated files.
No whole-wiki rewrite occurs after a turn.

Project and client scopes get distinct hashed directory names.
Queries match one exact scope unless the caller deliberately issues another query.
Only the global namespace can enter the Firstmate hot view.
The hot compiler uses a conservative UTF-8 byte bound of four bytes per token and never exceeds 1,500 tokens.
The hot view and exact decision context expose authority, valid time, transaction time, source turn and hash, precedence edges, and unresolved conflict IDs.

`bin/fm-brain-context.sh` selects only active global and exact-tenant claims for the caller's requested topics.
It validates that the compiled index version matches the immutable active batch ledger and rechecks validity at read time.
It never returns a partial context when the exact selection exceeds its default 3,000-token bound.
The caller must narrow the requested topics instead of accepting an indiscriminate dump.
Memory context never grants action authority and cannot bypass Firstmate's deterministic execution and merge gates.

## Rollback and health

Rollback resolves one active batch by its immutable version ID and appends a `deactivated` transition.
It then regenerates the prior active `generated/` tree from ledger records.
It never deletes an event, candidate, claim, review, or earlier batch transition.
Unused derived files move to a recoverable archive outside the active generated tree.

Health includes queue depth and lag, extraction failures, quarantined candidates, unresolved conflicts, stale claims, delivery errors, orphaned partial files, last successful compile, and hot-view size.
It also reports batches withheld by the behavioral or bounded-edit gates.
`health --exceptions-only --mark-reported` is the Brainkeeper-to-Firstmate path and emits nothing while healthy.

## Research basis

Only late-2025 and 2026 evidence influenced this architecture.

- Karpathy's April 2026 [LLM Wiki pattern](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f) establishes immutable raw sources, generated Markdown, schema-governed ingest, query and lint, an index, a log, and Git-style history.
- OpenAI's February 2026 [Codex harness architecture](https://openai.com/index/unlocking-the-codex-harness/) treats threads and turns as durable lifecycle primitives and exposes stable typed events instead of requiring transcript scraping.
- The current official [Codex hooks reference](https://learn.chatgpt.com/docs/hooks) provides `session_id`, `turn_id`, `prompt`, and `last_assistant_message`, and warns that transcript format is not stable.
- TierMem's February 2026 [provenance-aware tiered memory](https://arxiv.org/abs/2602.17913) supports a cheap compiled index linked back to immutable source evidence.
- The June 2026 [systematic memory-poisoning study](https://arxiv.org/abs/2606.04329) shows that aggressive memory writes expand the attack surface, which motivates default no-candidate behavior and an explicit poisoning quarantine.
- The July 2026 [Ground Truth First evaluation instrument](https://arxiv.org/abs/2607.21962) motivates validity intervals, source-channel boundaries, and held-out behavioral gates.
- SQLite's April 2026 [WAL documentation](https://www.sqlite.org/wal.html) reports a multi-connection WAL reset corruption bug through 3.51.2.
This implementation therefore avoids a foreground database and uses fsynced immutable files plus a single Brainkeeper file lock.

These sources establish patterns and risks, not production proof for this exact implementation.
The direct acceptance suite supplies that implementation evidence.
