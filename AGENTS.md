# AGENTS.md

## What this is

Reusable GitHub Actions workflows (`on: workflow_call`) that other `leinardi/*` repositories call by
SHA or by the moving `v1` tag. A workflow here runs with the **caller's** token, permissions and
repository, so a defect ships to every caller at once, the next time `v1` moves or Dependabot bumps
their pin.

| Workflow | Called as | What it does |
| --- | --- | --- |
| `.github/workflows/simple-tag-and-release.yaml` | reusable | Resolves a version (explicit or svu-derived), reconciles the GitHub release, moves `vMAJOR`/`latest`. |
| `.github/workflows/pre-commit-warmup.yaml` | reusable | Fills the `pre-commit` cache on the default branch, then prunes the older caches of that ref. |
| `.github/workflows/local-*.yaml` | this repo | This repository's own CI, release and warm-up. They call the local reusable files, not `@v1`. |

Each reusable workflow has a `.md` next to it: its contract (inputs, outputs, behaviour, usage).
Keep it in step with the YAML.

## Common commands

```bash
make check             # pre-commit on all files: the local gate, as CI's pre-commit-all
make check-stage       # pre-commit on the staged files only
make test              # scripts/test-*.sh: the workflows' inline scripts, stub gh, no token
make pre-commit-install  # installs the pre-commit and commit-msg hooks
make mk-common-update  # refresh the shared .mk snippets from leinardi/make-common@v1
scripts/check-license-headers.sh  # the MIT header on every code file (also a pre-commit hook)
```

`make check` runs actionlint, yamllint, markdownlint, shellcheck, prettier, checkmake and the
license-header check. In CI, `ci-result` is the one required check: it needs `pre-commit-all`,
`conventional-commits` and `release-workflow-tests` (`local-ci.yaml`); the reviewdog jobs only
annotate pull requests.

## Layout

| Path | What lives there |
| --- | --- |
| `.github/workflows/` | the reusable workflows, their `.md` contracts, and the `local-*` workflows |
| `scripts/test-simple-tag-and-release.sh` | extracts the release workflow's step scripts with `yq` and tests them |
| `scripts/test-pre-commit-warmup.sh` | the same for the warm-up's `prune` step |
| `scripts/check-license-headers.sh` | the license-header check |
| `scripts/bootstrap-mk-common.sh`, `.mk/` | shared make snippets from `leinardi/make-common`; `.mk/test.mk` is local |

### Generated or vendored: never hand-edit

- `.mk/help.mk`, `.mk/pre-commit.mk`, `.mk/password.mk` and `.mk/.mk-common-version`: fetched from
  `leinardi/make-common`, refreshed with `make mk-common-update`.
- `scripts/bootstrap-mk-common.sh`: also from make-common; a change is ported upstream.

## Invariants

- **Backward compatible within `v1`.** Callers pin `@v1` or a SHA that Dependabot moves. Never
  remove or rename an input, never make an optional input required, never change a default in a way
  that changes what an existing caller gets. `semver` stays as an alias of `version`. A breaking
  change is a `v2`.
- **Inputs reach shell and JavaScript through `env:` only**, never as `${{ inputs.* }}` inside
  `run:` or `script:`.
- **Every action is pinned to a full commit SHA** with the version in a trailing comment.
- **Least privilege.** A reusable workflow declares the permissions it needs; callers grant exactly
  those. The one exception is `pre-commit-warmup.yaml`'s `prune` job, which declares none and runs
  with the calling job's grant: a nested job that requests a permission its caller does not grant
  fails the whole run at startup, so requesting `actions: write` would break every existing caller.
  It skips with a warning when the grant is missing.
- **Release tags are immutable in the callers** ("Immutable tags" ruleset, managed in
  `leinardi/gh-leinardi-iac`): no update, no deletion. `simple-tag-and-release` therefore never
  creates a tag it might need to delete: publishing the draft creates it, as the last irreversible
  step. `vMAJOR` and `latest` are the only tags it moves, and never backwards.
- **Idempotent.** Re-running a failed release finishes it. Anything that already exists and
  disagrees with this run (a tag or draft on another commit, an asset with other content) fails with
  "needs a human" instead of being replaced.
- **The step scripts stay self-contained** (inputs from `env:` only), because `make test` extracts
  and runs them outside the workflow. A change to a step script comes with a test case in its
  `scripts/test-*.sh`.

## License headers

Every code file (shell and Python scripts, the Makefile, the repo-local `.mk` fragments) starts
with the MIT notice of the `.idea/copyright` profile, with the year the file was created. The
`check-license-headers` pre-commit hook (`scripts/check-license-headers.sh`) fails on any that
lacks it. YAML, JSON and Markdown are never governed; the make-common files are exempt.

## Markdown

Prose wraps at 100 columns (markdownlint `line-length`, `.editorconfig`); tables, code blocks and
headings may run longer. Never wrap inside a table, a code block or a link target.

## Commit messages

All commits MUST be Conventional Commits 1.0.0 **with a scope**:
`<type>(<scope>)[!]: <description>`, optional blank-line body and footers. Enforced by the
`conventional-pre-commit` `commit-msg` hook (`--force-scope`) and by the `conventional-commits` CI
job. Types: `feat`, `fix`, `docs`, `test`,
`refactor`, `perf`, `build`, `ci`, `chore`, `style`, `revert`. Breaking changes use `!` before `:`
or a `BREAKING CHANGE:` footer. Release notes are not built from these messages:
`gh release create --generate-notes` lists the merged pull requests by title. Examples:
`fix(release): refuse a draft on another commit`, `feat(release): attach artifact files`.

Release versions are derived by `svu` from the commits since the last tag (see
[CONTRIBUTING.md](CONTRIBUTING.md)), so a wrong type ships a wrong version:

| Release | Commit | Example |
| --- | --- | --- |
| major | any type with `!` before the colon, or a `BREAKING CHANGE:` footer | `feat(release)!: drop the semver input` |
| minor | `feat` | `feat(pre-commit-warmup): prune older pre-commit caches` |
| patch | `fix` | `fix(release): quote the tag name` |
| none | everything else: `perf`, `refactor`, `build`, `ci`, `chore`, `docs`, `style`, `test`, `revert` | `ci(deps): bump the checkout action` |

The highest bump among the commits wins; with only "none" commits since the last tag, a release
with no version fails with "nothing to bump". A major never happens inside `v1`: a breaking change
is a new `v2`.

**Pick the type by whether the change should ship, not by what kind of change it is.** Anything
that changes what a caller runs is `fix` (or `feat`), even when it is a performance improvement, a
refactor or a revert. Use `perf`, `refactor`, `style` and `revert` only when the commit is
deliberately not meant to trigger a release on its own. A `revert` of a shipped `feat` or `fix` is
itself a `fix`. `svu` matches `feat`/`fix` anywhere in the subject (e.g. `prefix:` counts as
`fix:`), so avoid a word ending in `feat` or `fix` directly before a colon in other subjects. PRs
land as merge commits, so every commit counts, not just the PR title.

## Validation matrix

Run before considering an edit done. `make check` applies to every row.

| You edited | Run |
| --- | --- |
| `.github/workflows/simple-tag-and-release.yaml` | `make test`; a step-script change adds a case to `scripts/test-simple-tag-and-release.sh`; update `simple-tag-and-release.md` |
| `.github/workflows/pre-commit-warmup.yaml` | `make test` (`scripts/test-pre-commit-warmup.sh`); update `pre-commit-warmup.md`; to see a real prune, `gh workflow run local-pre-commit-warmup.yaml --ref <branch>` |
| `.github/workflows/local-*.yaml`, `.github/dependabot.yml` | `pre-commit run actionlint --all-files` |
| `scripts/test-*.sh` | `make test`; break the code under test once and see the case fail |
| `scripts/check-license-headers.sh`, any new code file | `scripts/check-license-headers.sh`; for the script, a file without the header must still fail it |
| `.pre-commit-config.yaml`, `Makefile`, `.mk/test.mk` | `make check`, `make help` |
| `scripts/bootstrap-mk-common.sh` | port the change to make-common; `make help` proves the snippets still load |
| `**/*.md`, `.agents/skills/**` | `make check` (markdownlint); prose wrapped at 100 columns |

## Project skills

- `.agents/skills/adversarial-review/` — how to review a change to this repository. `.claude/skills`
  is a symlink to `.agents/skills`.
