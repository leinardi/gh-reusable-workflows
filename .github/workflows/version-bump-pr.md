# version-bump-pr

Reusable workflow for the first half of a release in a repository that commits its version, such
as a Cargo workspace (`[workspace.package] version`) or a Claude Code plugin (`plugin.json`). It
never tags. It:

1. resolves the version, explicit or derived by svu from the Conventional Commits since the last
   `<tag_prefix>X.Y.Z` tag, higher than the version the repository already carries;
2. runs the repository's own bump command, and checks that it changed only the allowed files;
3. pushes the result as one commit, authored and committed by `github-actions[bot]`, on
   `release/<tag>`, cut from the dispatched default-branch commit;
4. opens a pull request into the default branch with `GITHUB_TOKEN`, and dispatches CI on the
   branch.

Merging that pull request with a merge commit is the release:
[`release-on-merge`](release-on-merge.md) authorizes it and waits for CI on the merge commit, and
the caller's next job tags it with [`simple-tag-and-release`](simple-tag-and-release.md).

## Jobs

Repository code never runs next to a write token:

| Job | Permissions | Runs |
| --- | --- | --- |
| `bump` | `contents: read` | Checkout (no credential persisted), svu, `version_command`, `release-version`, `bump_command`, the diff guard, `version_command` again; uploads the staged change as a patch artifact (`version-bump-pr-patch`, kept 1 day). |
| `publish` | `contents: write`, `pull-requests: write`, `actions: write` | No repository code. A fresh checkout of the same commit (no credential persisted), the patch applied with `git apply --index` and checked again, then commit, push, pull request and CI dispatch. |

Whatever the commands do to the `bump` job (git config such as `core.fsmonitor`, hooks,
`GITHUB_ENV`, `GITHUB_PATH`) stays in that job, whose token can only read. The `publish` job trusts
nothing from it unchecked:

- the version and tag outputs must be a strict `X.Y.Z` and exactly `<tag_prefix>X.Y.Z`;
- the patch must apply to the dispatched commit, and every path it changes, read back from the
  index, must be in `allowed_files` exactly, hold no control character, and stay a regular file
  (a symlink or submodule fails);
- every git command runs with `core.fsmonitor=false`, `core.hooksPath=/dev/null` and no signing,
  and the push gets the token through a credential helper in that step's environment only.

## Inputs

| Input | Type | Default | Meaning |
| --- | --- | --- | --- |
| `version` | string | `""` | `X.Y.Z`, `vX.Y.Z` or `<tag_prefix>X.Y.Z`. Empty: derive it with svu. |
| `dry_run` | boolean | `false` | Run the `bump` job, then have `publish` apply the patch, print the diff, read the remote state and print what it would do; push, open and dispatch nothing. |
| `tag_prefix` | string | `v` | Text before `X.Y.Z` in the release tag, such as `<plugin>--v`. |
| `version_command` | string | required | Prints the version the repository carries, `X.Y.Z` on one line (see below). |
| `bump_command` | string | required | Writes the new version (see below). |
| `allowed_files` | string | required | The files the bump may change, relative to the root, separated by spaces or newlines. Give `release-on-merge` the same list. |
| `ci_workflow` | string | `ci.yaml` | The workflow file in `.github/workflows` dispatched on the bump branch. |

| Output | Meaning |
| --- | --- |
| `version` | The version written, `X.Y.Z`. |
| `tag` | The tag the merge will release, `<tag_prefix>X.Y.Z`. |
| `branch` | `release/<tag>`. |
| `pull_request` | The number of the opened, refreshed or reused pull request; empty on a dry run. |

The calling job grants the union of both jobs: `contents: write`, `pull-requests: write`,
`actions: write`. The repository must allow GitHub Actions to create pull requests (Settings,
Actions, "Allow GitHub Actions to create and approve pull requests"). Both jobs fail unless the
run was dispatched from the default branch.

## The commands

Both run with `bash -c` from the repository root, in the `bump` job. They come from the calling
workflow file, which is trusted. The version is never spliced into them: it reaches the bump
command only through the environment, after it was checked to be a strict `X.Y.Z`.

- **`version_command`** prints the version the repository carries now. It is the floor: the new
  version must be higher (equal fails with "already carries"). After the bump it is run again and
  must print the new version. [`release-on-merge`](release-on-merge.md) takes the same command.
- **`bump_command`** writes the new version. It gets `RELEASE_VERSION` (`X.Y.Z`) and `RELEASE_TAG`
  (`<tag_prefix>X.Y.Z`) in the environment, so a make target is called as
  `make release-bump VERSION="$RELEASE_VERSION"`. It must not commit. It may install what it needs
  first (`rustup toolchain install --no-self-update && make release-bump ...`).

After it, the run fails, with nothing pushed, when the bump command failed, moved `HEAD`, changed
nothing, or changed (modified, added, deleted, renamed: both paths) any path not listed in
`allowed_files`; ignored files do not count, and a path with a control character (a newline, a
tab) always fails. Entries are exact file paths, not directories or patterns.

## Re-runs and bringing the pull request up to date

The `publish` job reads the remote once, then acts:

| Found | Action |
| --- | --- |
| The tag `<tag>` exists | Fail: that version is released, or its release is in progress. |
| An open pull request from this repository's `release/<tag>`, opened by `github-actions[bot]`, whose branch is exactly this bump (one commit on the dispatched commit, same tree, authored and committed by `github-actions[bot]`) | Reuse it and dispatch CI on it again. |
| Such a pull request whose branch is anything else (the default branch moved on, "Update branch" added a merge, someone pushed, or recommitted the bump as themselves) | Push this bump onto the branch, replacing what is there, and dispatch CI. The pull request stays open. |
| An open pull request on the branch opened by anyone else, or two of them, or one whose branch is gone | Fail: it needs a human. |
| No open pull request (no branch, or one a failed run left) | Push this bump, open the pull request, dispatch CI. |

The default-branch ruleset requires a branch to be up to date before it merges. Bring a release
pull request up to date by **dispatching the release workflow again** with the same version, not
with "Update branch": that adds a commit which is not the bump, and
[`release-on-merge`](release-on-merge.md) then refuses the release. Pull requests from forks with
the same branch name are ignored.

Every API error fails the run before anything is written. The push is guarded by
`--force-with-lease` against the branch as read, so a branch someone pushed in between is never
overwritten.

## Why CI is dispatched

A pull request opened, and a branch pushed, with `GITHUB_TOKEN` fire no `pull_request` or `push`
run, so its required checks would never start; a `workflow_dispatch` through `GITHUB_TOKEN` is the
documented exception. The caller's `ci_workflow` must therefore have a `workflow_dispatch` trigger,
and its required check (`ci-result`) must run on it.

## Usage

One `release.yaml` holds both halves; see [`release-on-merge`](release-on-merge.md#usage) for the
complete file. The bump job:

```yaml
jobs:
  bump:
    if: github.event_name == 'workflow_dispatch'
    permissions:
      contents: write
      pull-requests: write
      actions: write
    uses: leinardi/gh-reusable-workflows/.github/workflows/version-bump-pr.yaml@<sha> # v1.x.y
    with:
      version: ${{ inputs.version }}
      dry_run: ${{ inputs.dry_run }}
      tag_prefix: my-plugin--v
      version_command: jq -r .version .claude-plugin/plugin.json
      bump_command: make release-bump VERSION="$RELEASE_VERSION"
      allowed_files: .claude-plugin/plugin.json
```

The workflow has its own concurrency group, `version-bump-pr-<owner>/<repo>`, never cancelled; do
not give the caller the same one. GitHub keeps one pending run per group: a third dispatch while
one runs and one waits cancels the waiting one. Dispatch it again; every step is idempotent.

## Tests

`make test` runs `scripts/test-version-bump-pr.sh`, which extracts the inline scripts from this
workflow with `yq` and runs them like the two jobs do: the bump in one checkout, the publish in a
fresh clone of a local bare origin, with a stub `gh`. It covers the diff guard, the patch checks
(files outside the list, control characters, symlinks, `.git`, garbage), the re-run table, a branch
pushed between the read and the push, and hooks and fsmonitor planted in the publish checkout.
