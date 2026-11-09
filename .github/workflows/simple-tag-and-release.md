# simple-tag-and-release

Reusable workflow that releases the calling commit as `vX.Y.Z` (or `<tag_prefix>X.Y.Z`):

- resolves the version: the one you pass, or the next one derived from the
  [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/) since the last release by
  [`svu`](https://github.com/caarlos0/svu);
- creates a GitHub release with generated notes, optionally with files from an artifact built
  earlier in the same run;
- for the default `v` prefix, moves the `vMAJOR` (e.g. `v1`) and `latest` tags to the release, when
  it is the highest one.

Every step is idempotent: re-running a failed run finishes what it started, and never replaces what
an earlier run published.

The version is resolved by the
[`release-version`](https://github.com/leinardi/gh-composite-actions/tree/v1.4.2/release-version)
action, and svu is installed by
[`setup-svu`](https://github.com/leinardi/gh-composite-actions/tree/v1.4.2/setup-svu), both from
`leinardi/gh-composite-actions` at a pinned SHA.

## Inputs

| Input | Type | Default | Meaning |
| --- | --- | --- | --- |
| `version` | string | `""` | `X.Y.Z`, `vX.Y.Z` or `<tag_prefix>X.Y.Z`. Empty: derive it from the commits since the last release. |
| `tag_prefix` | string | `v` | The text before `X.Y.Z` in a release tag: `v`, or `<plugin>--v` for a plugin tagged `<plugin>--vX.Y.Z`. Letters, digits and `.`, `_`, `/`, `-` only. See [Tag prefixes](#tag-prefixes). |
| `dry_run` | boolean | `false` | Resolve the version and print what would happen; change nothing. |
| `artifact_name` | string | `""` | An artifact uploaded earlier in the calling run. Its files are attached to the release; it must hold top-level files only. |
| `semver` | string | `""` | Deprecated alias of `version`, kept for existing callers. Setting both to different versions fails. |

| Output | Meaning |
| --- | --- |
| `version` | The released (or, on a dry run, resolved) tag, `<tag_prefix>X.Y.Z`: `vX.Y.Z` for the default prefix. |
| `tag` | The same tag, under a name that says what it is. |

The caller must grant `contents: write`. The run fails unless it was started from the repository's
default branch (a dispatch from it, or a push to it).

## Versions

A release tag is a strict `<tag_prefix>MAJOR.MINOR.PATCH`: no leading zeros, no pre-release, no
build metadata. Tags that do not match (`v1`, `latest`, `v1.2.0-rc.1`, another prefix's tags) are
never taken for a release, and never count when deciding which release is the highest.

With no `version`, `svu` counts the commits since the highest release reachable from the commit:

| Release | Commits since the last release |
| --- | --- |
| major | any type with `!` before the colon, or a `BREAKING CHANGE:` footer |
| minor | `feat` |
| patch | `fix` |
| none | everything else: `build`, `chore`, `ci`, `docs`, `perf`, `refactor`, `style`, … |

The run fails, and changes nothing, when:

- only "none" commits exist since the last release (*nothing to bump*): pass a `version` to release
  anyway;
- no release tag is reachable at all (a first release): pass a `version`;
- the version is not higher than every released version of the prefix, unless it is the version
  already tagged on this commit (a recovery);
- `version` and `semver` are both set and name different versions.

## Tag prefixes

`tag_prefix` defaults to `v`, which is what every existing caller gets. A repository that tags
something else, such as a Claude Code plugin tagged `<plugin>--vX.Y.Z`, passes its prefix:

- versions, the "higher than every release" check and GitHub's *Latest* badge look only at that
  prefix's tags;
- the release is titled with its tag (`gtk-rs-skills--v1.2.0`);
- **no moving tag is created or moved**: neither `latest` nor `<prefix>MAJOR`. `latest` is one tag
  per repository, so two prefixes would take it from each other, and it would no longer mean the
  repository's latest `v` release. A `<prefix>MAJOR` such as `gtk-rs-skills--v1` cannot move under
  the callers' "Immutable tags" ruleset, which exempts only `v<N>` and `latest`: it would be created
  once and the next release would fail after publishing. Plugin consumers resolve the exact
  `<plugin>--vX.Y.Z` tags, so neither is needed.

The *Latest* badge is per repository too: a repository that releases under two prefixes sees it go
to whichever prefix released its highest version last.

## What it does, in order

1. Refuses to run from any branch but the default one.
2. Installs svu (only when neither `version` nor `semver` is set: an explicit version needs no
   download), checks `tag_prefix` and the `version` / `semver` pair, and resolves the version as
   above.
3. Downloads `artifact_name`, if set.
4. Reconciles the release. The release tag, if it already exists, must point at this commit. Then,
   by what it finds:
    - no release: creates a draft on this commit, uploads the files, publishes it;
    - a draft (from a run that failed before publishing): checks its target, uploads the missing
      files, publishes it;
    - a published release (from a run that failed after publishing): uploads the missing files;
      nothing is re-published.

   A file already on the release with different content is never replaced: the run fails and it
   needs a human. So does a file on the release that the artifact does not contain. Publishing
   creates the tag, so everything that can fail runs before the tag exists. That matters where tags
   are immutable: a failed run leaves at most a draft, never an orphan tag.
5. Marks the release GitHub's *Latest* only when it is the highest release of its prefix, so
   recovering an older version never takes the badge. Failing to read which release carries the
   badge fails the run (a re-run finishes it); only "no release is Latest yet" reads as none.
6. For the `v` prefix only, moves `vMAJOR` to the release when it is the highest of its major, and
   `latest` when it is the highest overall. Both are updated in place and never move backwards.

A dry run stops after step 4 has printed its plan: no draft, no upload, no tag.

The checkout persists no credential: the release and every tag are written through the API. The two
steps that read the remote's tags with `git ls-remote` (needed for a private repository) get the
token through a credential helper in their own environment.

## Usage

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
        description: "Dry run: resolve the version and print the plan, change nothing"
        type: boolean
        default: false

permissions:
  contents: read

jobs:
  release:
    permissions:
      contents: write
    uses: leinardi/gh-reusable-workflows/.github/workflows/simple-tag-and-release.yaml@<sha> # v1.x.y
    with:
      version: ${{ inputs.version }}
      dry_run: ${{ inputs.dry_run }}
```

To attach build outputs, build them in an earlier job, upload them with `actions/upload-artifact`,
and pass the artifact's name:

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@<sha> # v7
      - run: make dist
      - uses: actions/upload-artifact@<sha> # v7
        with:
          name: release-assets
          path: dist/*.zip

  release:
    needs: build
    permissions:
      contents: write
    uses: leinardi/gh-reusable-workflows/.github/workflows/simple-tag-and-release.yaml@<sha> # v1.x.y
    with:
      version: ${{ inputs.version }}
      dry_run: ${{ inputs.dry_run }}
      artifact_name: release-assets
```

Pin the workflow to a commit SHA with the version in a trailing comment, as above; Dependabot keeps
it current. A repository that commits its version (a `Cargo.toml`, a `plugin.json`) calls this
from a `publish` job after [`release-on-merge`](release-on-merge.md#usage), with its `tag` output,
once [`version-bump-pr`](version-bump-pr.md)'s pull request is merged.

Do not give the calling workflow, or the calling job, the concurrency group
`release-<owner>/<repo>`: this workflow's job holds it, and a caller holding the same group
deadlocks and is cancelled.

## Recovering a failed release

Re-run the failed jobs, or dispatch again with the same explicit `version`. The run picks up from
what the failed one left: a draft is reused, missing files are uploaded, an existing tag is accepted
only on the same commit. If it stops with *needs a human*, the message names what disagrees (a tag
or draft on another commit, a file with other content); fix that by hand, then re-run.

## Tests

`make test` runs `scripts/test-simple-tag-and-release.sh`, which extracts the inline scripts from
this workflow with `yq` and runs them against throwaway git repositories with a stub `gh`. The
version resolution is `release-version`'s, tested in `leinardi/gh-composite-actions`. CI runs both
on every pull request.
