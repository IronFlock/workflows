#!/usr/bin/env bash
# End-to-end test of sign-provenance.sh sign against a plain-HTTP registry,
# with throwaway cosign key files instead of the KMS key:
#   bash scripts/test_sign_provenance_registry.sh <registry host:port>
# Needs docker buildx (a builder that reaches the registry: BUILDX_BUILDER),
# emulation for the second platform, cosign on PATH (or COSIGN) and jq.
# selftest.yml's provenance-sign job runs it against a registry service.
set -euo pipefail

registry=${1:?usage: test_sign_provenance_registry.sh <registry host:port>}
here=$(cd "$(dirname "$0")" && pwd)
script="$here/sign-provenance.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0
export COSIGN=${COSIGN:-cosign} COSIGN_ALLOW_HTTP=1 COSIGN_PASSWORD=selftest

expect() { # expect <name> <expected exit: 0|1> <command...>
  local name=$1 want=$2 got=0
  shift 2
  "$@" >"$work/log" 2>&1 || got=$?
  if { [ "$want" = 0 ] && [ "$got" = 0 ]; } || { [ "$want" = 1 ] && [ "$got" != 0 ]; }; then
    echo "ok   $name"
  else
    echo "FAIL $name (exit $got, wanted $want)"
    sed 's/^/     /' "$work/log"
    failures=$((failures + 1))
  fi
}

# attestations <ref> <public key>: how many signed provenance attestations
# on <ref> verify with the key
attestations() {
  { "$COSIGN" verify-attestation --allow-http-registry --key "$2" --type slsaprovenance1 \
      --insecure-ignore-tlog "$1" 2>/dev/null || true; } | grep -c . || true
}

# The build context: a clean git repository, so the provenance names a known
# source and revision.
src="$work/src"
mkdir -p "$src"
cp "$here/../tests/fixtures/release/Dockerfile" "$src/"
git -C "$src" init -q -b main
git -C "$src" config user.email t@example.invalid
git -C "$src" config user.name test
git -C "$src" add Dockerfile
git -C "$src" commit -qm fixture
git -C "$src" remote add origin https://github.com/IronFlock/selftest-provenance.git
run=https://github.com/IronFlock/selftest-provenance/actions/runs/1
image="$registry/selftest/provenance"

# build <platform>: push it by digest the way release-image.yml does; prints the digest
build() {
  docker buildx build --platform "$1" -f "$src/Dockerfile" --build-arg VERSION=v0.0.1 \
    --provenance="mode=max,version=v1,builder-id=$run/attempts/1" \
    --metadata-file "$work/metadata.json" \
    --output "type=image,name=$image,push-by-digest=true,name-canonical=true,push=true" \
    "$src" >"$work/build.log" 2>&1 || { cat "$work/build.log"; return 1; }
  jq -r '."containerimage.digest"' "$work/metadata.json"
}
amd64=$(build linux/amd64)
arm64=$(build linux/arm64)
docker buildx imagetools create -t "$image:v0.0.1" "$image@$amd64" "$image@$arm64" >/dev/null 2>&1
docker buildx imagetools create -t "$image:single" "$image@$amd64" >/dev/null 2>&1
index=$image@$(docker buildx imagetools inspect "$image:v0.0.1" --format '{{json .Manifest}}' | jq -r .digest)
single=$image@$(docker buildx imagetools inspect "$image:single" --format '{{json .Manifest}}' | jq -r .digest)

(cd "$work" && "$COSIGN" generate-key-pair --output-key-prefix release >/dev/null 2>&1)
(cd "$work" && "$COSIGN" generate-key-pair --output-key-prefix other >/dev/null 2>&1)
export COSIGN_KEY="$work/release.key" COSIGN_PUBLIC_KEY="$work/release.pub"
export EXPECT_SOURCE=https://github.com/IronFlock/selftest-provenance
export EXPECT_REVISION
EXPECT_REVISION=$(git -C "$src" rev-parse HEAD)
export EXPECT_RUN=$run

expect "another commit expected: refused" 1 env EXPECT_REVISION=fedcba9876543210fedcba9876543210fedcba98 bash "$script" sign "$index"
expect "  and nothing attached" 0 test "$(attestations "$index" "$work/release.pub")" = 0
expect "both platforms signed" 0 bash "$script" sign "$index"
expect "  two attestations verify" 0 test "$(attestations "$index" "$work/release.pub")" = 2
expect "  they name both platforms" 0 bash -c "\"$COSIGN\" verify-attestation --allow-http-registry --key '$work/release.pub' --type slsaprovenance1 --insecure-ignore-tlog '$index' 2>/dev/null | jq -r '.payload | @base64d | fromjson | .predicate.buildDefinition.internalParameters.targetPlatform' | sort | paste -sd, - | grep -qx linux/amd64,linux/arm64"
expect "  another key verifies none" 0 test "$(attestations "$index" "$work/other.pub")" = 0
expect "re-run signs nothing twice" 0 bash "$script" sign "$index"
expect "  still two attestations" 0 test "$(attestations "$index" "$work/release.pub")" = 2
expect "a single-platform index" 0 env COSIGN_KEY="$work/other.key" COSIGN_PUBLIC_KEY="$work/other.pub" bash "$script" sign "$single"
expect "  an attestation by another key does not count" 0 bash "$script" sign "$single"
expect "  one attestation verifies with each key" 0 test "$(attestations "$single" "$work/release.pub")$(attestations "$single" "$work/other.pub")" = 11
expect "not a digest reference" 1 bash "$script" sign "$image:v0.0.1"

if [ "$failures" -gt 0 ]; then
  echo "$failures failed"
  exit 1
fi
echo "all passed"
