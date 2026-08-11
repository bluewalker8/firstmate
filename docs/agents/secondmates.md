# Secondmates

Load when: creating, routing to, seeding, syncing, recovering, handing work to, or retiring a secondmate.

Fresh sources: `.agents/skills/secondmate-provisioning/SKILL.md`, `bin/fm-home-seed.sh`, `bin/fm-config-push.sh`, `bin/fm-backlog-handoff.sh`, `bin/fm-spawn.sh`, and current `data/secondmates.md`.

Read `.agents/skills/secondmate-provisioning/SKILL.md` completely before every secondmate lifecycle or registry action.
That skill owns the current registry format, home lease, transactional rollback, project restrictions, harness pin, sync, inheritance, backlog handoff, recovery, and retirement mechanics.

## Role and scope

A secondmate is a persistent Firstmate for one natural-language domain scope.
It has its own home, lock, state, backlog, configuration, and project clones.
Clone membership is non-exclusive and does not assign work by itself.
Route by the current scope statement and the nature of the request.

A secondmate acts only on work routed to it.
On restart it reconciles work already owned by its home, then idles.
An empty queue is healthy and never authorizes a survey, audit, or self-directed improvement sweep.

The main Firstmate manages only the secondmate as its direct report.
The secondmate manages workers and state inside its own home.
Do not reconstruct or directly supervise the secondmate's child fleet from the primary home.

## Requests and results

Send routed work through the current home-scoped send helper.
Marked main-Firstmate requests return through the secondmate status or a referenced document because the primary does not read its chat.
An unmarked message typed directly by the captain remains an authoritative conversational intervention.

Hand in-scope queued work through `bin/fm-backlog-handoff.sh` after current destination validation.
Do not hand off local-only work.

## Persistence and retirement

Secondmates persist while idle.
Retire one only after an explicit primary decision and the checks owned by the provisioning skill.
Ordinary teardown refuses while child work remains.
Forced retirement is destructive and requires explicit current captain authorization to discard the exact child work and home state.
