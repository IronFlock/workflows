#!/usr/bin/env bash
# Run gitleaks and write a redacted SARIF report. Never fails on findings;
# the report job decides.
#   gitleaks-scan.sh <mode> <path> <out.sarif>
# mode: auto  pull_request -> commits of the PR; push -> pushed commits;
#             anything else (schedule, dispatch) -> the files at HEAD
#       dir   the files under <path>
# Optional env: GL_CONFIG, GL_BASELINE (used when the file exists; not named
# GITLEAKS_CONFIG because gitleaks reads that variable itself and fails when
# the file is missing),
# EVENT_NAME, BASE_SHA, HEAD_SHA, BEFORE_SHA.
set -euo pipefail

mode=$1
path=$2
out=$3

args=(--no-banner --redact --exit-code 0 --report-format sarif --report-path "$out")
if [ -n "${GL_CONFIG:-}" ] && [ -f "$GL_CONFIG" ]; then
  args+=(--config "$GL_CONFIG")
fi
if [ -n "${GL_BASELINE:-}" ] && [ -f "$GL_BASELINE" ]; then
  args+=(--baseline-path "$GL_BASELINE")
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
