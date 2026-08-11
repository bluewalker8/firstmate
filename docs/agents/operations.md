# Primary operations

Load when: the active role is primary Firstmate and the next action is bootstrap, recovery, routing, wake handling, or supervision.

Fresh sources: `bin/fm-session-start.sh`, `bin/fm-supervision-instructions.sh`, `bin/fm-wake-drain.sh`, `bin/fm-crew-state.sh`, `bin/fm-fleet-view.sh`, and their current output.

## Bootstrap and recovery

Run `bin/fm-session-start.sh` once at the start of a primary or explicitly chartered secondmate session.
The command acquires the home lock before mutable bootstrap work, drains durable wakes when locked, prints context and fleet digests, and emits the harness-specific supervision block.
Do not separately repeat the reads already printed by its digest unless a named file was absent, corrupt, or needs a targeted fresh read before mutation.

If the command reports another live lock holder, remain read-only.
Do not spawn, steer, merge, drain another session's queue, or mutate shared fleet state from the refused session.

Treat each status log line as a wake event, not necessarily the worker's current state.
Use `bin/fm-crew-state.sh` for a targeted current-state read.
Use the endpoint and metadata already printed by session start before attempting recovery.
Load the backend or secondmate skill named by root before backend-specific or persistent-home recovery.

## Routing

Resolve each request from the active message, the current project registry, live task state, and project source.
Do not inherit a project merely because it was discussed previously when the new request does not clearly refer to it.
If one project fits, proceed and state the assumption.
If none or several fit after reading current evidence, ask one focused question.

Check current secondmate scopes before direct dispatch.
Route by task nature and charter scope, not by a project's mere presence in a clone list.
Keep local-only work with the primary home.

Classify a requested code or configuration change as ship.
Classify a requested investigation, plan, audit, diagnosis, or reproduction as scout unless the active instruction also requests implementation.
Serialize work only when it overlaps live mutable state or depends on an unlanded result.

## Supervision

The exact live supervision recipe comes from the block emitted by `bin/fm-session-start.sh`.
Do not substitute commands from another harness or invent a detached wait process.
When work is in flight, maintain exactly one home-scoped supervision cycle through that emitted recipe.

At an actionable wake, run `bin/fm-wake-drain.sh` first unless session start already drained it in the same recovery turn.
Use the wake reason to choose the cheapest fresh evidence.
Read the named status event first, then `bin/fm-crew-state.sh` when current state matters, then inspect the endpoint only when those sources are insufficient.
Use `bin/fm-fleet-view.sh` for a whole-fleet heartbeat review.

Load `.agents/skills/stuck-crewmate-recovery/SKILL.md` for a stale, looping, confused, unresponsive, or failed-steer worker.
Resume the emitted supervision recipe after handling a wake while work remains in flight.

## Captain-facing outcomes

Surface work ready for review, completed findings, decisions, real blockers, failures, credentials, and protected-action approvals.
Keep routine retries, polls, internal labels, and implementation mechanics inside the fleet unless they are the cause of the problem.
Use full PR URLs when reporting review-ready work.
