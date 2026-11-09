# pre-commit-warmup

Reusable GitHub Actions workflow to warm up the `pre-commit` cache on a repository's default
branch, the one ref whose caches every pull request can restore.

It:

- checks out the repo (no credential persisted);
- sets up Python (`python_version`);
- installs the pinned `pre-commit` (`pre_commit_version`);
- populates the `~/.cache/pre-commit` cache by running `pre-commit install-hooks`, under the key
  below;
- prunes the older `pre-commit` caches of the calling ref, keeping the newest `keep_caches`, with
  the [`prune-caches`](https://github.com/leinardi/gh-composite-actions/tree/v1.4.2/prune-caches)
  action.

The warm-up is the only writer of this cache: the CI jobs that run `pre-commit` restore it with
`actions/cache/restore`, under the same key.

---

## Inputs

| Input | Type | Default | Meaning |
| --- | --- | --- | --- |
| `python_version` | string | `"3.x"` | Python for `actions/setup-python`. Its **resolved** version (for example `3.14.0`) is part of the cache key. |
| `pre_commit_version` | string | `"4.6.2"` | The `pre-commit` release to install, `X.Y.Z`. Anything else fails before `pip` runs. Keep it equal to the version CI installs. |
| `cache_key_prefix` | string | `"pre-commit"` | The first part of the cache key. |
| `prune` | boolean | `true` | Whether to run the `prune` job after the warm-up. Pass `false` to keep every cache. |
| `keep_caches` | number | `2` | How many of the newest caches to keep, a whole number of at least 1; anything else fails the `prune` job. |

| Output | Meaning |
| --- | --- |
| `cache_key` | The key the warm-up saved (or found). |

Every job has a `timeout-minutes`.

---

## Cache key

```text
<cache_key_prefix>|<runner.os>|<resolved Python version>|<hash of .pre-commit-config.yaml>
```

The hook environments are virtualenvs bound to the interpreter that built them, so the Python
version is part of the key: when `3.x` moves to a new minor, the warm-up saves a new entry instead
of serving environments built for the old one. The resolved version is setup-python's
`python-version` output, not the `python_version` input.

A CI job restores it with the same four parts. It sets up the same `python_version` with an `id`,
and builds the key from that step's output:

```yaml
- name: Set up Python
  id: python
  uses: actions/setup-python@<sha> # v7.1.0
  with:
    python-version: "3.x" # the warm-up's python_version

- name: Install pre-commit
  run: pip install --no-cache-dir pre-commit==4.6.2 # the warm-up's pre_commit_version

# Restore only: the warm-up is the only writer.
- name: Restore the pre-commit cache
  uses: actions/cache/restore@<sha> # v6.1.0
  with:
    path: ~/.cache/pre-commit
    key: pre-commit|${{ runner.os }}|${{ steps.python.outputs.python-version }}|${{ hashFiles('.pre-commit-config.yaml') }}
```

`pre-commit` is the default `cache_key_prefix`; a caller that passes another one uses it here too.

Before v1.5.0 the key had no Python part (`<prefix>|<runner.os>|<hash>`). A CI job that still
restores that exact key misses until it adds the Python part; one that also lists
`restore-keys: <prefix>|<runner.os>|` keeps restoring the newest entry, a possibly stale one,
meanwhile. So a caller bumps this workflow's pin and its CI restore key in the same change; for
`template-default`, whose CI every new repository copies, that is the phase-4 change that adopts
v1.5.0.

---

## Pruning

Each change to `.pre-commit-config.yaml`, or to the resolved Python, saves a new cache entry, and
the old ones would stay in the repository's cache quota until GitHub evicts them. After the
warm-up, the `prune` job lists the caches of the calling ref (`github.ref`) whose key starts with
`<cache_key_prefix>|`, newest first, keeps the first `keep_caches` and deletes the rest. Only that
ref and that prefix are touched: caches of other branches, of pull requests and of other prefixes
stay. It runs after a failed warm-up too (not after a cancelled one).

Deleting a cache needs **`actions: write`**, which the **calling job** must grant:

```yaml
jobs:
  warm-pre-commit-cache:
    permissions:
      contents: read
      actions: write
    uses: leinardi/gh-reusable-workflows/.github/workflows/pre-commit-warmup.yaml@<sha> # v1.x.y
```

The `prune` job declares no permissions of its own and runs with whatever the calling job grants.
This is deliberate: a nested job that requests a permission its caller does not grant fails the
whole run at startup, warm-up included, so requesting `actions: write` would break every caller
that grants only `contents: read`. A caller without the grant instead gets a "Cache prune skipped"
warning and a green run, with its caches left as they were. The warning goes away when the calling
job grants `actions: write`, or when it passes `prune: false`. Any other API error, such as a rate
limit, fails the `prune` job.

---

## Usage

Example in a consuming repository:

```yaml
name: Pre-commit Cache Warm-up

# Keeps a default-branch cache of the pre-commit hook environments for pull requests to restore.
# The weekly schedule is eviction insurance: GitHub evicts a cache nobody restored for 7 days.
on:
  push:
    branches:
      - main
    paths:
      - .pre-commit-config.yaml
      - .github/workflows/pre-commit-warmup.yaml
  schedule:
    - cron: "37 3 * * 1"
  workflow_dispatch:

concurrency:
  group: pre-commit-warmup-${{ github.ref }}
  cancel-in-progress: true

permissions:
  contents: read

jobs:
  warm-pre-commit-cache:
    # actions: write lets the prune job delete the older caches.
    permissions:
      contents: read
      actions: write
    uses: leinardi/gh-reusable-workflows/.github/workflows/pre-commit-warmup.yaml@<sha> # v1.x.y
```

The self-path (`.github/workflows/pre-commit-warmup.yaml`) re-runs the warm-up when the caller
itself changes, for example when Dependabot bumps the pinned version.

You can override inputs if needed; CI must then set up the same Python and install the same
`pre-commit`:

```yaml
jobs:
  warm-pre-commit-cache:
    permissions:
      contents: read
      actions: write
    uses: leinardi/gh-reusable-workflows/.github/workflows/pre-commit-warmup.yaml@<sha> # v1.x.y
    with:
      python_version: "3.12"
      pre_commit_version: "4.6.2"
      keep_caches: 3
```

---

## Tests

`make test` runs `scripts/test-pre-commit-warmup.sh`: the install step's version check with stub
`python` and `pre-commit`, and the key and prune wiring as written, against this repository's own
CI, which restores the key. The prune logic is `prune-caches`', tested in
`leinardi/gh-composite-actions`.
