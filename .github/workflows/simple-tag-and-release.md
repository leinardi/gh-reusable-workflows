# simple-tag-and-release

Reusable workflow that releases the calling commit as `vX.Y.Z`:

- resolves the version: the one you pass, or the next one derived from the [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/)
  since the last release by [`svu`](https://github.com/caarlos0/svu);
- creates a GitHub release with generated notes, optionally with files from an artifact built earlier in the same run;
- moves the `vMAJOR` (e.g. `v1`) and `latest` tags to the release, when it is the highest one.

Every step is idempotent: re-running a failed run finishes what it started, and never replaces what an earlier run published.

## Inputs

| Input | Type | Default | Meaning |
| --- | --- | --- | --- |
| `version` | string | `""` | `X.Y.Z` or `vX.Y.Z`. Empty: derive it from the commits since the last release. |
| `dry_run` | boolean | `false` | Resolve the version and print what would happen; change nothing. |
| `artifact_name` | string | `""` | An artifact uploaded earlier in the calling run. Its files are attached to the release; it must hold top-level files only. |
| `semver` | string | `""` | Deprecated alias of `version`, kept for existing callers. Setting both to different values fails. |

Output: `version`, the released (or, on a dry run, resolved) `vX.Y.Z`.

The caller must grant `contents: write`. The run fails unless it was dispatched from the repository's default branch.

## Versions

A release version is a strict `vMAJOR.MINOR.PATCH`: no leading zeros, no pre-release, no build metadata. Tags that do not match
(`v1`, `latest`, `v1.2.0-rc.1`) are never taken for a release.

With no `version`, `svu` counts the commits since the highest release reachable from the commit:

| Release | Commits since the last release |
| --- | --- |
| major | any type with `!` before the colon, or a `BREAKING CHANGE:` footer |
| minor | `feat` |
| patch | `fix` |
| none | everything else: `build`, `chore`, `ci`, `docs`, `perf`, `refactor`, `style`, … |

The run fails, and changes nothing, when:

- only "none" commits exist since the last release (*nothing to bump*): pass a `version` to release anyway;
- no release tag is reachable at all (a first release): pass a `version`;
- the version is not higher than every released version, unless it is the version already tagged on this commit (a recovery).

## What it does, in order

1. Refuses to run from any branch but the default one.
2. Resolves the version as above.
3. Downloads `artifact_name`, if set.
4. Reconciles the release. The release tag, if it already exists, must point at this commit. Then, by what it finds:
    - no release: creates a draft on this commit, uploads the files, publishes it;
    - a draft (from a run that failed before publishing): checks its target, uploads the missing files, publishes it;
    - a published release (from a run that failed after publishing): uploads the missing files; nothing is re-published.

   A file already on the release with different content is never replaced: the run fails and it needs a human. So does a file on
   the release that the artifact does not contain. Publishing creates the tag, so everything that can fail runs before the tag
   exists. That matters where tags are immutable: a failed run leaves at most a draft, never an orphan tag.
5. Marks the release GitHub's *Latest* only when it is the highest release, so recovering an older version never takes the badge.
6. Moves `vMAJOR` to the release when it is the highest of its major, and `latest` when it is the highest overall. Both are
   updated in place and never move backwards.

A dry run stops after step 4 has printed its plan: no draft, no upload, no tag.

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

To attach build outputs, build them in an earlier job, upload them with `actions/upload-artifact`, and pass the artifact's name:

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

Pin the workflow to a commit SHA with the version in a trailing comment, as above; Dependabot keeps it current.

## Recovering a failed release

Re-run the failed jobs, or dispatch again with the same explicit `version`. The run picks up from what the failed one left: a draft
is reused, missing files are uploaded, an existing tag is accepted only on the same commit. If it stops with *needs a human*, the
message names what disagrees (a tag or draft on another commit, a file with other content); fix that by hand, then re-run.

## Tests

`make test` runs `scripts/test-simple-tag-and-release.sh`, which extracts the inline scripts from this workflow with `yq` and runs
them against throwaway git repositories with a stub `gh`. CI runs it on every pull request.
