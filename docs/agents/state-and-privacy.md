# State, backlog, and privacy

Load when: reading or mutating fleet state, project registry, secondmate registry, backlog, memory, configuration, or captain-private data.

Fresh sources: the current `bin/fm-session-start.sh` digest, `.tasks.toml`, `bin/fm-tasks-axi-lib.sh`, `bin/fm-project-mode.sh`, local configuration, and the specific file immediately before mutation.

## Ownership

Tracked repository material is shared product source.
Captain-specific fleet material is local and untracked.
Never commit `.env`, `data/`, `state/`, `config/`, `projects/`, or local validation state.
Never expose secrets or captain-private content in briefs, PRs, public reports, X replies, or logs.

`FM_HOME` selects the operational home used by current scripts.
Secondmates use separate homes.
Use current script output to resolve the active home rather than assuming the checkout root.

Treat `state/*.status` as append-only wake-event history.
Treat the current task endpoint, `bin/fm-crew-state.sh`, recorded metadata, and external service state as fresher evidence for current state.
Do not bulk-read state when the session-start digest already provided the needed snapshot.

## Project and memory placement

The project registry is a thin navigation and delivery-mode index.
The secondmate registry is a routing table, not project ownership.
Project-intrinsic build, architecture, release, and sharp-edge knowledge belongs in that project's tracked `AGENTS.md` through normal project delivery.
Captain preferences, fleet state, and product strategy remain in local Firstmate data.
Investigation findings live in the scout report named by its brief.

Prefer pointers to current source over copied mechanisms.
Inspect a memory or note before updating it.
Rewrite or prune stale content instead of appending contradictory history.
Verify volatile details against current configuration, code, or external state before acting.

## Backlog

The backlog tracks work, not persistent secondmate identities.
The active home owns its own backlog.
Update it on dispatch, completion, dependency change, and captain decision.
Keep blocked relationships explicit and re-evaluate them after completion and teardown.

The selected backlog mechanism comes from current configuration and `.tasks.toml`.
When the configured tasks tool is available and compatible, use its current `--help` rather than copied syntax.
When the active backend is manual, inspect the current backlog before editing and preserve its existing structure.

For task-note replacement, inspect first with `tasks-axi show <id> --full`.
Replace the considered body with `tasks-axi update <id> --body-file <path>`.
Add `--archive-body` only when superseded prior state should remain recoverable.
Use `bin/fm-backlog-handoff.sh` for secondmate transfers rather than a bare move command.

Completed ship work records its full PR URL or local merge result.
Completed scout work records its report path.
Follow the retention configured by the current backend instead of hard-coding a count in root instructions.
