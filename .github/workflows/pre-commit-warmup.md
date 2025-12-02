# pre-commit-warmup

Reusable GitHub Actions workflow to warm up the `pre-commit` cache on a repository.

It:

- Checks out the repo
- Sets up Python
- Installs `pre-commit`
- Populates the `~/.cache/pre-commit` cache by running `pre-commit install-hooks`

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
- Prefix used in the cache key for the `~/.cache/pre-commit` directory.

---

## Usage

Example in a consuming repository:

```yaml
name: Pre-commit Cache Warm-up

on:
  push:
    branches:
      - main
      - master
    paths:
      - .pre-commit-config.yaml
  workflow_dispatch:

jobs:
  warm-pre-commit-cache:
    uses: leinardi/gh-reusable-workflows/.github/workflows/pre-commit-warmup.yaml@v1
````

You can override inputs if needed:

```yaml
jobs:
  warm-pre-commit-cache:
    uses: leinardi/gh-reusable-workflows/.github/workflows/pre-commit-warmup.yaml@v1
    with:
      python_version: "3.12"
      cache_key_prefix: "pre-commit-py312"
```

---

## Recommendation

Use this workflow in combination with other workflows that run `pre-commit` on pull requests.
Warming the cache on `main` (or equivalent) keeps CI runs on feature branches faster.
