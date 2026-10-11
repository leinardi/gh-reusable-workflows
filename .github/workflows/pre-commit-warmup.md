# pre-commit-warmup

Reusable GitHub Actions workflow to warm up the `pre-commit` cache on a repository.

It:

- Checks out the repo
- Sets up Python
- Installs `pre-commit`
- Populates the `~/.cache/pre-commit` cache by running `pre-commit install-hooks`
- Prunes the older `pre-commit` caches of the calling ref, keeping the newest `keep_caches`

This speeds up later workflows that run `pre-commit` (for example on pull requests).

---

## Inputs

### `python_version` (optional)

- **Type:** `string`
- **Default:** `"3.x"`
- Python version to use for installing and running `pre-commit`.
  Example: `"3.12"`.

### `cache_key_prefix` (optional)

- **Type:** `string`
- **Default:** `"pre-commit"`
- Prefix used in the cache key for the `~/.cache/pre-commit` directory. The key is
  `<cache_key_prefix>|<runner OS>|<hash of .pre-commit-config.yaml>`.

### `prune` (optional)

- **Type:** `boolean`
- **Default:** `true`
- Whether to run the `prune` job after the warm-up. Pass `false` to keep every cache.

### `keep_caches` (optional)

- **Type:** `number`
- **Default:** `2`
- How many of the newest caches to keep. Must be a whole number of at least 1; anything else
  fails the `prune` job.

---

## Pruning

Each change to `.pre-commit-config.yaml` saves a new cache entry, and the old ones would stay in
the repository's cache quota until GitHub evicts them. After the warm-up, the `prune` job lists the
caches of the calling ref (`github.ref`) whose key starts with `<cache_key_prefix>|`, newest
first, keeps the first `keep_caches` and deletes the rest. Only that ref and that prefix are
touched: caches of other branches, of pull requests and of other prefixes stay. It runs after a
failed warm-up too (not after a cancelled one).

Deleting a cache needs **`actions: write`**, which the **calling job** must grant:

```yaml
jobs:
  warm-pre-commit-cache:
    permissions:
      contents: read
      actions: write
    uses: leinardi/gh-reusable-workflows/.github/workflows/pre-commit-warmup.yaml@v1
```

The `prune` job declares no permissions of its own and runs with whatever the calling job grants.
This is deliberate: a nested job that requests a permission its caller does not grant fails the
whole run at startup, warm-up included, so requesting `actions: write` would break every caller
that grants only `contents: read`. A caller without the grant instead gets a
"pre-commit cache prune skipped" warning and a green run, with its caches left as they were. The
warning goes away when the calling job grants `actions: write`, or when it passes `prune: false`.

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
    uses: leinardi/gh-reusable-workflows/.github/workflows/pre-commit-warmup.yaml@v1
```

The self-path (`.github/workflows/pre-commit-warmup.yaml`) re-runs the warm-up when the caller
itself changes, for example when Dependabot bumps the pinned version.

You can override inputs if needed:

```yaml
jobs:
  warm-pre-commit-cache:
    permissions:
      contents: read
      actions: write
    uses: leinardi/gh-reusable-workflows/.github/workflows/pre-commit-warmup.yaml@v1
    with:
      python_version: "3.12"
      cache_key_prefix: "pre-commit-py312"
      keep_caches: 3
```

---

## Recommendation

Use this workflow in combination with other workflows that run `pre-commit` on pull requests.
Warming the cache on `main` (or equivalent) keeps CI runs on feature branches faster.
