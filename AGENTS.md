# AGENTS.md

## What this is

Reusable GitHub Actions workflows (`on: workflow_call`) that other `leinardi/*` repositories call by
SHA or by the moving `v1` tag. A workflow here runs with the **caller's** token, permissions and
repository, so a defect ships to every caller at once, the next time `v1` moves or Dependabot bumps
their pin.

| Workflow | Called as | What it does |
| --- | --- | --- |
| `.github/workflows/simple-tag-and-release.yaml` | reusable | Resolves a version (explicit or svu-derived, any `tag_prefix`), reconciles the GitHub release, moves `vMAJOR`/`latest` (prefix `v` only). |
| `.github/workflows/version-bump-pr.yaml` | reusable | `bump` job (read-only): the caller's commands and the diff guard, a patch artifact. `publish` job (writes, no repo code): re-checks and applies the patch, pushes `release/<tag>`, opens the PR with `GITHUB_TOKEN`, dispatches CI. |
| `.github/workflows/release-on-merge.yaml` | reusable | On the merge push: `versions` (read-only, runs `version_command`), `authorize` (API only: the PR, its one bump commit, the files), `ci` (`require-ci-green`). Outputs `release`/`tag`; the caller's `publish` job calls `simple-tag-and-release`. |
| `.github/workflows/dependabot-release.yaml` | reusable | On a Dependabot merge push: `authorize` (API only: the last release tag, every commit since it Dependabot's verified commit or the merge of its pull request, at least one `fix`), `ci` (`require-ci-green`, then the default branch still at the push). Outputs `release`/`version`/`tag`; the caller's next job calls `simple-tag-and-release`. |
| `.github/workflows/pre-commit-warmup.yaml` | reusable | Fills the `pre-commit` cache on the default branch, then prunes the older caches of that ref. |
| `.github/workflows/local-*.yaml` | this repo | This repository's own CI, release and warm-up. They call the local reusable files, not `@v1`. |

Each reusable workflow has a `.md` next to it: its contract (inputs, outputs, behaviour, usage).
Keep it in step with the YAML.

Shared logic lives in composite actions of `leinardi/gh-composite-actions` (`setup-svu`,
`release-version`, `require-ci-green`, `prune-caches`), pinned to one release SHA everywhere here;
their tests live there. No reusable workflow here calls another one: a nested `./` call's resolution
is disputed, so `release-on-merge` and `dependabot-release` only decide, and their callers call
`simple-tag-and-release` themselves, pinned to the same commit.

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
| `scripts/test-version-bump-pr.sh` | the same for `version-bump-pr` (throwaway repositories, a local bare origin) |
| `scripts/test-release-on-merge.sh` | the same for `release-on-merge`: the version comparison and the authorization table |
| `scripts/test-dependabot-release.sh` | the same for `dependabot-release`: the authorization table and the head check |
| `scripts/test-pre-commit-warmup.sh` | the warm-up's install step, and its cache key and prune wiring against `local-ci.yaml` |
| `scripts/check-license-headers.sh` | the license-header check |
| `scripts/bootstrap-mk-common.sh`, `.mk/` | shared make snippets from `leinardi/make-common`; `.mk/test.mk` is local |

### Generated or vendored: never hand-edit

- `.mk/help.mk`, `.mk/pre-commit.mk`, `.mk/password.mk` and `.mk/.mk-common-version`: fetched from
  `leinardi/make-common`, refreshed with `make mk-common-update`.
- `scripts/bootstrap-mk-common.sh`: also from make-common; a change is ported upstream.

## Invariants

- **Backward compatible within `v1`.** Callers pin `@v1` or a SHA that Dependabot moves. Never
  remove or rename an input, never make an optional input required, never change a default in a way
  that changes what an existing caller gets. `semver` stays as an alias of `version`, and
  `tag_prefix` defaults to `v`. A breaking change is a `v2`.
- **Inputs reach shell and JavaScript through `env:` only**, never as `${{ inputs.* }}` inside
  `run:` or `script:`.
- **Every action is pinned to a full commit SHA** with the version in a trailing comment.
- **Least privilege.** A reusable workflow declares the permissions it needs; callers grant exactly
  those. The one exception is `pre-commit-warmup.yaml`'s `prune` job, which declares none and runs
  with the calling job's grant: a nested job that requests a permission its caller does not grant
  fails the whole run at startup, so requesting `actions: write` would break every existing caller.
  It skips with a warning when the grant is missing.
- **Release tags are immutable in the callers** ("Immutable tags" ruleset, managed in
  `leinardi/gh-leinardi-iac`, which exempts only `v<N>` and `latest`): no update, no deletion.
  `simple-tag-and-release` therefore never creates a tag it might need to delete: publishing the
  draft creates it, as the last irreversible step. `vMAJOR` and `latest` are the only tags it
  moves, never backwards, and only for the `v` prefix; another prefix moves none.
- **A committed version is released only through its pull request.** `release-on-merge`
  authorizes from the API alone, never from a commit message: exactly one merged PR whose
  `merge_commit_sha` is the pushed SHA, from this repository's `release/<tag>`, opened by
  `github-actions[bot]`, holding exactly one commit by version-bump-pr's git identity, and both
  that commit and the merge change only `allowed_files`. A push of several commits that changes
  the version fails. `release` is true only after `require-ci-green` passed on that SHA. Every API
  error or unexpected response fails closed.
- **A release nobody dispatched ships only Dependabot's work.** `dependabot-release` releases a
  patch only when every commit since the highest release tag is a verified commit by
  `dependabot[bot]` (GitHub's account, not the git author) or the merge of a `dependabot/` pull
  request from its own head, the whole change moves existing action pins to other full SHAs, line
  for line (and pre-commit revs, which ship nothing), at least one is a `fix` and none is breaking
  (subject `!` or footer). Attribution can be borrowed, so the change is what is trusted. Anything
  else is a green no-op with a notice, never a failure: that release is a human's. Callers hold push
  runs in one concurrency group for the whole workflow, so no two runs pick the same version.
- **Repository code never shares a job with a write token.** The caller's `version_command` and
  `bump_command` run only in jobs whose token is `contents: read` (`version-bump-pr`'s `bump`,
  `release-on-merge`'s `versions`), after checkouts with `persist-credentials: false`. Those jobs'
  outputs and artifacts are checked again by the jobs that use them, which run no repository code
  and run git with `core.fsmonitor=false` and `core.hooksPath=/dev/null`. A step that needs git
  credentials gets them through a `GIT_CONFIG_*` credential helper in its own `env:`.
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
| `.github/workflows/version-bump-pr.yaml` | `make test`; a step-script change adds a case to `scripts/test-version-bump-pr.sh`; update `version-bump-pr.md` |
| `.github/workflows/release-on-merge.yaml` | `make test`; a step-script change adds a case to `scripts/test-release-on-merge.sh`; update `release-on-merge.md` |
| `.github/workflows/dependabot-release.yaml` | `make test`; a step-script change adds a case to `scripts/test-dependabot-release.sh`; update `dependabot-release.md` |
| `.github/workflows/pre-commit-warmup.yaml` | `make test` (`scripts/test-pre-commit-warmup.sh`); update `pre-commit-warmup.md`; a key change updates `local-ci.yaml`'s restore key too; to see a real prune, `gh workflow run local-pre-commit-warmup.yaml --ref <branch>` |
| a `leinardi/gh-composite-actions` pin | the same SHA in every workflow and test; `make test`; read that release's notes for input or output changes |
| `.github/workflows/local-*.yaml`, `.github/dependabot.yml` | `pre-commit run actionlint --all-files` |
| `scripts/test-*.sh` | `make test`; break the code under test once and see the case fail |
| `scripts/check-license-headers.sh`, any new code file | `scripts/check-license-headers.sh`; for the script, a file without the header must still fail it |
| `.pre-commit-config.yaml`, `Makefile`, `.mk/test.mk` | `make check`, `make help` |
| `scripts/bootstrap-mk-common.sh` | port the change to make-common; `make help` proves the snippets still load |
| `**/*.md`, `.agents/skills/**` | `make check` (markdownlint); prose wrapped at 100 columns |

## Project skills

- `.agents/skills/adversarial-review/` — how to review a change to this repository. `.claude/skills`
  is a symlink to `.agents/skills`.
