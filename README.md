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
| [security.yml](.github/workflows/security.yml) | `gitleaks`, `deps`, `semgrep`, `sbom`, `config`, `licenses`, `image`, `report` | security screening; `report` applies `fail-on` |
| [workflows-lint.yml](.github/workflows/workflows-lint.yml) | `lint` | actionlint, zizmor, pinact on the caller's workflows; always blocking |
| [release-image.yml](.github/workflows/release-image.yml) | `verify`, `build`, `publish` | release of a container image from a version tag: only commits on the protected `main`; native multi-arch build, SBOM + provenance attached, keyless push |
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

Every run writes a summary table to the job summary and keeps the raw reports
as artifacts (`security-findings-*`, `security-sbom`) for 90 days. A workflow that
calls `security.yml` more than once per run gives each call its own `artifact-prefix`. Public repositories also get
the results in their Security tab.

## Protected main branch

Each repository protects `main` with a ruleset: changes only through pull
requests, which must be up to date with `main` and pass the required checks
`ci-ok` and `security / report`; no force pushes, no deletion, no bypass. So
every commit on `main` is green, and `release-image.yml` only checks that the
tagged commit is on `main`. `ci-ok` is a small job at the end of the caller's
`ci.yml` that succeeds only when every other job in it succeeded (see
[templates/workflows/ci-go.yml](templates/workflows/ci-go.yml)).

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
  change and weekly. The fixtures plant one finding per scanner (a fake key,
  a reachable call into a vulnerable `golang.org/x/text`, a secret written to
  the console, a root container on an outdated base image, an unpinned action,
  a failing test); the self-test is green only when each one is reported and
  the clean fixture passes with every `fail-on` category set. Alerts that
  GitHub raises for the fixtures are expected.
- **Releases.** Callers use the moving tag `v1`. Move it only to a commit
  whose self-test is green:
  `git tag -f v1 <sha> && git push -f origin v1`. Breaking input changes get
  `v2`.
- **Report script.** `python3 -I scripts/test_sarif_summary.py` tests the
  categories, `fail-on`, VEX expiry and the code-scanning copy.
