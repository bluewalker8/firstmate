# Harness and runtime routing

Load when: selecting, spawning, steering, interrupting, resuming, or diagnosing a harness or runtime backend.

Fresh sources: `config/crew-dispatch.json` when present, `bin/fm-harness.sh`, `bin/fm-dispatch-select.sh`, `bin/fm-spawn.sh`, `bin/fm-backend.sh`, `bin/backends/`, and `.agents/skills/harness-adapters/SKILL.md`.

## Selection

An explicit active per-task harness choice wins.
Otherwise evaluate every current dispatch-profile rule and choose the best fit by its stated condition and rationale.
If a selected quota-balanced rule applies, use `bin/fm-dispatch-select.sh` with the current rule object.
If no rule applies, use its current default or resolve the static crew harness with `bin/fm-harness.sh`.

Never dispatch on an unverified adapter.
When a profile names an unsupported adapter, use the next valid source and surface the issue only when it affects delivery.
Quota lookup failure must not block a dispatch that has a valid fallback.

Load `.agents/skills/harness-adapters/SKILL.md` immediately before a spawn, recovery, trust dialog, harness-specific invocation, interrupt, exit, resume, or adapter verification.
Pass the resolved profile explicitly when current dispatch configuration requires it.

## Runtime backend

Use the backend resolved by current configuration and runtime detection.
Do not memorize the supported set from prose.
Inspect `bin/fm-backend.sh`, `bin/fm-spawn.sh` `--help`, and the selected adapter under `bin/backends/` before backend-specific action.

A backend refusal is evidence of a blocker.
Do not silently retry on another backend because that changes the execution contract and can strand state.
Load the dedicated Orca or Codex App skill when root's trigger applies.

## Control and recovery

Use `bin/fm-send.sh` for resolved home-scoped steering and keep messages short.
Use `bin/fm-peek.sh` only for targeted diagnosis after cheaper state evidence is insufficient.
Use the harness skill's current interrupt, exit, and resume procedures rather than generic keystrokes.
Never target endpoints by a guessed label when task metadata can resolve them.
