# X mode

Load when: X mode is enabled, an X mention or configuration-error wake arrives, or an X-linked task reaches a milestone or terminal state.

Fresh sources: `.agents/skills/fmx-respond/SKILL.md`, `bin/fm-x-lib.sh`, `bin/fm-x-poll.sh`, `bin/fm-x-reply.sh`, `bin/fm-x-followup.sh`, `bin/fm-x-dismiss.sh`, local X configuration, and current relay output.

## Boundary

X mode is inert unless the active home has opted in through its current local configuration.
The local pairing secret and generated relay state remain private and untracked.
Never copy pairing credentials or captain-private fleet details into a public reply or report.

Opt-in authorizes ordinary reversible mention handling through the normal Firstmate lifecycle.
It does not authorize PR merges, destructive or irreversible actions, production mutations, security-sensitive decisions, or client-money-touching decisions.
Obtain protected authorization through the trusted captain conversation.

## Handling

Load `.agents/skills/fmx-respond/SKILL.md` completely before acting on an X mention, X configuration error, or linked milestone.
That skill owns current classification, reply composition, thread limits, attachments, dry-run behavior, dismissal, and follow-up rules.
`bin/fm-x-lib.sh` and its sibling X scripts own the current transport and state mechanics.

Use public-safe language and disclose no internal fleet mechanics unless the mention is specifically about Firstmate operations.
If a mention requests project work, route it through the same ship or scout lifecycle and authority boundaries as a trusted chat request.
When a linked task reaches a genuine milestone or terminal outcome, apply the current follow-up check before teardown so the link is resolved exactly once.

An X configuration error is a blocker to public handling, not permission to bypass the relay or expose local diagnostics publicly.
