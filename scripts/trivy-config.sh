#!/usr/bin/env bash
# Run the trivy misconfiguration scan (Dockerfile, Kubernetes, Helm) and write
# a SARIF report. Never fails on findings; the report job decides. Fails when
# trivy skipped a Helm chart: a chart it cannot load (a dependency missing from
# charts/, a required value without a default) is skipped with a warning,
# subcharts included, and the report would look clean.
#   trivy-config.sh <path> <out.sarif>
# Optional env: TRIVYIGNORE (used when the file exists).
set -euo pipefail

path=$1
out=$2

args=(--format sarif --output "$out")
if [ -n "${TRIVYIGNORE:-}" ] && [ -f "$TRIVYIGNORE" ]; then
  args+=(--ignorefile "$TRIVYIGNORE")
fi

# Not --quiet: a skipped chart shows only in the log.
log=$(mktemp)
trap 'rm -f "$log"' EXIT
status=0
trivy config "${args[@]}" "$path" 2>"$log" || status=$?
cat "$log" >&2
[ "$status" -eq 0 ] || exit "$status"

skipped=$(grep -F 'Skipping chart' "$log" | sed 's/.*Skipping chart[[:space:]]*//' || true)
if [ -n "$skipped" ]; then
  while IFS= read -r line; do
    echo "::error::trivy skipped a Helm chart, so the scan does not cover it or its subcharts: $line"
  done <<<"$skipped"
  echo "::error::Make the chart load for the scan: fetch its dependencies first (config-setup-recipe, e.g. helm dependency build) or set the values it requires (misconfiguration.helm.set in trivy.yaml)."
  exit 1
fi
