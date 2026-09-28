# Contributing

## Setup

Install [`pre-commit`](https://pre-commit.com/), [`shellcheck`](https://www.shellcheck.net/) and
[`yq`](https://github.com/mikefarah/yq) (v4), then install the hooks once with `make pre-commit-install`. It installs both the
`pre-commit` and the `commit-msg` hooks, so commit messages are checked when you commit.

- `make check` runs the full pre-commit suite on every file, `make check-stage` on the staged files only.
- `make test` tests the release workflow's inline scripts against throwaway repositories with a stub `gh`.

A reusable workflow is called by other repositories with their token and permissions: read [AGENTS.md](AGENTS.md) for the
invariants a change must keep, and update the workflow's `.md` contract in the same pull request.

## Commit messages

All commits must follow [Conventional Commits 1.0.0](https://www.conventionalcommits.org/en/v1.0.0/) with a scope:
`<type>(<scope>)[!]: <description>`. The `conventional-pre-commit` hook enforces this on `commit-msg`, and the
`conventional-commits` CI job checks it again on every pull request.

```text
fix(release): refuse a draft that targets another commit
feat(release): attach the files of a caller-built artifact
ci(deps): bump the checkout action
```

The release version is derived from these types, since the last release:

| Release | Commit | Example |
| --- | --- | --- |
| major | any type with `!` before the colon, or a `BREAKING CHANGE:` footer | `feat(release)!: drop the semver input` |
| minor | `feat` | `feat(warmup): add a cache key input` |
| patch | `fix` | `fix(release): quote the tag name` |
| none | everything else: `build`, `chore`, `ci`, `docs`, `perf`, `refactor`, `style`, `test`, `revert` | `docs(readme): fix a link` |

Pick the type by whether callers should receive the change, not by what kind of change it is: anything that changes what a caller
runs is a `fix` (or `feat`), even a refactor. A major is a breaking change for every caller of `v1`, so it never happens inside
`v1`: a breaking change is a new `v2`.

Pull requests are merged with merge commits; squash and rebase merging are disabled. Every commit therefore lands on `main` as it
is, so each one needs a correct type, not just the pull request as a whole.

## Releasing

Dispatch the **Release** workflow (`local-release.yaml`) from `main`. Leave the version empty to derive it from the commits, or
pass one; tick *dry run* first to see what it would do. It runs this repository's own `simple-tag-and-release.yaml`, so a release
always publishes with the workflow it is releasing. Publishing moves `v1`, which every `@v1` caller picks up immediately.
See [`.github/workflows/simple-tag-and-release.md`](.github/workflows/simple-tag-and-release.md) for the details and for
recovering a failed run.
