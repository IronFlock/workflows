# IronFlock CI harness

Reusable GitHub Actions workflows that give every IronFlock repository the same
gate (lint, unit tests, build) and the same security screening (secrets,
dependencies, SAST, configuration, licences, SBOM, container image).

Every logic step calls a `just` recipe of the calling repository, so a
developer runs the same checks locally that CI runs.

## Use it

`.github/workflows/ci.yml` (see [templates/workflows](templates/workflows)):

```yaml
jobs:
  gate:
    uses: IronFlock/workflows/.github/workflows/go-gate.yml@v1
    with:
      working-directory: .
      targets-file: targets
  workflows:
    uses: IronFlock/workflows/.github/workflows/workflows-lint.yml@v1
```

`.github/workflows/security.yml`:

```yaml
jobs:
  security:
    uses: IronFlock/workflows/.github/workflows/security.yml@v1
    permissions:
      contents: read
      security-events: write
    with:
      languages: go
      image: true
```

The inputs of each workflow are documented in its `on.workflow_call` block.

| Workflow | Jobs | Purpose |
|---|---|---|
| [go-gate.yml](.github/workflows/go-gate.yml) | `lint`, `unit`, `build` | Go gate; cross-build matrix from `targets` / `targets-file` |
| [node-gate.yml](.github/workflows/node-gate.yml) | `lint`, `unit`, `build` | Node/Bun gate: `package-manager` bun or npm, installs from the lockfile only (`bun install --frozen-lockfile` / `npm ci`), fails on a lockfile of the other package manager; `skip` drops jobs a repository has no recipe for |
| [python-gate.yml](.github/workflows/python-gate.yml) | `lint`, `unit`, `build` | Python gate: uv from `tools.lock`; with a `uv.lock`, `uv sync --frozen` (all groups) before the recipes, otherwise the recipes bring their own tools (pinned `uvx`) |
| [security.yml](.github/workflows/security.yml) | `gitleaks`, `deps`, `semgrep`, `sbom`, `config`, `licenses`, `image`, `report` | security screening; `report` applies `fail-on` |
| [workflows-lint.yml](.github/workflows/workflows-lint.yml) | `lint` | actionlint, zizmor, pinact on the caller's workflows; always blocking |
| [release-intent.yml](.github/workflows/release-intent.yml) | `intent` | the version file decides: a rise makes a release PR (title `release <name> <tag>` required), an unchanged version a no-release PR; output `kind` gates the release dry run; listed in the `needs` of `ci-ok` |
| [release-image.yml](.github/workflows/release-image.yml) | `verify`, `build`, `publish` | release of a container image on the merge of a release PR into the protected `main`; native multi-arch build, SBOM + provenance attached, keyless push; on a release PR a dry run (every platform build, no push); re-runs are safe; read rights only; `build-contexts-artifact` hands data an earlier job prepared (with secrets the build must not see) to the build as named contexts |
| [release-tag.yml](.github/workflows/release-tag.yml) | `tag` | the annotated git tag of a release, after every image job of the caller; a tag always means "in the registry"; written with a token of the release GitHub App from the caller's `release` environment |
| [selftest.yml](.github/workflows/selftest.yml) | — | proves the harness against [tests/fixtures](tests/fixtures) |

Gates for Node, Python and chart/shell repositories follow the same pattern
and are added when the first repository of that kind adopts the harness.

## Recipe contract

| Recipe | Meaning |
|---|---|
| `lint` | non-mutating static checks. Go: `gofmt -l`, `go mod tidy -diff`, `go vet`, golangci-lint (incl. gosec, config in [templates/repo/.golangci.yml](templates/repo/.golangci.yml)) |
| `test` | hermetic unit tests. Go: `go test -race -shuffle=on -count=1 ./...` |
| `build` | the artefact build, without publishing |
| `sarif`, `sbom` | optional (Go): write govulncheck SARIF / CycloneDX files; otherwise the harness runs govulncheck and cyclonedx-gomod itself |

Tests that need services (databases, Docker, a router) stay in a
repository-local `integration` job next to the gate.

## Gating

- `lint`, `unit`, `build` and workflow lint block from the first run.
- The security scan starts **report-only** (`fail-on: ""`). After two weeks or
  ten green runs, a repository sets
  `fail-on: secrets,vuln-critical,vuln-high,misconfig-high,license-forbidden,semgrep-error`.
- Vulnerabilities count only when a fixed version exists (trivy
  `--ignore-unfixed`); govulncheck findings count as high only when the
  vulnerable code is reachable.
- A scanner job that fails or is cancelled (rather than finds something) always
  fails `report`: an incomplete scan is not a pass.
- semgrep runs the IronFlock rules plus `semgrep-rulesets` (default `p/default`).
  Go repositories, whose `just lint` runs gosec, set `semgrep-rulesets: ""` so each
  finding is reported (and annotated) once.
- The container image (`image: true`) is built and scanned on the events in
  `image-on`, and on every pull request of a public repository. Private
  repositories skip the build on pull requests to save Actions minutes, except
  on release pull requests (title `release <name> v<x>`): the image that the
  merge publishes is scanned before the merge.

Every run writes a summary table to the job summary and keeps the raw reports
as artifacts (`security-findings-*`, `security-sbom`) for 90 days. A workflow that
calls `security.yml` more than once per run gives each call its own `artifact-prefix`. Public repositories also get
the results in their Security tab.

## Central logic, thin callers

The logic lives here: the reusable workflows, the scripts and the tool pins
(`tools.lock`). Each repository keeps only thin caller files — `ci.yml`,
`security.yml`, `release.yml` — because GitHub starts workflows only from files
in the repository itself. A caller holds the triggers, the repository's settings
(image, version file, directory, targets) and `uses: IronFlock/workflows/...@v1`,
plus jobs only that repository needs (integration tests, a second image). Copy
them from [templates/workflows](templates/workflows). A change to the logic is
made once here and reaches every repository when `v1` moves after a green
self-test; a change to triggers or settings needs a pull request per repository.

## Protected main branch

Each repository protects `main` with a ruleset: changes only through pull
requests, squash-merged, which must be up to date with `main` and pass the
required checks `ci-ok` and `security / report`; no force pushes, no deletion,
no bypass. So every commit on `main` is green, and `release-image.yml` only
checks that the released commit is on `main`. `ci-ok` is a small job at the end
of the caller's `ci.yml` that succeeds only when every other job in it
succeeded (see [templates/workflows/ci-go.yml](templates/workflows/ci-go.yml)).

The check workflows (`ci.yml`, `security.yml`) run on pull requests into
`main`, plus the weekly security scan; a run after the merge would test the
same tree again. The version file decides what a pull request is
(`release-intent.yml`):

| Kind | Made with | Title | Version | On the pull request | After the merge |
|---|---|---|---|---|---|
| release PR | `just release-patch` (`-minor`, `-major`) | `release <name> v<version>` | rises | ci (incl. the release dry run: every platform build, no push) + security | `release.yml` publishes the image, then sets the tag |
| no-release PR | `just merge` | anything that does not read like a release | unchanged | ci + security | nothing runs |

If a release run fails after the merge, `main` holds the new version without
an image or tag; nothing reads it (deployments take versions from the
registry). A transient or permission failure: fix the cause and re-run the run
(safe: nothing is pushed twice, the tag comes last). A code failure: fix it in
the next release PR; the unreleased version stays a gap in the history.

`release.yml` runs on pushes to `main` that touch the version file, and its job
only when the squash-merge title is a release title (`release <name> v...`;
[templates/workflows/release.yml](templates/workflows/release.yml)). The
identity provider grants the publisher service account only to main-branch
pushes (and version tags) through `release-image.yml`. Only the IronFlock
release GitHub App may create `v*` tags (bypass actor of the repository's
`release tags v*` tag ruleset; the built-in GitHub Actions app cannot be one).
`release-tag.yml` takes its token in the repository's `release` environment:
deployments from `main` only, variable `RELEASE_APP_CLIENT_ID`, secret
`RELEASE_APP_PRIVATE_KEY`; the token covers the contents of that one
repository. Callers grant `contents: read` only and pass `secrets: inherit`:
environment secrets reach a reusable workflow only that way.
With `promote-branch` set, the tag job then fast-forwards that branch to the
released commit (never a force push), for a hosting service that deploys from
a branch: only release merges reach it. Protect that branch with a ruleset
whose only bypass actor is the release App.
With `github-release: true` it also creates the GitHub release of the tag
(generated notes), with the same token, so callers need no write rights. Both
steps catch up on a re-run that finds the tag already set.

## Pull requests from a laptop

`just merge` and `just release-patch|minor|major` behave the same in every
repository: the Justfile fetches [scripts/pr.sh](scripts/pr.sh) at `v1` (with
`gh`) and runs it. A repository only names its release, its version file and
the files a bump changes, and writes the version in `_write-version`; copy
[templates/repo/Justfile.release](templates/repo/Justfile.release).

- `just merge [TITLE]`: pushes the current feature branch (also when origin
  does not have it yet), opens the pull request and turns on auto-merge. It
  refuses a changed version and a title starting with `release `. A
  repository without a version, whose `main` is the publication (a content
  site, a plugin marketplace), passes `-` as version file and has no release
  recipes.
- `just release-patch`: the next version is computed from the version on
  `origin/main`, so a second run on the same branch does not bump twice. The
  release commit `release <name> v<x>` holds only the listed files and sits on
  top of the branch's work; on an up-to-date `main` it goes on a new branch
  `release/v<x>`. It then waits for the merge and for the release run, and
  ends back on `main` (detached on `origin/main` in a worktree).

Onboarding a repository onto this flow, besides the caller files:

- `main` ruleset: squash merges only; repository setting "default commit
  message" = pull request title (so the merge commit carries the checked
  title).
- Environment `release`: deployment branches `main` only; variable
  `RELEASE_APP_CLIENT_ID`, secret `RELEASE_APP_PRIVATE_KEY`.
- The release GitHub App installed on the repository and listed as bypass
  actor of the `release tags v*` ruleset.
- The publisher binding of the identity provider for the repository.

## Exceptions

Each exception needs a reason and an expiry, and is reviewed in the pull
request that adds it. Templates are in [templates/repo](templates/repo).

| File | For | Expiry |
|---|---|---|
| `security/vex.openvex.json` | vulnerabilities that do not affect the code (OpenVEX `not_affected` with a `justification`, or `fixed`) | statement `timestamp` + 12 months |
| `.trivyignore.yaml` | image, configuration and licence findings | `expired_at` (required) |
| `.gitleaks.toml` | reviewed secret false positives | review with each change |
| `.gitleaks-baseline.json` | historical findings that cannot be removed from history | — |
| `// nosemgrep: <rule>` | a reviewed semgrep false positive, with the reason | — |

The summary lists exceptions that expire within 30 days.

## Maintaining the harness

- **Versions.** Scanner binaries are pinned with their sha256 in
  [tools.lock](tools.lock) and installed by
  [scripts/install-tool.sh](scripts/install-tool.sh); Go tools and semgrep are
  pinned in the workflows' `env` blocks; actions are pinned to commit SHAs.
- **Self-test.** [selftest.yml](.github/workflows/selftest.yml) runs on every
  pull request and weekly. The fixtures plant one finding per scanner (a fake key,
  a reachable call into a vulnerable `golang.org/x/text`, a secret written to
  the console, a root container on an outdated base image, an unpinned action,
  a failing test); the self-test is green only when each one is reported and
  the clean fixture passes with every `fail-on` category set. Alerts that
  GitHub raises for the fixtures are expected.
- **Releases.** Callers use the moving tag `v1`. Move it only to the merge
  commit of a pull request whose self-test was green (squash merge of an
  up-to-date branch: the same tree):
  `git tag -f v1 <sha> && git push -f origin v1`. Breaking input changes get
  `v2`.
- **Report script.** `python3 -I scripts/test_sarif_summary.py` tests the
  categories, `fail-on`, VEX expiry and the code-scanning copy.
- **Release script.** `bash scripts/test_release.sh` tests the release intent,
  the run modes of `release-image.yml` and the idempotent tag.
