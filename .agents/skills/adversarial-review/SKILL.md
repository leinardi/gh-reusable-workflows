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

Copy this checklist and tick items as you go:

```text
Review progress:
- [ ] 1. Diff and intent established (default scope if none given)
- [ ] 2. AGENTS.md and the contracts it names read
- [ ] 3. Repository invariants checked
- [ ] 4. Adversarial passes run
- [ ] 5. Findings confirmed or dropped; gates run
- [ ] 6. Report written
```

## 1. Establish the diff

With no scope given, review the uncommitted work; if the tree is clean, review the branch
against `main`.

| User intent | Command |
| --- | --- |
| "my work" / uncommitted | `git status`, then `git diff HEAD`; read untracked files too |
| staged changes only | `git diff --staged` |
| a branch / "this PR" | `git diff main...HEAD` |
| a commit range | `git diff <base>..<head>` |
| a GitHub PR number | `gh pr diff <n>` and `gh pr view <n>` |

Read `git log --oneline` for the range: the stated intent is what the code is checked against.
Read every changed workflow in full, and its `.md` contract next to it.

## 2. Load project authority

Read `AGENTS.md` (the invariants) before judging anything. The `.md` next to each reusable
workflow is its public contract: a behaviour change without a matching `.md` change is a finding,
and so is a `.md` promise the YAML does not keep.

## 3. Repository invariants — check on every review

### Callers of `v1`

- An input removed, renamed, made required, or given a new default that changes an existing
  caller's result is a breaking change. Inside `v1` it is a **critical** finding.
- `semver` must keep working as an alias of `version`.
- An output removed or renamed breaks callers that read it.
- A new required permission breaks every caller that grants only the old set.

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
- **Strict versions.** Every tag lookup goes through `RELEASE_TAG_REGEX`. A glob, `git describe`,
  or "the nearest tag" lets `v1.9.0-rc.1`, `latest` or `v1` become a version.
- **Dry run** writes nothing: no draft, no upload, no ref, no badge.
- The default-branch guard runs before anything that writes.

### Tests

`make test` extracts the step scripts by `id`. A renamed step `id`, or a script that now reads
something other than `env:`, silently drops or breaks its tests. A behaviour change to a step
script without a new case in `scripts/test-simple-tag-and-release.sh` is a gap.

## 4. Adversarial passes

- **Correctness:** a `grep` that matches a prefix (`v1.2` vs `v1.20`), `sort` without `-V`, an
  unanchored regex, `set -e` swallowed inside `$(...)` or a pipeline.
- **Empty and absent:** no tags at all, no releases, an empty artifact, an asset list that is
  empty, `gh` returning an error that is not "not found".
- **Concurrency:** two runs in flight (job `concurrency` must serialize them), a tag pushed by
  someone else between the check and the publish.
- **Contract drift:** the `.md`, `README.md` and `AGENTS.md` still describe what the YAML does.

For each candidate finding, reproduce it or trace the failing input end to end. If that confirms
it, report it; if not, dig once more, then drop it. No named input and wrong result, no finding.

## 5. Verify

| Diff touched | Run |
| --- | --- |
| `simple-tag-and-release.yaml`, `scripts/test-*` | `make test`, then `make check` |
| any workflow | `make check` (actionlint, yamllint, prettier) |
| anything else | `make check` |

A real release can only be proven in a disposable repository that calls the branch SHA. Say
which states you could not exercise rather than implying they passed.

## 6. Report

Rank worst first:

```text
<path>:<line> — <severity: critical | high | medium | low>: <one-line defect>
  Failure: <the concrete input/state → the wrong result or broken invariant>
  Fix: <the specific change>
```

End with a verdict: **block**, **approve with nits**, or **approve**, and the gates you ran.
