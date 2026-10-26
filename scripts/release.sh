#!/usr/bin/env bash
# Release decisions shared by release-intent.yml and release-image.yml, run
# from the repository root of a full checkout (history and tags).
#
#   release.sh version <file> [<rev>]
#       print the version in <file>: a package.json's `version`, a
#       pyproject.toml's `[project] version`, otherwise the file's content
#       without whitespace. With <rev> the file is read at that
#       commit; a file missing there prints nothing.
#
#   release.sh intent
#       the release intent of a pull request into main. Env: VERSION_FILE,
#       TAG_PREFIX, BASE_SHA, HEAD_SHA, TITLE, RELEASE_NAME (optional: one of
#       several release projects in the repository). The version file decides:
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
#
#   release.sh promote
#       fast-forward branch BRANCH to the released commit through the GitHub
#       API (e.g. the branch a hosting service deploys from). Env: BRANCH, SHA,
#       REPO, GH_TOKEN. A missing branch is created; a branch already on SHA
#       passes (re-run); a branch that SHA does not descend from fails (never a
#       force push).
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
    pyproject.toml | */pyproject.toml) awk '/^\[/ { p = ($0 ~ /^\[project\][[:space:]]*(#.*)?$/) } p && /^version[[:space:]]*=/ { sub(/^version[[:space:]]*=[[:space:]]*/, ""); sub(/[[:space:]]*#.*$/, ""); gsub(/["'"'"']/, ""); print; exit }' <<<"$content" ;;
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

  # Several release projects in one repository (RELEASE_NAME set per project):
  # a release title that names another project is a no-release for this one,
  # whose version must then stay as it is (one release per pull request).
  local lower named=""
  # shellcheck disable=SC2153 # TITLE comes from the environment (see the header)
  lower=$(printf '%s' "$TITLE" | tr '[:upper:]' '[:lower:]')
  if [ -n "${RELEASE_NAME:-}" ] && [[ "$lower" =~ ^release\ ([^\ ]+)\  ]]; then
    named=${BASH_REMATCH[1]}
  fi
  if [ -n "$named" ] && [ "$named" != "$RELEASE_NAME" ]; then
    if [ "$head" != "$base" ]; then
      echo "::error::$VERSION_FILE changes ($base -> $head), but the pull request releases $named: one release per pull request"
      return 1
    fi
    echo "a release of $named: $RELEASE_NAME releases nothing"
    out kind=no-release
    return 0
  fi

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
    if ! [[ "$title" =~ ^release\ ([^\ ]+)\ (.+)$ ]]; then
      echo "::error::'$title' is not the merge of a release pull request: nothing to release"
      return 1
    fi
    if [ -n "${RELEASE_NAME:-}" ] && [ "${BASH_REMATCH[1]}" != "$RELEASE_NAME" ]; then
      echo "::error::'$title' releases ${BASH_REMATCH[1]}, not $RELEASE_NAME"
      return 1
    fi
    if [ "${BASH_REMATCH[2]}" != "$tag" ]; then
      echo "::error::the merged release pull request names ${BASH_REMATCH[2]}, but $VERSION_FILE holds $tag"
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

promote() {
  local current status
  if ! current=$(gh api "repos/$REPO/git/ref/heads/$BRANCH" --jq .object.sha 2>/dev/null); then
    gh api "repos/$REPO/git/refs" -f ref="refs/heads/$BRANCH" -f sha="$SHA" >/dev/null
    echo "created $BRANCH on $SHA"
    return 0
  fi
  if [ "$current" = "$SHA" ]; then
    echo "$BRANCH is already on $SHA"
    return 0
  fi
  status=$(gh api "repos/$REPO/compare/$current...$SHA" --jq .status)
  if [ "$status" != ahead ]; then
    echo "::error::$BRANCH is on $current, which $SHA does not descend from ($status): not a fast-forward"
    return 1
  fi
  gh api "repos/$REPO/git/refs/heads/$BRANCH" -X PATCH -f sha="$SHA" -F force=false >/dev/null
  echo "moved $BRANCH from $current to $SHA"
}

case "${1:-}" in
  version) version "$2" "${3:-}" ;;
  intent) intent ;;
  mode) mode ;;
  tag) tag ;;
  promote) promote ;;
  *) echo "usage: release.sh version <file> [<rev>] | intent | mode | tag" >&2; exit 2 ;;
esac
