# Security policy

## Supported versions

Only the latest release gets security fixes, and it reaches callers through the moving `v1` tag or a Dependabot bump of their
pinned SHA. Released `vX.Y.Z` tags are immutable and are never re-pointed.

## Reporting a vulnerability

Report it privately through GitHub's
[private vulnerability reporting](https://github.com/leinardi/gh-reusable-workflows/security/advisories/new), not in a public
issue or pull request. Include the workflow, the version or SHA, and how a caller would be affected.

This is a project maintained in spare time, so reports are handled on a best-effort basis. You will get an answer in the advisory,
and the fix, once released, is credited there unless you prefer otherwise.

## Scope

In scope: the reusable workflows under `.github/workflows/` and anything they execute. A reusable workflow runs with the calling
repository's token and permissions, so a way to make it act outside its documented contract (injection through an input, writing
to a ref it should not touch, running unpinned code) is a vulnerability.

## Security model

- Inputs reach shell and JavaScript through `env:` only, never through expression interpolation inside a script.
- Every third-party action is pinned to a full commit SHA; downloaded tools (`svu`) are pinned to a version and verified against a
  pinned SHA-256.
- Each workflow declares the permissions it needs, and callers grant exactly those.
