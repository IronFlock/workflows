#!/usr/bin/env bash
# Signed SLSA provenance of a released image, run by release-image.yml's
# publish job: the only job of a release that runs no code of the repository
# being released.
#
#   sign-provenance.sh sign <image>@<index digest>
#       For every platform image of the multi-arch index: take the SLSA v1
#       provenance BuildKit attached at build time, `check` that it describes
#       this run's build of this commit, and attach it to the index as an
#       in-toto attestation signed with COSIGN_KEY (cosign, without
#       transparency log or timestamp service: nothing about the image leaves
#       the registry). A platform whose signed provenance is already attached
#       is skipped, so a re-run never signs twice. Afterwards the signed
#       provenance of every platform must verify with the same key.
#       Env: COSIGN_KEY (a KMS URI such as gcpkms://..., or a key file for
#       tests), EXPECT_SOURCE, EXPECT_REVISION, EXPECT_RUN (see check).
#       Optional: COSIGN_PUBLIC_KEY (what verifies: default COSIGN_KEY, as a
#       KMS URI does both; a test's key file needs its .pub), COSIGN (the
#       binary, default cosign), COSIGN_ALLOW_HTTP=1 (a plain-HTTP test
#       registry). Registry credentials: docker login.
#
#   sign-provenance.sh check <predicate.json> <platform>
#       the predicate is BuildKit's SLSA v1 provenance of <platform>, built by
#       run EXPECT_RUN (its URL; builder id <run URL>/attempts/<n>, any
#       attempt) from the clean checkout of EXPECT_REVISION of repository
#       EXPECT_SOURCE (a trailing .git aside).
#
# Each attestation names its platform (predicate.buildDefinition
# .internalParameters.targetPlatform). Verify a released image with the
# public key (`cosign public-key --key <KMS URI>` prints it):
#   cosign verify-attestation --key provenance.pub --type slsaprovenance1 \
#     --insecure-ignore-tlog <image>@<index digest>
set -euo pipefail

BUILDKIT_SLSA_V1=https://github.com/moby/buildkit/blob/master/docs/attestations/slsa-definitions.md

check() {
  local file=$1 platform=$2 btype target builder revision source attempt
  : "${EXPECT_SOURCE:?}" "${EXPECT_REVISION:?}" "${EXPECT_RUN:?}"
  IFS=$'\t' read -r btype target builder revision source < <(jq -r '[
      .buildDefinition.buildType,
      .buildDefinition.internalParameters.targetPlatform,
      .runDetails.builder.id,
      .runDetails.metadata.buildkit_metadata.vcs.revision,
      .runDetails.metadata.buildkit_metadata.vcs.source
    ] | map(if . == null or . == "" then "-" else . end) | @tsv' "$file")
  if [ "$btype" != "$BUILDKIT_SLSA_V1" ]; then
    echo "::error::the provenance of $platform is not BuildKit's SLSA v1 provenance (buildType $btype)"
    return 1
  fi
  if [ "$target" != "$platform" ]; then
    echo "::error::the provenance attached for $platform describes a build for $target"
    return 1
  fi
  attempt=${builder#"$EXPECT_RUN/attempts/"}
  if [ "$attempt" = "$builder" ] || ! [[ "$attempt" =~ ^[0-9]+$ ]]; then
    echo "::error::the provenance of $platform was built by $builder, not by this run ($EXPECT_RUN)"
    return 1
  fi
  if [ "$revision" != "$EXPECT_REVISION" ]; then
    echo "::error::the provenance of $platform names revision $revision, not $EXPECT_REVISION (a -dirty revision: the build context had uncommitted changes)"
    return 1
  fi
  if [ "${source%.git}" != "${EXPECT_SOURCE%.git}" ]; then
    echo "::error::the provenance of $platform names source $source, not $EXPECT_SOURCE"
    return 1
  fi
}

# signed <ref> <digest> <log>: the platforms whose signed provenance on <ref>
# (for subject <digest>) verifies with the public key, one per line; cosign's
# messages go to <log> (none attached yet is an error to cosign, too)
signed() {
  local ref=$1 digest=$2 log=$3
  { "$COSIGN" verify-attestation "${registry_flags[@]}" --key "${COSIGN_PUBLIC_KEY:-$COSIGN_KEY}" \
      --type slsaprovenance1 --insecure-ignore-tlog "$ref" 2>"$log" || true; } |
    jq -r --arg d "${digest#sha256:}" '.payload | @base64d | fromjson
      | select(any(.subject[]?; .digest.sha256 == $d))
      | .predicate.buildDefinition.internalParameters.targetPlatform // empty' |
    sort -u
}

sign() {
  local ref=$1 image digest work platforms provenance platform have missing=0
  : "${COSIGN_KEY:?}"
  image=${ref%@*}
  digest=${ref##*@}
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "::error::sign-provenance: want <image>@sha256:<digest>, got $ref" >&2; return 2; }
  work=$(mktemp -d)
  trap 'rm -rf "$work"' RETURN

  platforms=$(docker buildx imagetools inspect "$ref" --raw | jq -r '.manifests[]
    | select(.annotations["vnd.docker.reference.type"] != "attestation-manifest")
    | .platform | "\(.os)/\(.architecture)\(if .variant then "/" + .variant else "" end)"')
  [ -n "$platforms" ] || { echo "::error::$ref is not a multi-arch index with platform images"; return 1; }
  provenance=$(docker buildx imagetools inspect "$ref" --format '{{json .Provenance}}')
  have=$(signed "$ref" "$digest" "$work/verify.log")

  # No transparency log, no timestamp service: an empty signing config.
  "$COSIGN" signing-config create --out "$work/no-services.json" >/dev/null

  while read -r platform; do
    if grep -qxF -- "$platform" <<<"$have"; then
      echo "$platform: signed provenance already attached"
      continue
    fi
    jq --arg p "$platform" --argjson n "$(wc -l <<<"$platforms")" \
      'if has("SLSA") and $n == 1 then .SLSA else .[$p].SLSA end // empty' <<<"$provenance" >"$work/predicate.json"
    if [ ! -s "$work/predicate.json" ]; then
      echo "::error::$image has no BuildKit provenance for $platform (built without --provenance?)"
      return 1
    fi
    check "$work/predicate.json" "$platform"
    "$COSIGN" attest --yes "${registry_flags[@]}" --key "$COSIGN_KEY" \
      --signing-config "$work/no-services.json" \
      --type slsaprovenance1 --predicate "$work/predicate.json" "$ref" >/dev/null
    echo "$platform: provenance signed and attached"
  done <<<"$platforms"

  have=$(signed "$ref" "$digest" "$work/verify.log")
  while read -r platform; do
    grep -qxF -- "$platform" <<<"$have" || { echo "::error::no signed provenance of $platform verifies on $ref"; missing=1; }
  done <<<"$platforms"
  if [ "$missing" != 0 ]; then
    echo "cosign verify-attestation said:"
    sed 's/^/  /' "$work/verify.log"
  fi
  return "$missing"
}

COSIGN=${COSIGN:-cosign}
registry_flags=()
if [ "${COSIGN_ALLOW_HTTP:-}" = 1 ]; then registry_flags=(--allow-http-registry); fi

case "${1:-}" in
  check) check "$2" "$3" ;;
  sign) sign "$2" ;;
  *) echo "usage: sign-provenance.sh sign <image>@<digest> | check <predicate.json> <platform>" >&2; exit 2 ;;
esac
