#!/usr/bin/env bash
# Publishes the harness: the logic behind `just release-patch|minor|major` in
# this repository. Every repository uses the harness at the moving tag v<major>
# (callers `uses: ...@v1`, Justfiles fetch scripts/pr.sh at v1), so a change
# reaches them when that tag moves. Run on an up-to-date main whose HEAD is the
# merge commit of a pull request with all checks green.
#
#   publish.sh <patch|minor|major>
#       tags HEAD with the next version v<major>.<minor>.<patch> (the last one
#       on origin, or v1.0.0 before the first) and moves v<major> to it: v1 for
#       patch and minor; for major a new v<major+1>, while the old one stays
#       where it is until every caller has moved. Asks before it pushes
#       (PUBLISH_YES=1 answers yes); prints how to roll back.
#
# Rollback: git tag -f v<major> <previous commit> && git push -f origin v<major>
set -euo pipefail

die() { echo "publish: $*" >&2; exit 1; }

level=${1:-}
case "$level" in
  patch | minor | major) ;;
  *) die "usage: publish.sh <patch|minor|major>" ;;
esac

[ -z "$(git status --porcelain)" ] || die "uncommitted changes: a change reaches main through just merge"
[ "$(git rev-parse --abbrev-ref HEAD)" = main ] ||
  die "run on main: git switch main; git pull --ff-only (a change reaches main through just merge)"
git fetch --quiet --force --tags origin
git fetch --quiet origin main
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] ||
  die "main is not origin/main: git pull --ff-only (local commits reach main through just merge)"
sha=$(git rev-parse HEAD)

released=$(git tag --points-at "$sha" -l 'v[0-9]*.[0-9]*.[0-9]*' | sort -V | tail -n1)
[ -z "$released" ] || die "$(git rev-parse --short "$sha") is published already, as $released"

# Only the merge commit of a pull request whose checks (the self-test) are green.
pr=$(gh api "repos/{owner}/{repo}/commits/$sha/pulls" \
  --jq '[.[] | select(.merged_at != null)][0].number // empty') ||
  die "cannot ask GitHub which pull request made $(git rev-parse --short "$sha") (gh api failed)"
[ -n "$pr" ] || die "$(git rev-parse --short "$sha") is not the merge commit of a pull request: only those are published"
gh pr checks "$pr" >/dev/null 2>&1 ||
  die "the checks of #$pr are not all green: gh pr checks $pr"

last=$(git tag -l 'v[0-9]*.[0-9]*.[0-9]*' | sort -V | tail -n1)
IFS=. read -r major minor patch <<<"${last:-v1.0.0}"
major=${major#v}
case "$level" in
  patch) next="v$major.$minor.$((patch + 1))" ;;
  minor) next="v$major.$((minor + 1)).0" ;;
  major) next="v$((major + 1)).0.0" ;;
esac
moving=${next%%.*}
old=$(git rev-parse -q --verify "refs/tags/$moving^{commit}" || true)

echo "==> publish $next: #$pr, $(git log -1 --format='%h %s' "$sha")"
if [ -n "$old" ]; then
  echo "    $moving moves from $(git rev-parse --short "$old") to $(git rev-parse --short "$sha"); every repository's next CI run and just merge|release-* use it"
else
  echo "    new tag $moving at $(git rev-parse --short "$sha"); repositories use it once their callers say @$moving"
fi
if [ "${PUBLISH_YES:-}" != 1 ]; then
  [ -t 0 ] || die "confirm interactively, or set PUBLISH_YES=1"
  read -r -p "Publish? [y/N] " answer
  case "$answer" in y | Y | yes) ;; *) die "not published" ;; esac
fi

git tag -a "$next" -m "workflows $next (#$pr)" "$sha"
git push --quiet origin "refs/tags/$next"
git tag -f "$moving" "$sha" >/dev/null
git push --quiet --force origin "refs/tags/$moving"
echo "==> published $next; $moving is at $(git rev-parse --short "$sha")"
if [ -n "$old" ]; then
  echo "    roll back: git tag -f $moving $old && git push -f origin $moving"
fi
