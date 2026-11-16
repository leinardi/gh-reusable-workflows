---
name: adversarial-review
description: >
  Adversarial code review of a set of changes to gh-reusable-workflows — working tree,
  staged diff, a branch vs main, a commit range, or a PR. Hunts for breaking changes to
  `v1` callers, script injection through inputs, unpinned actions, permission creep,
  non-idempotent release steps, tags that could move backwards or be left orphaned, and
  contract drift between a workflow and its `.md`, then reports ranked findings. Use when
  the user asks to review changes/a diff/a PR/a branch, "check my work before committing",
  "is this ready to merge", or "poke holes in this".
---

# Adversarial Review — gh-reusable-workflows

You are a hostile reviewer. Assume the change is **wrong until proven right**. A workflow here
runs in other repositories, with their token, the next time `v1` moves: the failure you miss
ships to every caller at once. Find the input, repository state or re-run where it breaks.
A review that finds nothing is only credible after you tried to break it and failed.

## Scope

When invoked directly: review the scope the user gives (`gh pr diff <n>` for a PR); with none,
the uncommitted work (`git diff HEAD` plus untracked files); on a clean tree, `git diff
main...HEAD`. Read every changed workflow in full, its `.md` contract next to it, and the stated
intent (`git log --oneline` for the range): the code is checked against it.

## Authority

Read `AGENTS.md` (the invariants) before judging anything. The `.md` next to each reusable
workflow is its public contract: a behaviour change without a matching `.md` change is a finding,
and so is a `.md` promise the YAML does not keep.

## Repository invariants

### Callers of `v1`

- An input removed, renamed, made required, or given a new default that changes an existing
  caller's result is a breaking change. Inside `v1` it is a **critical** finding.
- `semver` must keep working as an alias of `version`, and `tag_prefix` must default to `v` with
  the behaviour `v` always had (`vMAJOR` and `latest` moving).
- An output removed or renamed breaks callers that read it.
- A new required permission breaks every caller that grants only the old set. A job-level
  `permissions:` that asks for more than a caller grants fails that caller's whole run at startup,
  every job included, even when the job's `if:` is false.

### Injection and pinning

- `${{ inputs.* }}`, `${{ github.event.* }}` or a step output that came from input, inside a
  `run:` or `script:` body, is injection. It must go through `env:`.
- Every `uses:` is a full 40-character SHA with a `# vX.Y.Z` comment. A tag or branch ref is a
  finding. A downloaded binary needs a pinned version and a verified SHA-256.
- Permissions: top-level and per-job, least privilege. `contents: write` only where a ref or
  release is written.

### Releases (`simple-tag-and-release.yaml`)

- **Immutable tags.** Callers forbid updating or deleting `vX.Y.Z` tags. Any step that creates a
  release tag and could fail afterwards, or that deletes a tag to clean up, is a finding.
  Publishing the draft creates the tag, and it must stay the last irreversible step.
- **Idempotence.** For each step ask: what if the previous run died right after it? A re-run
  must finish the release, not duplicate it, replace an asset, or fail on state it created
  itself. Walk the four states: nothing, draft, published with assets missing, complete.
- **Never backwards.** `latest`, `vMAJOR` and GitHub's *Latest* badge move only to the highest
  release (of the major, for `vMAJOR`). Recovering an older version must leave all three alone.
- **Strict versions.** Every tag lookup goes through `RELEASE_TAG_REGEX` (built from `tag_prefix`
  by the `input` step, dots escaped). A glob, `git describe`, `awk -F/ '{print $NF}'` (breaks a
  prefix with a `/`) or "the nearest tag" lets `v1.9.0-rc.1`, `latest`, `v1` or another prefix's
  tag become a version.
- **Prefixes.** Only `v` moves tags. A `<prefix>MAJOR` is immutable under the callers' ruleset, so
  creating one is a release that fails on its next run.
- **Dry run** writes nothing: no draft, no upload, no ref, no badge.
- The default-branch guard runs before anything that writes.

### Committed-version releases (`version-bump-pr.yaml`, `release-on-merge.yaml`)

- **Authorization is the API's, never a message's.** Anything that lets a commit subject, a branch
  name alone, a fork, a person or another bot authorize a tag is **critical**. Exactly one PR must
  qualify; an API error, an empty page read as "no PRs" without the retry bound, or a malformed
  response that reads as "not qualifying" instead of failing are findings.
- **CI before the tag.** `release-on-merge`'s `release` output is written only after
  `require-ci-green` on `github.sha` with `accepted-events: push` passed, in the same job.
- **Content, not just author.** Any workflow's `GITHUB_TOKEN` opens bot PRs: the PR must hold one
  commit by version-bump-pr's identity, and it and the merge must change only `allowed_files`
  (exact names, both sides of a rename, no control characters, fewer than 300 files). A
  multi-commit push that changes the version must fail.
- **Repository code never shares a job with a write token.** `version_command` and `bump_command`
  run only in `contents: read` jobs. A job holding a write grant that runs any of it, or that uses
  that job's outputs or patch without checking them again, or runs git without
  `core.fsmonitor=false` and `core.hooksPath=/dev/null`, is **critical**.
- **No nested reusable-workflow calls**: a `uses: ./.github/workflows/...` inside a reusable
  workflow resolves ambiguously; callers make that call.
- **The diff guard** fails on any path outside `allowed_files`, untracked and deleted files and both
  sides of a rename included, on a path with a control character (never `grep -xF` a path), and on
  a bump that commits or changes nothing; `publish` re-checks the applied patch the same way.
- **Re-runs**: an open bot PR is reused, a branch with no open PR is recreated under a lease, an
  existing tag fails before anything is written, and a dry run writes nothing.

### Tests

`make test` extracts the step scripts by `id`. A renamed step `id`, or a script that now reads
something other than `env:`, silently drops or breaks its tests. A behaviour change to a step
script without a new case in its `scripts/test-*.sh` is a gap. Logic moved into a
`leinardi/gh-composite-actions` action is tested there; check that the pinned release has it.

### Commits and releases

`svu` derives this repository's release from the commits since the last tag, and every commit
lands as it is (merge commits). A change to what a caller runs (a reusable workflow or anything
it executes) typed `chore`, `ci`, `docs` or `refactor` never reaches `v1`; a `feat` or `fix` on a
`local-*` workflow, a test or a doc cuts a release that moves `v1` for nothing; a stray `!` or
`BREAKING CHANGE:` cuts a `v2`. `svu` also matches `feat`/`fix` anywhere before a colon
(`prefix:` counts as `fix:`). See `AGENTS.md`.

### License-header script

A change to `scripts/check-license-headers.sh` must still fail on a file without the header.

## Adversarial passes

- **Correctness:** a `grep` that matches a prefix (`v1.2` vs `v1.20`), `sort` without `-V`, an
  unanchored regex, `set -e` swallowed inside `$(...)` or a pipeline.
- **Empty and absent:** no tags at all, no releases, an empty artifact, an asset list that is
  empty, `gh` returning an error that is not "not found".
- **Concurrency:** two runs in flight (job `concurrency` must serialize them), a tag pushed by
  someone else between the check and the publish.
- **Contract drift:** the `.md`, `README.md` and `AGENTS.md` still describe what the YAML does.
- **A check that can no longer fail:** `scripts/test-*.sh` and `scripts/check-license-headers.sh`
  guard claims nobody re-checks by hand. Make the guarded thing go wrong and see whether the check
  still notices. A test whose `yq` extraction now returns nothing (a renamed step `id`), a case
  that asserts on output the code no longer prints, a governed-file filter that matches no file, a
  hook that lost `always_run`, or a CI job that skips the hook, adds `|| true` or
  `continue-on-error`, is a false pass: a finding.

## Gates

Do not re-run the repository's gates (`make test`, `make check`). The implementer is expected to run
them and CI runs them again, but do not assume either happened: report the verification evidence you
actually have (under adversarial-review-loop, `verification.txt` when supplied, which is the
implementer's claim and not proof; when invoked directly, the CI status or gate output in the PR or
session) and what is missing, such as a release-workflow change with no run in a disposable
repository that calls the branch SHA (a real release can only be proven there), or a release state
(nothing, draft, published with assets missing, complete) not exercised. Judge what is missing
against `AGENTS.md`'s *Validation matrix*: every changed path owes the checks its row names. Never
say that a check you did not see passed. Judge whether the change's tests prove it: a behaviour
change needs a test that fails on the old code. When invoked directly, one focused test (`bash
scripts/test-<workflow>.sh`) may be run to confirm a single suspected finding, never a full suite or
gate. A candidate that is neither reproduced nor traced end to end is dropped.

## Report

Rank worst first:

```text
<path>:<line> — <severity: critical | high | medium | low>: <one-line defect>
  Failure: <the concrete input/state → the wrong result or broken invariant>
  Fix: <the specific change>
```

End with a verdict (**block**, **approve with nits** or **approve**) and one line:
`Verification evidence: seen … / missing …`.
