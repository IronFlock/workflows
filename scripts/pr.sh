#!/usr/bin/env bash
# Pull requests into main from a laptop: the logic behind `just merge` and
# `just release-patch|minor|major` in every repository. Run from the repository
# root; needs git, gh (logged in) and jq. The repository's Justfile fetches this
# script at IronFlock/workflows@v1 and runs it, so the flow is the same
# everywhere (see "Pull requests from a laptop" in the README).
#
#   pr.sh merge <version-file> [<title>]
#       a no-release pull request from the current feature branch (pushed even
#       if origin does not have it yet), titled <title> (default: the subject
#       of the branch's first commit), merged automatically (squash) once the
#       required checks pass. The version must equal main's, and the title must
#       not start with "release ": such a merge releases nothing.
#
#   pr.sh release <patch|minor|major> <name> <version-file> <workflow> <file>...
#       a release pull request. The next version is computed from the version
#       on origin/main (so a second run on the same branch does not bump twice)
#       and written by `just _write-version <version>`. Only the listed files
#       are committed, as `release <name> v<version>`, on top of the work of the
#       current feature branch, or on a new branch release/v<version> when run
#       on an up-to-date main. The pull request merges automatically once the
#       required checks pass; its merge starts <workflow> (the image and the
#       tag), and this waits for that run.
#
# Env: PR_WAIT_SECONDS (default 20) between polls.
set -euo pipefail

wait_s=${PR_WAIT_SECONDS:-20}

die() { echo "$*" >&2; exit 1; }

# version <file> [<rev>]: a package.json's `version`, otherwise the content
# without whitespace (same rule as release.sh).
version() {
  local content
  if [ -n "${2:-}" ]; then
    content=$(git show "$2:$1" 2>/dev/null) || return 0
  else
    content=$(cat "$1")
  fi
  if [ "$(basename "$1")" = package.json ]; then
    jq -r '.version // empty' <<<"$content"
  else
    tr -d '[:space:]' <<<"$content"
  fi
}

next_version() { # next_version <level> <x.y.z>
  local major minor patch
  IFS=. read -r major minor patch <<<"$2"
  case "$1" in
    patch) echo "$major.$minor.$((patch + 1))" ;;
    minor) echo "$major.$((minor + 1)).0" ;;
    major) echo "$((major + 1)).0.0" ;;
    *) die "level must be patch, minor or major, got '$1'" ;;
  esac
}

require_clean() {
  local dirty
  dirty=$(git status --porcelain)
  [ -z "$dirty" ] || die "uncommitted changes: commit them first, with a message describing the work
$dirty"
}

# The title is checked like release-intent.yml does: a title starting with
# "release " (any case) belongs to a release pull request.
release_title() {
  [[ "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" == "release "* ]]
}

open_pr() { # open_pr <branch>: number of the branch's open pull request, if any
  gh pr list --head "$1" --state open --json number --jq '.[0].number // empty'
}

await_merge() { # await_merge <branch>: waits up to 40 minutes
  local state=""
  echo "==> waiting for the required checks and the merge of $1"
  for _ in $(seq 1 120); do
    state=$(gh pr view "$1" --json state --jq .state)
    case "$state" in
      MERGED) return 0 ;;
      CLOSED) die "the pull request of $1 was closed without merging" ;;
    esac
    sleep "$wait_s"
  done
  die "the pull request of $1 is not merged after 40 minutes: gh pr checks $1"
}

# Back on main after the merge; in a worktree main is checked out elsewhere,
# so this continues detached on origin/main.
leave_branch() {
  git fetch --quiet origin main
  if git switch --quiet main 2>/dev/null; then
    git pull --quiet --ff-only
  else
    git switch --quiet --detach origin/main
  fi
  git branch -D "$1" >/dev/null 2>&1 || true
}

cmd_merge() {
  [ $# -ge 1 ] || die "usage: pr.sh merge <version-file> [<title>]"
  local vf=$1 title=${2:-} branch here there
  branch=$(git rev-parse --abbrev-ref HEAD)
  if [ "$branch" = main ] || [ "$branch" = HEAD ]; then
    die "merge: run on a feature branch"
  fi
  require_clean
  git fetch --quiet origin main
  git merge-base --is-ancestor origin/main HEAD ||
    die "merge: $branch does not contain origin/main (git rebase origin/main)"
  here=$(version "$vf")
  there=$(version "$vf" origin/main)
  [ "$here" = "$there" ] ||
    die "merge: $branch changes the version ($there -> $here): that is a release (just release-patch)"
  [ -n "$title" ] || title=$(git log --reverse --format=%s origin/main..HEAD | head -n1)
  [ -n "$title" ] || die "merge: no commits on $branch beyond main"
  if release_title "$title"; then
    die "merge: '$title' starts with 'release ' (the title of release pull requests); pass another title"
  fi
  git push --quiet -u origin "$branch"
  if [ -z "$(open_pr "$branch")" ]; then
    gh pr create --base main --head "$branch" --title "$title" \
      --body "Opened by \`just merge\`. Merged automatically once the required checks pass; the merge releases nothing."
  fi
  gh pr merge "$branch" --squash --auto --delete-branch
  echo "==> $title: merges automatically once the required checks pass"
}

cmd_release() {
  [ $# -ge 5 ] || die "usage: pr.sh release <patch|minor|major> <name> <version-file> <workflow> <file>..."
  local level=$1 name=$2 vf=$3 workflow=$4
  shift 4
  local base next tag title branch pr sha run
  require_clean
  git fetch --quiet origin main
  branch=$(git rev-parse --abbrev-ref HEAD)
  if [ "$branch" = main ]; then
    [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] ||
      die "release: main is not up to date (git pull --ff-only)"
  elif [ "$branch" = HEAD ] || ! git merge-base --is-ancestor origin/main HEAD; then
    die "release: run on main or on a branch that contains origin/main (git rebase origin/main)"
  fi

  base=$(version "$vf" origin/main)
  [ -n "$base" ] || die "release: $vf has no version on origin/main"
  next=$(next_version "$level" "$base")
  tag="v$next"
  title="release $name $tag"
  if [ "$(version "$vf")" != "$next" ]; then
    just _write-version "$next"
    [ "$(version "$vf")" = "$next" ] || die "release: just _write-version $next left $vf at $(version "$vf")"
  fi
  echo "==> $title (main has $base)"

  if [ "$branch" = main ]; then
    branch="release/$tag"
    git switch --quiet -c "$branch"
  fi
  pr=$(open_pr "$branch")
  # The title before the push: the checks that the push starts read it.
  if [ -n "$pr" ]; then
    gh pr edit "$pr" --title "$title" >/dev/null
  fi
  git add -- "$@"
  if ! git diff --cached --quiet; then
    git commit --quiet -m "$title"
  fi
  [ -z "$(git status --porcelain)" ] ||
    die "release: _write-version changed files outside the list ($*): $(git status --porcelain | tr '\n' ' ')"
  git push --quiet -u origin "$branch"
  if [ -z "$pr" ]; then
    gh pr create --base main --head "$branch" --title "$title" \
      --body "Opened by \`just release-$level\`. Merged automatically once the required checks pass; the merge publishes the release and sets the tag $tag."
  fi
  gh pr merge "$branch" --squash --auto --delete-branch
  await_merge "$branch"
  sha=$(gh pr view "$branch" --json mergeCommit --jq '.mergeCommit.oid')
  leave_branch "$branch"

  echo "==> waiting for the release run of $tag ($workflow on $sha)"
  run=""
  for _ in $(seq 1 30); do
    run=$(gh run list --workflow "$workflow" --commit "$sha" --json databaseId,event \
      --jq 'map(select(.event == "push")) | .[0].databaseId // empty')
    [ -n "$run" ] && break
    sleep 5
  done
  [ -n "$run" ] || die "no run of $workflow started for $sha: check GitHub Actions"
  gh run watch "$run" --exit-status --interval "$wait_s" >/dev/null ||
    die "the release run $run of $tag failed: gh run view $run --log-failed (a re-run is safe)"
  git fetch --quiet origin tag "$tag"
  echo "==> $tag published and tagged by CI (run $run)"
}

case "${1:-}" in
  merge) shift; cmd_merge "$@" ;;
  release) shift; cmd_release "$@" ;;
  *) die "usage: pr.sh merge|release ..." ;;
esac
