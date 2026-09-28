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

* Pin a **commit SHA** with the version in a trailing comment (`@<sha> # v1.3.0`), or at least a tag (`@v1`), never `@main`.
  Dependabot keeps SHA pins current.
* Filenames without a prefix are intended to be reusable.
* Workflows with a prefix like `local-` are internal to this repo (e.g. `local-ci.yaml`).

---

## Available workflows

* **`simple-tag-and-release.yaml`**
  Release the calling commit as `vX.Y.Z`: the version is passed or derived from Conventional Commits, the GitHub release is created
  idempotently (optionally with build outputs attached), and `vMAJOR` / `latest` move when it is the highest release.
* **`pre-commit-warmup.yaml`**
  Fill the `pre-commit` cache on the default branch so pull-request jobs start warm.

See the corresponding `.md` file next to each workflow (for example:
`.github/workflows/simple-tag-and-release.md`) for details and examples.

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Security issues: [SECURITY.md](SECURITY.md).

---

## License

Licensed under the [MIT License](./LICENSE).
