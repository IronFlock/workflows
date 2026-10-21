#!/usr/bin/env bash
# Run gitleaks and write a redacted SARIF report. Never fails on findings;
# the report job decides.
#   gitleaks-scan.sh <mode> <path> <out.sarif>
# mode: auto  pull_request -> commits of the PR; push -> pushed commits;
#             anything else (schedule, dispatch) -> the files at HEAD
#       dir   the files under <path>
# Optional env: GITLEAKS_CONFIG, GITLEAKS_BASELINE (used when the file exists),
# EVENT_NAME, BASE_SHA, HEAD_SHA, BEFORE_SHA.
set -euo pipefail

mode=$1
path=$2
out=$3

args=(--no-banner --redact --exit-code 0 --report-format sarif --report-path "$out")
if [ -n "${GITLEAKS_CONFIG:-}" ] && [ -f "$GITLEAKS_CONFIG" ]; then
  args+=(--config "$GITLEAKS_CONFIG")
fi
if [ -n "${GITLEAKS_BASELINE:-}" ] && [ -f "$GITLEAKS_BASELINE" ]; then
  args+=(--baseline-path "$GITLEAKS_BASELINE")
fi

range=""
if [ "$mode" = auto ]; then
  case "${EVENT_NAME:-}" in
    pull_request) range="${BASE_SHA}..${HEAD_SHA}" ;;
    push)
      if [ -n "${BEFORE_SHA:-}" ] && [ "${BEFORE_SHA}" != 0000000000000000000000000000000000000000 ] &&
        git cat-file -e "${BEFORE_SHA}^{commit}" 2>/dev/null; then
        range="${BEFORE_SHA}..${HEAD_SHA}"
      fi
      ;;
  esac
fi

if [ -n "$range" ]; then
  echo "gitleaks: commits $range"
  gitleaks git "${args[@]}" --log-opts="$range" .
else
  echo "gitleaks: files under $path"
  gitleaks dir "${args[@]}" "$path"
fi
