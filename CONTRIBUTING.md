# Contributing

Thanks for wanting to contribute.
Every change uses an isolated branch and an ordinary pull request.
The author self-reviews the complete diff against the authoritative base, runs targeted tests plus typecheck and lint where relevant, pushes the feature branch, and opens the PR.
PR CI is the independent shipping check, and a maintainer merges only after required checks pass.

## Workflow

1. Fork the repo, clone it, and add the parent as `upstream` if needed.
2. Fetch the authoritative base and create an isolated feature branch from the current `main`.
3. Make and commit the smallest complete change.
4. Fetch the authoritative base again, rebase when it advanced, and self-review `git diff <authoritative-main>...HEAD` line by line.
5. Run the narrowest relevant tests plus typecheck and lint where the repository provides them.
6. Push only the feature branch:

   ```sh
   git push -u origin HEAD
   ```

7. Open a PR against the parent repository and let PR CI run.
8. Address valid review or CI findings in the same isolated branch.
9. A maintainer merges only after checks pass, then verifies the integrated result.

## Repo conventions

- This repo is a template for running a firstmate orchestrator agent.
  `AGENTS.md` is the agent's main job description and names when to load bundled firstmate skills; `CLAUDE.md` is a symlink to it, and `.claude/skills` is a symlink to `.agents/skills`.
- Only shared material is tracked: `AGENTS.md`, `README.md`, `CONTRIBUTING.md`, `.tasks.toml`, `.github/workflows/`, `bin/`, `.agents/skills/`, and `skills/`.
  `.agents/skills/` holds agent-loaded skills that assume a live firstmate home and carry `metadata.internal: true` so installers such as [skills.sh](https://skills.sh) hide them from discovery; `skills/` holds standalone, installer-facing public skills with no firstmate dependency (see the README's "Two-tier skill layout").
  Everything personal to one captain's fleet (`.env`, `data/`, `state/`, `config/`, `projects/`, and legacy `.no-mistakes/` state) is gitignored; never commit it.
  The root `.tasks.toml` is tracked `tasks-axi` config for `data/backlog.md`; compatible `tasks-axi` is the default backend for routine backlog mutations, with the compatibility definition owned by [`docs/configuration.md`](docs/configuration.md) ("Backlog backend").
  A local `config/backlog-backend=manual` opt-out forces firstmate's routine backlog updates to hand-editing and stays gitignored; validated secondmate handoffs still delegate through `tasks-axi mv`.
  A local `config/backend` file explicitly overrides runtime auto-detection for new task endpoints and stays gitignored; spawn-supported values are `tmux` plus experimental `herdr`, `zellij`, `orca`, and `cmux`, while `codex-app` is documented only in `docs/codex-app-backend.md`.
  It does not make `data/` tracked.
- Helper scripts in `bin/` are plain bash.
  Each starts with a usage header comment; keep it accurate when you change behavior.
  Test scripts and helpers in `tests/` are plain bash too.
  `shellcheck bin/*.sh bin/backends/*.sh tests/*.sh` must pass, and CI enforces it.
- Changes to harness adapters (detection in `bin/fm-harness.sh`, launch and hook mechanics in `bin/fm-spawn.sh`, busy signatures in `bin/fm-watch.sh` and `bin/fm-tmux-lib.sh`, cleanup in `bin/fm-teardown.sh`, and facts in `.agents/skills/harness-adapters/SKILL.md`) must be verified empirically against the real harness, never written from documentation alone.
- Changes to runtime session backends (`bin/fm-backend.sh`, `bin/backends/`, and the scripts that dispatch through them) need empirical adapter notes in the relevant backend guide: `docs/tmux-backend.md`, `docs/herdr-backend.md`, `docs/zellij-backend.md`, `docs/orca-backend.md`, `docs/cmux-backend.md`, or `docs/codex-app-backend.md` for blocked Codex App transport work.
- In Markdown, put each full sentence on its own line.
- `README.md` stays a concise overview plus pointers: it never carries a wall of inline detail.
  Route detail to the most specific `docs/` file (architecture, configuration, or a backend guide) and link to it instead.

## Development

Tracked changes to firstmate itself - `AGENTS.md`, `README.md`, `CONTRIBUTING.md`, `.tasks.toml`, `.github/workflows/`, `bin/`, `.agents/skills/`, and `skills/` - ship through the isolated direct-PR contract on a feature branch and require an explicit merge approval.
Before making any such change, load the agent-only `firstmate-coding-guidelines` skill (`.agents/skills/firstmate-coding-guidelines/SKILL.md`).
It has the knowledge-placement rules that keep `AGENTS.md` from regrowing after each diet pass.
There is no reliable way for `bin/fm-brief.sh`'s scaffold to detect that a task's repo is firstmate itself, so firstmate adds this skill's load line to firstmate-repo briefs by hand.
A crewmate picking up such a brief should load the skill even if the brief predates this instruction.
When supervising live crewmates, keep firstmate's own long validation or build commands in the background so watcher wakes can still be handled.
Crewmates self-review the complete diff against the authoritative base and run targeted tests plus typecheck and lint where relevant before pushing and opening a PR.
Never commit legacy `.no-mistakes/` state or evidence to this repository.

Check and test the toolbelt before pushing:

```sh
for script in bin/*.sh bin/backends/*.sh; do bash -n "$script"; done   # syntax-check the toolbelt
shellcheck bin/*.sh bin/backends/*.sh tests/*.sh   # lint the toolbelt and behavior tests; CI enforces this
for test_script in tests/*.test.sh; do bash "$test_script"; done   # behavior tests, matching CI
[ "$(readlink CLAUDE.md)" = "AGENTS.md" ]
[ "$(readlink .claude/skills)" = "../.agents/skills" ]
tmp=$(mktemp -d) && printf 'done: smoke\n' > "$tmp/smoke.status" && FM_STATE_OVERRIDE="$tmp" FM_SIGNAL_GRACE=1 FM_POLL=1 FM_HEARTBEAT=999999 bin/fm-watch-arm.sh  # watcher re-arm smoke test (prints arm status, then an actionable signal)
```

Discover tests by listing `tests/*.test.sh`: each is a self-contained bash script named `<subject>.test.sh`, and its header comment describes what it covers, so run one directly to focus on a subject.
Tests that need a real optional backend or an explicit opt-in (real herdr/zellij/cmux smoke tests, the live Pi regression) skip themselves and print the tool or environment gate needed to enable them, so the run-all loop above is always safe.

## Questions

Open an issue, or talk to me on [Discord](https://discord.gg/Wsy2NpnZDu).
