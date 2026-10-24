#!/usr/bin/env bash
# Release decisions shared by release-intent.yml and release-image.yml, run
# from the repository root of a full checkout (history and tags).
#
#   release.sh version <file> [<rev>]
#       print the version in <file>: a package.json's `version`, otherwise the
#       file's content without whitespace. With <rev> the file is read at that
#       commit; a file missing there prints nothing.
#
#   release.sh intent
#       the release intent of a pull request into main. Env: VERSION_FILE,
#       TAG_PREFIX, BASE_SHA, HEAD_SHA, TITLE. The version file decides:
#         release      the version rises; the title is `release <name> <tag>`
#                      (just release-patch|minor|major)
#         no-release   the version is unchanged (just merge); any title except
#                      one that reads like a release
#       anything else fails. Writes kind= (and tag= for a release) to GITHUB_OUTPUT.
#
#   release.sh mode
#       what a run of release-image.yml does. Env: VERSION_FILE, TAG_PREFIX,
#       EVENT, REF, REF_TYPE, REF_NAME, RELEASE_BRANCH, COMMIT_TITLE, SHA.
#         tag       a pushed version tag (the flow before releases on merge)
#         release   a push to the release branch whose commit is a release
#                   PR's squash merge: title `release <name> <tag>`, tag not
#                   set yet
#         released  the same, but the tag is already on this commit: a re-run
#                   after a complete release, nothing left to do
#         dry-run   anything else: build, push nothing
#       Writes mode= and tag= to GITHUB_OUTPUT.
#
#   release.sh tag
#       set the annotated tag of a release through the GitHub API. Env: TAG,
#       SHA, MESSAGE, REPO, GH_TOKEN. A tag already on SHA passes (re-run); a
#       tag on another commit fails.
set -euo pipefail

out() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "$1" >> "$GITHUB_OUTPUT"; fi
}

# version <file> [<rev>]
version() {
  local file=$1 rev=${2:-} content
  if [ -n "$rev" ]; then
    content=$(git show "$rev:$file" 2>/dev/null) || return 0
  else
    content=$(cat "$file")
  fi
  case "$file" in
    package.json | */package.json) jq -r '.version // empty' <<<"$content" ;;
    *) tr -d '[:space:]' <<<"$content" ;;
  esac
}

# higher <a> <b>: a is a higher version than b (version sort; b may be empty)
higher() {
  [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" = "$1" ]
}

intent() {
  local base head tag
  base=$(version "$VERSION_FILE" "$BASE_SHA")
  head=$(version "$VERSION_FILE" "$HEAD_SHA")
  [ -n "$head" ] || { echo "::error::$VERSION_FILE has no version at $HEAD_SHA"; return 1; }

  if [ "$head" = "$base" ]; then
    # The squash merge carries this title, and release.yml starts on a merge
    # whose message starts with 'release ' (GitHub compares case-insensitively).
    # shellcheck disable=SC2153 # TITLE comes from the environment (see the header)
    if [[ "$(printf '%s' "$TITLE" | tr '[:upper:]' '[:lower:]')" == "release "* ]]; then
      echo "::error::the title starts with 'release ', but $VERSION_FILE is unchanged ($head): bump it (just release-patch) or retitle the pull request"
      return 1
    fi
    echo "no-release pull request (version unchanged): merging it releases nothing"
    out kind=no-release
    return 0
  fi

  if ! higher "$head" "$base"; then
    echo "::error::the version must rise: $VERSION_FILE goes from $base to $head"
    return 1
  fi
  tag="${TAG_PREFIX}${head}"
  if ! [[ "$TITLE" =~ ^release\ [^\ ]+\ (.+)$ ]] || [ "${BASH_REMATCH[1]}" != "$tag" ]; then
    echo "::error::a release pull request is titled 'release <name> $tag' (just release-patch), got '$TITLE'"
    return 1
  fi
  echo "release pull request: merging it releases $tag"
  out kind=release
  out "tag=$tag"
}

mode() {
  local v tag title
  v=$(version "$VERSION_FILE")
  [ -n "$v" ] || { echo "::error::$VERSION_FILE is empty"; return 1; }
  tag="${TAG_PREFIX}${v}"
  out "tag=$tag"

  if [ "$REF_TYPE" = tag ]; then
    if [ "$REF_NAME" != "$tag" ]; then
      echo "::error::tag $REF_NAME does not match $VERSION_FILE ($tag)"
      return 1
    fi
    echo "release $tag from its tag"
    out mode=tag
    return 0
  fi

  if [ "$EVENT" = push ] && [ "$REF" = "refs/heads/$RELEASE_BRANCH" ]; then
    # The squash merge of a release pull request: `release <name> <tag> (#n)`.
    title=$(head -n1 <<<"$COMMIT_TITLE")
    title=${title% (#*)}
    if ! [[ "$title" =~ ^release\ [^\ ]+\ (.+)$ ]]; then
      echo "::error::'$title' is not the merge of a release pull request: nothing to release"
      return 1
    fi
    if [ "${BASH_REMATCH[1]}" != "$tag" ]; then
      echo "::error::the merged release pull request names ${BASH_REMATCH[1]}, but $VERSION_FILE holds $tag"
      return 1
    fi
    if git rev-parse --quiet --verify "refs/tags/$tag" >/dev/null; then
      if [ "$(git rev-parse "$tag^{commit}")" = "$SHA" ]; then
        echo "::notice::$tag is already released from this commit: nothing to do"
        out mode=released
        return 0
      fi
      echo "::error::$tag is already released from another commit"
      return 1
    fi
    echo "release $tag from $RELEASE_BRANCH"
    out mode=release
    return 0
  fi

  echo "::notice::dry run on $EVENT $REF: builds $tag, pushes nothing"
  out mode=dry-run
}

tag() {
  local existing object
  if existing=$(gh api "repos/$REPO/git/ref/tags/$TAG" --jq '.object.type + " " + .object.sha' 2>/dev/null); then
    object=${existing#* }
    if [ "${existing%% *}" = tag ]; then
      object=$(gh api "repos/$REPO/git/tags/$object" --jq .object.sha)
    fi
    if [ "$object" = "$SHA" ]; then
      echo "$TAG is already on $SHA"
      return 0
    fi
    echo "::error::$TAG exists on $object, not on $SHA"
    return 1
  fi
  object=$(gh api "repos/$REPO/git/tags" -f tag="$TAG" -f message="$MESSAGE" \
    -f object="$SHA" -f type=commit --jq .sha)
  gh api "repos/$REPO/git/refs" -f ref="refs/tags/$TAG" -f sha="$object" >/dev/null
  echo "tagged $TAG on $SHA"
}

case "${1:-}" in
  version) version "$2" "${3:-}" ;;
  intent) intent ;;
  mode) mode ;;
  tag) tag ;;
  *) echo "usage: release.sh version <file> [<rev>] | intent | mode | tag" >&2; exit 2 ;;
esac
