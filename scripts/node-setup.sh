#!/usr/bin/env bash
# Node/Bun dependency handling for node-gate.yml, run from the package directory.
#   node-setup.sh check-lockfile <bun|npm>   the package manager's lockfile exists, no other one does
#   node-setup.sh install <bun|npm>          install exactly what the lockfile pins
set -euo pipefail

cmd=${1:-}
pm=${2:-}
case "$pm" in
  bun) own=(bun.lock); others=(bun.lockb package-lock.json yarn.lock pnpm-lock.yaml) ;;
  npm) own=(package-lock.json); others=(bun.lock bun.lockb yarn.lock pnpm-lock.yaml) ;;
  *) echo "node-setup: package manager must be bun or npm, got '$pm'" >&2; exit 2 ;;
esac

case "$cmd" in
  check-lockfile)
    rc=0
    for f in "${own[@]}"; do
      [ -f "$f" ] || { echo "::error::$f missing: $pm installs only from its lockfile"; rc=1; }
    done
    for f in "${others[@]}"; do
      [ -f "$f" ] && { echo "::error::$f present in a $pm repository: remove it (one lockfile, one package manager)"; rc=1; }
    done
    exit "$rc"
    ;;
  install)
    if [ "$pm" = bun ]; then
      bun install --frozen-lockfile
    else
      npm ci --no-audit --no-fund
    fi
    ;;
  *) echo "usage: node-setup.sh check-lockfile|install bun|npm" >&2; exit 2 ;;
esac
