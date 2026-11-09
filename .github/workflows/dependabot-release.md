# dependabot-release

Reusable workflow that releases a patch on its own when merging a Dependabot pull request leaves
nothing but Dependabot's work unreleased. It is meant for a repository whose callers run what it
ships, such as actions or reusable workflows: a pin bump then reaches them without anyone
dispatching the release. With `ecosystems`, it serves a repository that ships an image or binaries
too: a base image, crate, Go module or npm bump that Dependabot marks `fix(deps)` ships the same
way. The caller runs it on every push to the default branch. It decides, and
tags nothing:

- the push is not the merge of a Dependabot pull request: the jobs are skipped;
- something other than Dependabot's work is unreleased, or none of it is a `fix`: a green no-op
  with a notice, `release` empty. That release is a human's, dispatched as usual;
- everything since the last release is Dependabot's, changes only what Dependabot's updates change
  (action pins, and the `ecosystems`' versions), holds at least one
  `fix` and nothing breaking, CI passed on the pushed commit and the default branch has not moved
  on: `release` is `true`, with the next patch as `version` and `tag`;
- a re-run on the release commit itself: `release` is `true` with that release's version, so
  simple-tag-and-release finishes whatever the first run left undone;
- an API error, or a last release that is not an ancestor of the push: the run fails red.

The caller's next job then calls [`simple-tag-and-release`](simple-tag-and-release.md) with the
version, pinned like any other call (see [Usage](#usage)).

## Inputs

| Input | Type | Default | Meaning |
| --- | --- | --- | --- |
| `tag_prefix` | string | `v` | Text before `X.Y.Z` in the release tag, such as `<plugin>--v`. |
| `ci_workflow` | string | `ci.yaml` | The CI workflow file in `.github/workflows` that must have passed on the pushed commit. |
| `ecosystems` | string | `""` | Dependabot ecosystems whose updates may ship besides action pins and pre-commit revs, space-separated: any of `docker`, `cargo`, `gomod`, `npm` (see step 4). Empty: action pins only. |

| Output | Meaning |
| --- | --- |
| `release` | `true` only when everything unreleased is Dependabot's and CI passed on it; otherwise empty. |
| `version` | `X.Y.Z`, the last release's patch + 1; empty unless `release` is `true`. |
| `tag` | `<tag_prefix>X.Y.Z`; empty unless `release` is `true`. |

The calling job grants the union of the jobs: `contents: read`, `pull-requests: read`,
`actions: read`. Nothing is written.

## Jobs

| Job | Permissions | Runs |
| --- | --- | --- |
| `authorize` | `contents: read`, `pull-requests: read` | No checkout, no repository code: GitHub API calls only. |
| `ci` | `actions: read`, `contents: read` | `require-ci-green` on the pushed commit, then the default branch's head, then the `release` output. |

### authorize

The job runs only when the push's head commit starts with `Merge pull request #` and names a
`/dependabot/` branch, so an ordinary push spends no runner. That message is a filter, not a
proof. The step then decides from the API alone, failing on any API error and on any answer that
is not what the API documents:

1. **The last release.** `git/matching-refs/tags/<tag_prefix>` lists the tags. The highest
   `<tag_prefix>X.Y.Z` by version wins (`v1.10.0` over `v1.9.9`; `v1`, `latest` and pre-releases do
   not count). With none, the first release is a human's.
2. **What is unreleased.** `compare/<last tag>...<sha>`: `ahead` goes on, `identical` (the release
   commit itself) finishes that release (see [Concurrency and re-runs](#concurrency-and-re-runs)),
   `behind` (a re-run of an older push) is a no-op, and anything else fails. A comparison that
   lists fewer commits than `total_commits` (the API stops at 250) fails.
3. **Whose it is.** Every commit in the comparison must be one of:

   | Commit | Check |
   | --- | --- |
   | Dependabot's own | one parent; `author.login` is `dependabot[bot]` and `author.type` is `Bot`; `committer.login` is `web-flow` (GitHub created the commit); `commit.verification.verified` is `true` |
   | the merge of a Dependabot pull request | two parents; `commits/{sha}/pulls` lists a pull request whose `merge_commit_sha` is this commit, and `pulls/{number}` has it merged, opened by `dependabot[bot]` (a `Bot`), from a `dependabot/` branch of this repository whose head is the merge's second parent, into this repository's default branch |

   An empty pull request list is read again a few times, since the association can lag the push.
   A commit pushed onto a Dependabot branch, or an "Update branch" merge, is not Dependabot's. A
   commit pushed from a clone with Dependabot as its author has its pusher's committer, not
   `web-flow`. A commit made through the API by someone with write access is committed by
   `web-flow` too and can name any author: step 4 is what bounds it.
4. **What it changes.** Step 3 rests on GitHub's attribution, and a commit can borrow it: anyone
   can write Dependabot's address as the git author, and a verified signature authenticates the
   committer, not the author. So the change itself is checked too. Every file in the comparison
   must be `modified` with a patch (fewer than 300 files, since the API truncates there), and
   every change block (a run of removed and added lines with no unchanged line inside) must
   replace lines one for one: the n-th removed line with the n-th added one, the same line but for
   its ref. That is a `uses: <action>@<full SHA>` pin moving to another full SHA
   (same action, same indentation, any version comment), or a `rev:` line in
   `.pre-commit-config.yaml`. An added or removed step, another action in a pin's place, or a tag
   instead of a SHA is a human's release, whoever wrote it. A borrowed identity can at most move
   an existing pin.

   Each ecosystem in `ecosystems` admits its files, by name, anywhere in the tree:

   | Ecosystem | Files | Each change |
   | --- | --- | --- |
   | `docker` | `Dockerfile`, `Dockerfile.*`, `*.Dockerfile` (and `Containerfile`) | one for one: a `FROM` line, the same image, `--platform` and stage name, another tag or digest; both sides name a tag or a digest (not a bare stage), and a digest is never dropped |
   | `cargo` | `Cargo.toml` | one for one: the same key, a single version requirement (`"1.2.3"`, `{ version = "^1.2" ... }`) for another |
   | `cargo` | `Cargo.lock` | line by line: `[[package]]`, `name`, `version`, `checksum`, `dependencies` entries, and a `source` that is crates.io |
   | `gomod` | `go.mod` | line by line: a requirement on a module path with a dot (`path vX // indirect`), `require (`, `)`, `go`, `toolchain`; no `replace`, `exclude` or `retract` directive |
   | `gomod` | `go.sum` | line by line: `path vX[/go.mod] h1:<hash>` |
   | `npm` | `package.json` | one for one: the same key, a single version (`"^7.1.0"`) for another |
   | `npm` | `package-lock.json` | removed lines are free; each added line is a known key with a plain value (a `node_modules/` entry, `version`, `integrity`, `license`, `dev`/`optional`/`peer`, `engines`, `os`/`cpu`, `funding`, `deprecated`, a dependency range), with no backslash, and a `resolved` is exactly `https://registry.npmjs.org/<name>/-/<base>-<version>.tgz` of the entry it is in. No `name` (an alias), `link`, `bin` or `hasInstallScript` |

   A lockfile (and `go.mod`, which gains indirect requirements) can't be paired line by line, so
   only its lines' shape is checked: a dependency can move to another version from its registry,
   never to another source, a local path or, in `package-lock.json`, another package (the entry's
   own name and version decide its tarball, and a backslash, which could spell another key as a
   JSON escape, is refused). A line Dependabot would write in another shape (a `bin` entry, an
   install script flag) is a human's release, as is a lockfile whose patch GitHub omits (too
   large).

   Accepted limits: a version-shaped value can move on any key of `Cargo.toml` or `package.json`,
   not only in a dependency table (the crate's own `version`, say), since a patch line does not
   say which table it is in; and `go.mod` can gain a requirement on a new module, or a line inside
   an existing `exclude` block, which builds nothing until code imports it. Lowercase `from` / `as`
   in a Dockerfile are refused, a safe miss.
5. **Whether it ships.** At least one of Dependabot's commits is a `fix` (`fix(deps): ...`). A
   breaking commit, by a `!` in its subject or a `BREAKING CHANGE:` (or `BREAKING-CHANGE:`)
   footer anywhere in its message, merge commits included, is a human's release.

The version is the last release's patch + 1, the same that svu derives from `fix` commits, so the
release needs no svu download.

### ci

`require-ci-green` waits, up to 30 minutes, for the newest run of `.github/workflows/<ci_workflow>`
on the pushed SHA, triggered by the `push` to the default branch, and requires its `ci-result` job
to succeed. Then `git/ref/heads/<default branch>` must still be the pushed commit: a newer push has
its own run, whose comparison holds this commit too, and two runs releasing would race. Only then
does the job set `release=true`. When the newer push is not Dependabot's, nothing releases the
older one: that release is a human's, as it would be anyway. A release being finished skips the
head check: its version is already taken.

## Concurrency and re-runs

The version is picked here and published by the caller's next job, under
`simple-tag-and-release`'s own group. Two push runs between those points would pick the same
version, and the second would fail at publishing. So **the caller holds its push runs in one
group for the whole workflow**, never cancelled (see [Usage](#usage)). Its name must differ from
`dependabot-release-<owner>/<repo>` (this workflow's) and `release-<owner>/<repo>`
(simple-tag-and-release's). GitHub keeps at most one pending run per group, so a newer push can
replace a waiting run; when the newer push is not Dependabot's, that release is a human's.

A dispatched release runs outside that group. If it publishes the version a Dependabot run picked,
the Dependabot run fails at publishing without releasing anything; re-run it, and it compares from
the dispatched release and picks the next patch.

A failed run can be re-run: every step reads the same facts again. A run that failed after the tag
(moving `vMAJOR` or `latest`) finds the pushed commit already released, and the re-run hands that
release back to simple-tag-and-release, which finishes it.

## What to expect

- **One release per Dependabot merge that ships a `fix`.** With Dependabot's monthly, grouped
  updates, that is about one or two a month.
- **A slow cascade, not a loop.** A release here is a Dependabot bump in the repositories that pin
  it, which release in turn after their next monthly run and the 7-day cooldown.
- **Callers still choose.** They pin SHAs, and their own Dependabot proposes the release with its
  cooldown.

## Usage

Next to the dispatched release, in the same `release.yaml`:

```yaml
name: Release

on:
  workflow_dispatch:
    inputs:
      version:
        description: "Version, e.g. 1.3.0 or v1.3.0 (empty: derive from the commits since the last release)"
        required: false
        type: string
      dry_run:
        description: "Dry run: resolve the version and print the plan, change nothing"
        type: boolean
        default: false
  push:
    branches:
      - main

permissions:
  contents: read

# Push runs hold one group for the whole workflow; a dispatch runs on its own.
concurrency:
  group: "${{ github.event_name == 'push' && format('release-flow-{0}', github.repository) || github.run_id }}"
  cancel-in-progress: false

jobs:
  dependabot:
    if: github.event_name == 'push'
    permissions:
      contents: read
      pull-requests: read
      actions: read
    uses: leinardi/gh-reusable-workflows/.github/workflows/dependabot-release.yaml@<sha> # v1.x.y
    # Only for a repository that ships an image or binaries: the ecosystems Dependabot bumps with
    # fix(deps). Omit it for actions and reusable workflows.
    # with:
    #   ecosystems: docker cargo

  release:
    needs: dependabot
    # A dispatch skips the dependabot job; always() keeps this job from being skipped with it.
    if: >-
      always()
      && (github.event_name == 'workflow_dispatch' || needs.dependabot.outputs.release == 'true')
    permissions:
      contents: write
    uses: leinardi/gh-reusable-workflows/.github/workflows/simple-tag-and-release.yaml@<sha> # v1.x.y
    with:
      version: ${{ github.event_name == 'workflow_dispatch' && inputs.version || needs.dependabot.outputs.version }}
      dry_run: ${{ github.event_name == 'workflow_dispatch' && inputs.dry_run }}
```

Pin both to the same commit. CI must run on `push` to the default branch with no `paths:` filter,
or `require-ci-green` finds no run and times out.

**A dispatch skips the `dependabot` job, and a skipped job skips every job below it** under the
implicit `success()`, not only the jobs that need it directly. In the example, `release` needs
`dependabot` itself and says `always()`, so it runs. In a longer chain (a `guard` that needs
`dependabot`, then jobs that need `guard`), give every job below the gate an explicit condition,
or a dispatch ends green with nothing released:

```yaml
  ci-green:
    needs: guard
    if: ${{ !cancelled() && needs.guard.result == 'success' }}
```

After wiring a repository, its next release is a dispatch: the wiring commit is not Dependabot's,
so nothing releases on its own until a release covers it.

## Tests

`make test` runs `scripts/test-dependabot-release.sh`: the authorization against canned API
responses from a stub `gh` (the highest tag and a custom prefix; one and several Dependabot pull
requests; chore-only, breaking (subject and footer, merges too), human, unverified and pretend-bot
commits; changes beyond pin bumps (another line, an added or removed step, another action, a
tag instead of a SHA, a moved, swapped or reordered pin, an added file, no patch, a `rev:` outside
pre-commit, a truncated list); a Dependabot-authored commit with another committer; per
ecosystem, the update that ships and what does not (another image or stage, a RUN line, a build
script, a git dependency or source, a `replace`, a script, a `resolved` elsewhere or a `link`, and
an ecosystem not listed), and each rule's edge (a changed tail beside a requirement, a version
beside a git source, a removed lockfile line, an inline `=>`, a `retract`, a short hash, a dropped
digest or tag, a stage turned image, JSON-escaped keys, another package's tarball, a mismatched or
orphan `resolved`, an alias, an install script, a git or path spec, a nested scoped entry, a new
entry); ecosystems split on tabs and newlines; an unknown ecosystem; merges of another
author's pull request, a fork, another branch or base, an unmerged one, a head that is not the
second parent, an "Update branch" merge, an octopus; no release yet, a re-run on the release
commit, behind and diverged comparisons; truncation, API errors and malformed answers), the head
check and its skip for a release being finished, and the job graph and `local-release.yaml`'s
group as written.
