# GHA Workflow Templates

Reusable GitHub Actions workflows for Risclog repositories.

## Available Templates

The reusable workflows live under [`.github/workflows`](.github/workflows).

| Workflow | Purpose |
| --- | --- |
| `pytest_appenv.yml` | Test runner for appenv-based projects on GitHub-hosted runners, including a Python matrix, PostgreSQL, artifacts, and raw coverage data. |
| `pytest_appenv_selfhosted.yml` | Appenv test runner for self-hosted runners. |
| `pytest_buildout.yml` | Test runner for buildout-based projects on GitHub-hosted runners. |
| `pytest_self_hosted.yml` | Buildout test runner for self-hosted runners. |
| `coverage.yml` | Combines uploaded coverage files and enforces `min_coverage`. |
| `pre_commit.yml` | Runs `pre-commit` and resolves the Python version from workflow input or `.pre-commit-config.yaml`. |
| `publish_test_results.yml` | Publishes `pytest.xml` as check and PR results. |
| `sonarqube.yml` | Runs SonarQube analysis for Python or JavaScript projects. |
| `check_release.yml` | Decides whether a release should run based on the commit message. |
| `release.yml` | Performs a Python package release with `zest.releaser`. |
| `pin_release.yml` | Pins a released package version in another repository. |
| `deploy.yml` | Deployment workflow for self-hosted runners with SSH and GPG setup. |
| `cleanup.yml` | Artifact cleanup workflow; currently disabled. |
| `actionlint.yml` | Lints the workflow definitions themselves. |
| `ci_selftest.yml` | Runs repository-internal self-tests for the templates. |

## Typical Usage

Example caller workflow:

```yaml
name: Test

on:
  workflow_dispatch:
  push:
    branches:
      - master
      - testing
  pull_request:

jobs:
  test:
    uses: risclog-solution/gha_workflow_templates/.github/workflows/pytest_appenv.yml@master
    with:
      versions: >-
        ["3.10", "3.11", "3.12", "3.13"]
    secrets:
      PIPCONF: ${{ secrets.PIPCONF }}

  coverage:
    needs: test
    uses: risclog-solution/gha_workflow_templates/.github/workflows/coverage.yml@master
    with:
      min_coverage: 80

  pre-commit:
    uses: risclog-solution/gha_workflow_templates/.github/workflows/pre_commit.yml@master
```

## Pre-commit Workflow

The reusable workflow in [`.github/workflows/pre_commit.yml`](.github/workflows/pre_commit.yml) supports two modes:

1. An explicit override via workflow input `python_version`
2. Automatic detection from the caller's `.pre-commit-config.yaml`

The reusable workflow embeds the resolution logic so it works in the caller repository checkout. The matching helper script in [`.github/scripts/resolve_pre_commit_python.rb`](.github/scripts/resolve_pre_commit_python.rb) is kept for local testing and documentation.

### Resolution Order

The Python version is resolved in this order:

1. `with.python_version` in the calling workflow
2. `default_language_version.python` in `.pre-commit-config.yaml` or `.pre-commit-config.yml`
3. a single, unambiguous hook-level `language_version` for Python hooks
4. fallback `3.9`

### Caller Examples

Explicit override:

```yaml
jobs:
  pre-commit:
    uses: risclog-solution/gha_workflow_templates/.github/workflows/pre_commit.yml@master
    with:
      python_version: "3.12"
```

In `.pre-commit-config.yaml`, automatic resolution can look like this:

```yaml
default_language_version:
  python: python3.12

repos:
  - repo: https://github.com/pre-commit/pre-commit-hooks
    rev: v5.0.0
    hooks:
      - id: trailing-whitespace
      - id: end-of-file-fixer
      - id: check-yaml

  - repo: local
    hooks:
      - id: example-python-hook
        name: example-python-hook
        entry: python -c "import sys; print(sys.version)"
        language: python
```

Or at hook level:

```yaml
repos:
  - repo: local
    hooks:
      - id: my-hook
        name: my-hook
        entry: python -c "print('ok')"
        language: python
        language_version: python3.11
```

### Config Rules and Caveats

- The workflow only auto-detects `.pre-commit-config.yaml` or `.pre-commit-config.yml` in the repository root.
- Caller repositories do not need to carry `.github/scripts/resolve_pre_commit_python.rb`; the reusable workflow ships its own resolver logic.
- `python_version` in the workflow always wins. If the input is set, the config is not consulted.
- `default_language_version.python` is the preferred way to define one project-wide Python version for `pre-commit`.
- A single hook-level `language_version` is also supported.
- Multiple different Python versions across hook-level `language_version` values are intentionally not supported. The workflow fails early with a clear error message instead.
- If both `default_language_version.python` and a hook-level `language_version` are set, they must resolve to the same Python version.
- Non-Python hooks are ignored for version resolution.
- Supported version formats are the common ones such as `3.11`, `python3.11`, `python3`, or `python`.
- `default` and `system` are not treated as concrete interpreter versions. In those cases, the resolver continues to the next resolution step.
- If your hooks intentionally require different Python versions, the current template is not sufficient. The workflow would need to be extended to install and manage multiple interpreters.

## Tests and Self-Tests

Repository-internal validation currently runs through [`.github/workflows/ci_selftest.yml`](.github/workflows/ci_selftest.yml) and [`.github/workflows/actionlint.yml`](.github/workflows/actionlint.yml).

### Covered Cases

`ci_selftest.yml` currently verifies:

- fallback behavior when no pre-commit config exists
- resolution through `default_language_version.python`
- resolution through hook-level `language_version`
- workflow input `python_version` taking precedence
- failure on conflicting Python versions in the config
- appenv-specific `update-lockfile` behavior in `pytest_appenv.yml` across the Python matrix `3.9` through `3.13`
- generation and downstream use of coverage artifacts

Fixtures used by the self-tests:

- [`.github/fixtures/pre_commit_default_language.yaml`](.github/fixtures/pre_commit_default_language.yaml)
- [`.github/fixtures/pre_commit_hook_language.yaml`](.github/fixtures/pre_commit_hook_language.yaml)
- [`.github/fixtures/pre_commit_conflict.yaml`](.github/fixtures/pre_commit_conflict.yaml)
- [`.github/fixtures/appenv_stub.sh`](.github/fixtures/appenv_stub.sh)
- [`.github/fixtures/coverage_sample.py`](.github/fixtures/coverage_sample.py)

### Local Testing

Syntax-check the resolver:

```bash
ruby -c .github/scripts/resolve_pre_commit_python.rb
```

Fallback without config:

```bash
resolver="$PWD/.github/scripts/resolve_pre_commit_python.rb"
tmpdir=$(mktemp -d) && (
  cd "$tmpdir" &&
  DEFAULT_PYTHON_VERSION=3.9 ruby "$resolver"
)
```

Resolve via `default_language_version.python`:

```bash
DEFAULT_PYTHON_VERSION=3.9 \
ruby .github/scripts/resolve_pre_commit_python.rb \
.github/fixtures/pre_commit_default_language.yaml
```

Resolve via hook-level `language_version`:

```bash
DEFAULT_PYTHON_VERSION=3.9 \
ruby .github/scripts/resolve_pre_commit_python.rb \
.github/fixtures/pre_commit_hook_language.yaml
```

Simulate workflow-input override:

```bash
DEFAULT_PYTHON_VERSION=3.9 \
INPUT_PYTHON_VERSION=3.13 \
ruby .github/scripts/resolve_pre_commit_python.rb \
.github/fixtures/pre_commit_default_language.yaml
```

Conflict case, expected to exit with status `1`:

```bash
DEFAULT_PYTHON_VERSION=3.9 \
ruby .github/scripts/resolve_pre_commit_python.rb \
.github/fixtures/pre_commit_conflict.yaml
```

Test against a real consumer config:

```bash
DEFAULT_PYTHON_VERSION=3.9 \
ruby .github/scripts/resolve_pre_commit_python.rb \
/path/to/your/project/.pre-commit-config.yaml
```

## GitHub Warning About Node 20

The message

> Warning: Node.js 20 actions are deprecated ...

is currently a GitHub warning, not a failure caused by the `pre_commit` change.

The main trigger right now is `actions/checkout@v4`, which is still used in multiple workflows in this repository. In practice this means:

- GitHub is moving JavaScript actions from Node 20 to Node 24.
- `actions/checkout@v4` should be upgraded in a separate follow-up change.
- The warning is operationally unrelated to the new Python resolution logic in `pre_commit.yml`.

If you want to remove the warning, that should be handled as a repository-wide action-version update.
