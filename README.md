# gh-reusable-workflows

Reusable GitHub Actions workflows maintained by [@leinardi](https://github.com/leinardi).

This repo is a small toolbox of opinionated workflows that can be called from other repositories via [`workflow_call`](https://docs.github.com/en/actions/using-workflows/reusing-workflows).

---

## Usage

Call a workflow from this repo like this:

```yaml
jobs:
  some-job:
    uses: leinardi/gh-reusable-workflows/.github/workflows/<workflow>.yaml@v1
    with:
      # workflow-specific inputs
```

* Use a **tag** (`@v1`, `@v1.0.0`, …) instead of `@main` for reproducibility.
* Filenames without a prefix are intended to be reusable.
* Workflows with a prefix like `local-` are internal to this repo (e.g. `local-ci.yaml`).

---

## Available workflows

* **`simple-tag-and-release.yaml`**
  Create a semantic version tag, GitHub Release, and update `vMAJOR` and `latest` tags.

See the corresponding `.md` file next to each workflow (for example:
`.github/workflows/simple-tag-and-release.md`) for details and examples.

---

## License

Licensed under the [MIT License](./LICENSE).
