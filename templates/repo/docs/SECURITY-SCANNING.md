# Security scanning

This repository runs the shared IronFlock CI harness
([IronFlock/workflows](https://github.com/IronFlock/workflows)):

| Check | What it covers | When |
|---|---|---|
| `ci / gate` | lint, unit tests, build (`just lint`, `just test`, `just build`) | every PR and push to `main` |
| `ci / workflows` | actionlint, zizmor, pinned actions in `.github/workflows` | every PR and push to `main` |
| `security / security` | secrets (gitleaks), dependencies (govulncheck / osv-scanner), SAST (semgrep), Dockerfile/Helm configuration (trivy), licences, SBOM, container image (trivy) | every PR, push to `main`, weekly |

**Scope:** SCOPE — describe what this repository ships (binary, image, chart) and what is out
of scope.

**Gating:** STATUS — report-only until DATE, then blocking on secrets, fixable high/critical
vulnerabilities, high misconfigurations, forbidden licences and semgrep errors.

**Exceptions** need a reason and an expiry and are reviewed in the PR that adds them:
`security/vex.openvex.json` (vulnerabilities that do not affect this code, valid 12 months),
`.trivyignore.yaml` (`expired_at` required), `.gitleaks.toml` (reviewed false positives).

Run the same checks locally with `just lint test`; the scanners run in CI only.
