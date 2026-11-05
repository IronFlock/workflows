#!/usr/bin/env bash
# Tests of sign-provenance.sh check against a BuildKit SLSA v1 predicate:
#   bash scripts/test_sign_provenance.sh
# Signing itself (cosign, a registry) is exercised by selftest.yml's
# provenance-sign job.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
script="$here/sign-provenance.sh"
fixture="$here/../tests/fixtures/provenance/predicate.json"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

export EXPECT_SOURCE=https://github.com/IronFlock/example
export EXPECT_REVISION=0123456789abcdef0123456789abcdef01234567
export EXPECT_RUN=https://github.com/IronFlock/example/actions/runs/123

check() { # check <name> <expected exit: 0|1> <jq edit of the fixture> [<platform>]
  local name=$1 want=$2 edit=$3 platform=${4:-linux/amd64} got=0
  jq "$edit" "$fixture" >"$work/predicate.json"
  bash "$script" check "$work/predicate.json" "$platform" >"$work/log" 2>&1 || got=$?
  if { [ "$want" = 0 ] && [ "$got" = 0 ]; } || { [ "$want" = 1 ] && [ "$got" != 0 ]; }; then
    echo "ok   $name"
  else
    echo "FAIL $name (exit $got, wanted $want)"
    sed 's/^/     /' "$work/log"
    failures=$((failures + 1))
  fi
}

check "this run's build of this commit" 0 .
check "a re-run attempt of this run" 0 '.runDetails.builder.id = "https://github.com/IronFlock/example/actions/runs/123/attempts/2"'
check "source without .git" 0 '.runDetails.metadata.buildkit_metadata.vcs.source = "https://github.com/IronFlock/example"'
check "a variant platform" 0 '.buildDefinition.internalParameters.targetPlatform = "linux/arm/v7"' linux/arm/v7

check "another platform's provenance" 1 . linux/arm64
check "another run" 1 '.runDetails.builder.id = "https://github.com/IronFlock/example/actions/runs/1234/attempts/1"'
check "another repository's run" 1 '.runDetails.builder.id = "https://github.com/IronFlock/other/actions/runs/123/attempts/1"'
check "a builder id with more after the attempt" 1 '.runDetails.builder.id = "https://github.com/IronFlock/example/actions/runs/123/attempts/1/x"'
check "no builder id" 1 '.runDetails.builder.id = ""'
check "uncommitted changes in the build context" 1 '.runDetails.metadata.buildkit_metadata.vcs.revision += "-dirty"'
check "another commit" 1 '.runDetails.metadata.buildkit_metadata.vcs.revision = "fedcba9876543210fedcba9876543210fedcba98"'
check "no vcs information" 1 'del(.runDetails.metadata.buildkit_metadata.vcs)'
check "another repository" 1 '.runDetails.metadata.buildkit_metadata.vcs.source = "https://github.com/IronFlock/example-fork.git"'
check "SLSA v0.2 provenance" 1 '{buildType: "https://mobyproject.org/buildkit@v1", builder: {id: .runDetails.builder.id}}'
check "not JSON" 1 '"not a predicate"'

if [ "$failures" -gt 0 ]; then
  echo "$failures failed"
  exit 1
fi
echo "all passed"
