#!/usr/bin/env bash
# tools.lock is well-formed and every tool has an arm64 entry at its version:
#   bash scripts/test_tools_lock.sh
set -euo pipefail
lock="$(cd "$(dirname "$0")/.." && pwd)/tools.lock"
fail=0
bad() {
  echo "tools.lock: $*" >&2
  fail=1
}

declare -A version
while read -r name ver sha url member extra; do
  case "$name" in '' | '#'*) continue ;; esac
  [ -n "$member" ] && [ -z "$extra" ] || bad "$name: want 5 fields"
  [[ "$sha" =~ ^[0-9a-f]{64}$ ]] || bad "$name: sha256 is not 64 hex digits"
  [[ "$url" == https://* ]] || bad "$name: url is not https"
  [ -z "${version[$name]+set}" ] || bad "$name is listed twice"
  version[$name]=$ver
done <"$lock"

for name in "${!version[@]}"; do
  case "$name" in
    */arm64)
      base=${name%/arm64}
      [ -n "${version[$base]+set}" ] || bad "$name has no x86_64 entry $base"
      [ "${version[$base]:-}" = "${version[$name]}" ] || bad "$name is ${version[$name]}, $base ${version[$base]:-missing}"
      ;;
    */*) bad "$name: the only architecture suffix is /arm64" ;;
    *) [ -n "${version[$name/arm64]+set}" ] || bad "$name has no $name/arm64 entry" ;;
  esac
done
[ "$fail" = 0 ] && echo "tools.lock: ${#version[@]} entries, every tool for x86_64 and arm64"
exit "$fail"
