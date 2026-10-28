#!/usr/bin/env bash
# Publishes the harness: the logic behind `just release-patch|minor|major` in
# this repository. Every repository uses the harness at the moving tag v<major>
# (callers `uses: ...@v1`, Justfiles fetch scripts/pr.sh at v1), so a change
# reaches them when that tag moves.
#
#   publish.sh <patch|minor|major>
#       On a feature branch: opens its pull request (pr.sh merge; the harness
#       has no version file), waits for the self-test and the merge, goes back
#       to main and publishes that merge commit. On an up-to-date main:
#       publishes HEAD, the merge commit of the newest pull request.
#
#       Publishing tags the commit with the next version v<major>.<minor>.<patch>
#       (the last one on origin, or v1.0.0 before the first) and moves
#       v<major> to it: v1 for patch and minor; for major a new v<major+1>,
#       while the old one stays where it is until every caller has moved. Only
#       the merge commit of a pull request whose checks are green. Asks before
#       it pushes (PUBLISH_YES=1 answers yes); prints how to roll back.
#
# Running it again after a run whose wait broke off is safe: pr.sh leaves the
# merged branch for main, and the newest merge is published from there.
#
# Env: PR_WAIT_SECONDS (default 20) between polls.
# Rollback: git tag -f v<major> <previous commit> && git push -f origin v<major>
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
wait_s=${PR_WAIT_SECONDS:-20}

die() { echo "publish: $*" >&2; exit 1; }

# Waits for the merge of the branch's pull request; prints "<merge commit> <head commit>".
await_merged() { # await_merged <branch>
  local out misses=0
  echo "==> waiting for the self-test and the merge of $1" >&2
  for _ in $(seq 1 120); do
    if out=$(gh pr view "$1" --json state,mergeCommit,headRefOid \
      --jq '"\(.state) \(.mergeCommit.oid // "") \(.headRefOid)"' 2>/dev/null); then
      misses=0
      case "$out" in
        "MERGED "[0-9a-f]*) echo "${out#MERGED }"; return 0 ;;
        CLOSED*) die "the pull request of $1 was closed without merging: nothing published" ;;
      esac
    else
      misses=$((misses + 1))
      [ "$misses" -lt 10 ] ||
        die "lost the connection to GitHub while waiting for the merge of $1. The pull request still merges by itself: run this again to publish it."
    fi
    sleep "$wait_s"
  done
  die "the pull request of $1 is not merged after 40 minutes: gh pr checks $1"
}

# Tags <sha> with the next version and moves v<major> there.
publish_commit() { # publish_commit <level> <sha>
  local level=$1 sha=$2 released pr last major minor patch next moving old answer
  git fetch --quiet --force --tags origin
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
}

level=${1:-}
case "$level" in
  patch | minor | major) ;;
  *) die "usage: publish.sh <patch|minor|major>" ;;
esac
[ -z "$(git status --porcelain)" ] || die "uncommitted changes: commit them first, with a message describing the work"

branch=$(git rev-parse --abbrev-ref HEAD)
[ "$branch" != HEAD ] || die "HEAD is detached: switch to your feature branch, or to main"
if [ "$branch" != main ]; then
  # The pull request (or, when it is merged already, back to main), as `just merge`.
  bash "$here/pr.sh" merge -
  if [ "$(git rev-parse --abbrev-ref HEAD)" = "$branch" ]; then
    merged=$(await_merged "$branch")
    read -r sha head <<<"$merged"
    git fetch --quiet origin main
    if git merge-base --is-ancestor main origin/main 2>/dev/null && git switch --quiet main 2>/dev/null; then
      git merge --quiet --ff-only origin/main
    else
      git switch --quiet --detach origin/main
      echo "==> continuing detached on origin/main; the local main is left as it is"
    fi
    # Only a branch the pull request holds entirely.
    if [ "$(git rev-parse -q --verify "refs/heads/$branch")" = "$head" ]; then
      git branch -D "$branch" >/dev/null
    else
      echo "==> $branch keeps commits pushed after its pull request: left as it is"
    fi
    publish_commit "$level" "$sha"
    exit 0
  fi
fi

# On main: its HEAD, the merge commit of the newest pull request.
git fetch --quiet origin main
[ "$(git rev-parse --abbrev-ref HEAD)" = main ] ||
  die "the local main cannot follow origin/main (it holds commits origin/main lacks): see git log origin/main..main"
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] ||
  die "main is not origin/main: git pull --ff-only (local commits reach main through just merge)"
publish_commit "$level" "$(git rev-parse HEAD)"
