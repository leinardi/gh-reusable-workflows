# AGENTS.md

## What this is

Reusable GitHub Actions workflows (`on: workflow_call`) that other `leinardi/*` repositories call by SHA or by the moving `v1` tag.
A workflow here runs with the **caller's** token, permissions and repository, so a defect ships to every caller at once, the next
time `v1` moves or Dependabot bumps their pin.

| Workflow | Called as | What it does |
| --- | --- | --- |
| `.github/workflows/simple-tag-and-release.yaml` | reusable | Resolves a version (explicit or svu-derived), reconciles the GitHub release, moves `vMAJOR`/`latest`. |
| `.github/workflows/pre-commit-warmup.yaml` | reusable | Fills the `pre-commit` cache on the default branch. |
| `.github/workflows/local-*.yaml` | this repo | This repository's own CI, release and warm-up. They call the local reusable files, not `@v1`. |

Each reusable workflow has a `.md` next to it: its contract (inputs, outputs, behaviour, usage). Keep it in step with the YAML.

## Common commands

```bash
make check             # pre-commit on all files (actionlint, yamllint, markdownlint, shellcheck, prettier, checkmake, …)
make check-stage       # pre-commit on the staged files only
make test              # scripts/test-simple-tag-and-release.sh: the release workflow's inline scripts, stub gh, no token
make pre-commit-install  # installs the pre-commit and commit-msg hooks
make mk-common-update  # refresh the shared .mk snippets from leinardi/make-common@v1
```

## Layout

| Path | What lives there |
| --- | --- |
| `.github/workflows/` | the reusable workflows, their `.md` contracts, and the `local-*` workflows |
| `scripts/test-simple-tag-and-release.sh` | extracts the release workflow's step scripts with `yq` and tests them |
| `scripts/bootstrap-mk-common.sh`, `.mk/` | shared make snippets from `leinardi/make-common`; `.mk/test.mk` is local |

## Invariants

- **Backward compatible within `v1`.** Callers pin `@v1` or a SHA that Dependabot moves. Never remove or rename an input, never
  make an optional input required, never change a default in a way that changes what an existing caller gets. `semver` stays as an
  alias of `version`. A breaking change is a `v2`.
- **Inputs reach shell and JavaScript through `env:` only**, never as `${{ inputs.* }}` inside `run:` or `script:`.
- **Every action is pinned to a full commit SHA** with the version in a trailing comment.
- **Least privilege.** A reusable workflow declares the permissions it needs; callers grant exactly those.
- **Release tags are immutable in the callers** ("Immutable tags" ruleset, managed in `leinardi/gh-leinardi-iac`): no update, no
  deletion. `simple-tag-and-release` therefore never creates a tag it might need to delete: publishing the draft creates it, as the
  last irreversible step. `vMAJOR` and `latest` are the only tags it moves, and never backwards.
- **Idempotent.** Re-running a failed release finishes it. Anything that already exists and disagrees with this run (a tag or
  draft on another commit, an asset with other content) fails with "needs a human" instead of being replaced.
- **The step scripts stay self-contained** (inputs from `env:` only), because `make test` extracts and runs them outside the
  workflow. A change to a step script comes with a test case in `scripts/test-simple-tag-and-release.sh`.

## Commit messages

[Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/) with a mandatory scope, enforced by the
`conventional-pre-commit` `commit-msg` hook (`--force-scope`) and by the `conventional-commits` CI job on every pull request. The
release version is derived from them (see [CONTRIBUTING.md](CONTRIBUTING.md)): a change callers should receive is a `fix` or a
`feat`, a breaking one needs `!`. Examples: `fix(release): refuse a draft on another commit`, `feat(release): attach artifact files`.

## Project skills

- `.agents/skills/adversarial-review/` — how to review a change to this repository. `.claude/skills` is a symlink to
  `.agents/skills`.
