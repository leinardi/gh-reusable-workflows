# release-on-merge

Reusable workflow for the second half of a release in a repository that commits its version
([`version-bump-pr`](version-bump-pr.md) is the first). The caller runs it on every push to the
default branch that touches the version file. It decides, and tags nothing:

- the version did not change: a green no-op, `release` empty;
- the push is the merge of version-bump-pr's pull request for exactly the version it now carries,
  that pull request is exactly the one bump commit, and CI passed on the merge commit: `release` is
  `true`, with `version` and `tag`;
- anything else that changed the version: the run fails red.

The caller's next job then calls [`simple-tag-and-release`](simple-tag-and-release.md) with the
tag, pinned like any other call (see [Usage](#usage)).

## Inputs

| Input | Type | Default | Meaning |
| --- | --- | --- | --- |
| `version_command` | string | required | Prints the version the repository carries, `X.Y.Z` on one line. |
| `allowed_files` | string | required | The files a release may change, separated by spaces or newlines: version-bump-pr's list. |
| `tag_prefix` | string | `v` | Text before `X.Y.Z` in the release tag, such as `<plugin>--v`. |
| `ci_workflow` | string | `ci.yaml` | The CI workflow file in `.github/workflows` that must have passed on the merge commit. |

| Output | Meaning |
| --- | --- |
| `release` | `true` only when the push is an authorized release and CI passed on it; otherwise empty. |
| `version` | `X.Y.Z`; empty unless `release` is `true`. |
| `tag` | `<tag_prefix>X.Y.Z`, the `version` to give simple-tag-and-release; empty unless `release` is `true`. |

The calling job grants the union of the jobs: `contents: read`, `pull-requests: read`,
`actions: read`. Nothing is written.

## Jobs

| Job | Permissions | Runs |
| --- | --- | --- |
| `versions` | `contents: read` | Checkout of the whole history (no credential persisted); `version_command` on the pushed commit, its first parent and the push's `before`. |
| `authorize` | `contents: read`, `pull-requests: read` | No checkout, no repository code: GitHub API calls only. |
| `ci` | `actions: read` | `require-ci-green` on the pushed commit, then the `release` output. |

`version_command` is code from the commit being judged, so it runs alone in `versions`, whose
token can only read. What it could do there (write `GITHUB_ENV` or `GITHUB_PATH`, forge the step's
outputs) reaches no other job: `authorize` checks the reported version again (a strict `X.Y.Z`)
and decides everything else from the API.

### versions

The version is read by running `version_command` in a worktree of each commit, so no second
description of the file format is needed:

| Repository | `version_command` |
| --- | --- |
| Cargo workspace (`[workspace.package] version`) | `python3 -c 'import tomllib; print(tomllib.load(open("Cargo.toml", "rb"))["workspace"]["package"]["version"])'` |
| Claude Code plugin (`.claude-plugin/plugin.json`) | `jq -r .version .claude-plugin/plugin.json` |

Anything but one strict `X.Y.Z` line fails the run. Then:

| The push | Result |
| --- | --- |
| `before` is missing, all zeros, or not in the history (a force push) | Fail: what the push changed is unknown. |
| One commit on top of `before` (`before` is its first parent), version unchanged | No-op. |
| The same, version raised | A candidate for `authorize`. |
| The same, version lowered | Fail. |
| Several commits on top of `before` (a fast-forward of several commits, a rebase merge), version unchanged across the push | No-op. |
| The same, version changed | Fail: no single pull request merge authorizes it. |

### authorize

From the API alone, every page read, and failing on any API error (403, 404, 409, 5xx) and on any
answer that is not what the API documents:

1. **What the merge changed.** `commits/{sha}` gives the first parent; `compare/{parent}...{sha}`
   must list only files in `allowed_files` (both names of a rename, no control characters, fewer
   than 300 files, since the API truncates there).
2. **Which pull request merged it.** `commits/{sha}/pulls` lists the merged pull request that
   introduced the commit, which for a merge commit is the one it merged. An empty list is read again
   a few times, since the association can lag the push. Each listed pull request is read in full
   from `pulls/{number}`, and exactly one must qualify:

   | Check | Field |
   | --- | --- |
   | merged | `merged` is `true` and `merged_at` is set |
   | by exactly this commit | `merge_commit_sha` equals the pushed SHA |
   | into this repository's default branch | `base.ref`, `base.repo.full_name` |
   | from this repository, not a fork | `head.repo.full_name` (a deleted fork's is `null`: refused) |
   | from the bump branch of exactly this version | `head.ref` is `release/<tag_prefix><version>` |
   | opened by version-bump-pr | `user.login` is `github-actions[bot]`, `user.type` is `Bot` |

3. **What the pull request holds.** Any workflow's `GITHUB_TOKEN` can open a pull request as
   `github-actions[bot]`, so its content is checked too. `pulls/{number}/commits` must list exactly
   one commit, the pull request's head, whose git author and committer are both
   `github-actions[bot] <41898282+github-actions[bot]@users.noreply.github.com>` (the identity
   version-bump-pr commits with), and `commits/{that sha}` must list only files in
   `allowed_files`.

The merge commit's subject is printed as a diagnostic only. Who made the merge commit does not
matter. What a merged pull request says cannot change afterwards (merge commit, head, base, author,
commits), so nothing can be edited between this check and the tag.

### ci

`require-ci-green` waits, up to 30 minutes, for the newest run of `.github/workflows/<ci_workflow>`
on the pushed SHA, triggered by the `push` to the default branch, and requires its `ci-result` job
to succeed. Only then does the job set `release=true`. A CI workflow whose `push` trigger skips the
merge (a `paths:` filter, a branch filter) leaves no run to find, and the gate times out.

## Why the caller calls simple-tag-and-release

A reusable workflow calling another one with `./.github/workflows/...` is documented to use "the
same commit as the caller workflow", but how that resolves when the caller is itself called from
another repository is disputed (community reports have it resolve in the top-level caller's
repository, which would fail every caller at startup), and the explicit `$/` syntax is too new for
the pinned actionlint. Pinning `simple-tag-and-release` from inside this file would have to name a
commit of this repository other than its own. So this workflow decides, and the caller's `publish`
job calls `simple-tag-and-release.yaml@<the same sha>`, with Dependabot bumping both pins together.

## Concurrency and re-runs

Runs share the group `release-on-merge-<owner>/<repo>` and are never cancelled.
`simple-tag-and-release` serializes its own job under `release-<owner>/<repo>`. Do not give the
caller either group. GitHub keeps at most one pending run per group: when a third run arrives
while one runs and one waits, the waiting one is cancelled, and its version is not tagged until it
runs. Merges of release pull requests are rare enough for this to be unlikely; if it happens,
**re-run the cancelled run** (all jobs): every step reads the same facts again, and
simple-tag-and-release finishes a release an earlier run started. (`concurrency.queue: max` would
remove this, but actionlint v1.7.12, the latest release, rejects it.)

## Usage

The single `release.yaml` of a repository that commits its version, both halves:

```yaml
name: Release

on:
  workflow_dispatch:
    inputs:
      version:
        description: "Version, e.g. 1.2.0 (empty: derive from the commits since the last release)"
        required: false
        type: string
      dry_run:
        description: "Dry run: resolve the version and show the bump, change nothing"
        type: boolean
        default: false
  push:
    branches:
      - main
    paths:
      - .claude-plugin/plugin.json

permissions:
  contents: read

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

  release:
    if: github.event_name == 'push'
    permissions:
      contents: read
      pull-requests: read
      actions: read
    uses: leinardi/gh-reusable-workflows/.github/workflows/release-on-merge.yaml@<sha> # v1.x.y
    with:
      tag_prefix: my-plugin--v
      version_command: jq -r .version .claude-plugin/plugin.json
      allowed_files: .claude-plugin/plugin.json

  publish:
    needs: release
    if: needs.release.outputs.release == 'true'
    permissions:
      contents: write
    uses: leinardi/gh-reusable-workflows/.github/workflows/simple-tag-and-release.yaml@<sha> # v1.x.y
    with:
      version: ${{ needs.release.outputs.tag }}
      tag_prefix: my-plugin--v
```

Pin all three to the same commit. `paths:` only saves runs: a push that touches the file without
changing the version is a green no-op either way.

## Tests

`make test` runs `scripts/test-release-on-merge.sh`: the versions table against throwaway git
repositories, and the authorization against canned API responses from a stub `gh` (one, none and
several qualifying pull requests; fork and deleted heads; wrong branch, author, base and merge
commit; unmerged; an extra commit, a foreign identity or an extra file in the pull request; files
outside the list, renames and control characters in the merge; API errors and malformed answers).
The job graph is checked as written.
