# Merge and teardown

Load when: a PR or local branch is ready, or before any merge, integrated verification, or teardown action.

Fresh sources: `bin/fm-pr-check.sh`, `bin/fm-pr-merge.sh`, `bin/fm-review-diff.sh`, `bin/fm-merge-local.sh`, `bin/fm-teardown.sh`, and current GitHub state.

## Merge authority

No PR merge occurs without the captain's literal authorization for that PR in the active conversation.
Do not infer authorization from configuration, prior merges, standing autonomy, green checks, an approved review, a task brief, or an agent recommendation.
If authorization is absent, report the full PR URL and readiness evidence, then wait.

Before a permitted PR merge, verify the exact URL, current head, review state, and required checks.
Use `bin/fm-pr-merge.sh` so PR identity and head evidence are recorded before the merge.
Do not call the underlying GitHub merge command directly for a managed task.
Merge ready PRs sequentially and observe each result.

A local-only merge also requires current captain approval.
Review with `bin/fm-review-diff.sh` and merge with `bin/fm-merge-local.sh`.
If the guarded fast-forward refuses, stop and return the lane for correction.

## Integrated verification

After a confirmed merge, refresh the authoritative default branch through the current fleet-sync path.
Exercise the changed behavior at the risk level required by the active task before treating it as integrated.
If integrated verification fails, report the evidence and stop any merge sequence.

## Teardown

Read the full current header of `bin/fm-teardown.sh` before teardown when landed-work proof or cleanup state is not routine.
Use `bin/fm-teardown.sh` without `--force` for ordinary completion.
The script owns the current landed-work proof, PR containment fallback, dirty-worktree refusal, report requirement, backend cleanup, and local-only handling.

Never reinterpret a refusal as a cleanup inconvenience.
Investigate whether work is dirty, unpushed, absent from the recorded PR, not contained by the merged head, or otherwise unlanded.
Preserve the worktree and task state until the proof succeeds.

Use `--force` only when the captain explicitly authorizes discarding the exact identified work.
Forced secondmate retirement can discard child work and persistent state, so it requires the same exact authorization.
A scout is disposable only after its required report exists and has been read.

After successful teardown, apply the backlog reminder printed by the script and re-evaluate newly unblocked work.
