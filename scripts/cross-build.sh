#!/usr/bin/env bash
# Cross-compile every package below a Go module for one target, discarding the output.
#   cross-build.sh <module-dir> <GOOS/GOARCH[/GOARM]>
set -euo pipefail

dir=$1
target=$2
IFS=/ read -r goos goarch goarm <<<"$target"
[ -n "$goos" ] && [ -n "$goarch" ] || { echo "cross-build: bad target '$target'" >&2; exit 2; }

out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

export CGO_ENABLED=0 GOOS="$goos" GOARCH="$goarch"
if [ -n "${goarm:-}" ]; then
  export GOARM="$goarm"
fi
cd "$dir"
# A trailing slash makes -o a directory, which works for one or many main packages.
go build -o "$out/" ./...
echo "built $target"
