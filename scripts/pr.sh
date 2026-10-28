#!/usr/bin/env bash
# Pull requests into main from a laptop: the logic behind `just merge` and
# `just release-patch|minor|major` in every repository. Run from the repository
# root; needs git, gh (logged in) and jq. The repository's Justfile fetches this
# script at IronFlock/workflows@v1 and runs it, so the flow is the same
# everywhere (see "Pull requests from a laptop" in the README).
#
#   pr.sh merge <version-file[,version-file...]|-> [<title>]
#       a no-release pull request from the current feature branch (pushed even
#       if origin does not have it yet), titled <title> (default: the subject
#       of the branch's first commit), merged automatically (squash) once the
#       required checks pass. Every version must equal main's (several
#       comma-separated files: a repository with several release projects; `-`:
#       a repository without a version, whose main is the publication), and the
#       title must not start with "release ": such a merge releases nothing.
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
# Running either again after a run whose wait broke off (a dropped connection,
# Ctrl-C) is safe: a branch whose pull request is merged already (squash) is
# left for main, and a release follows the release run of its merged release
# pull request instead of releasing again, or releases main when the branch
# was merged without a release. Polls survive short outages. Every start that
# cannot work (gh not logged in, main behind or ahead of origin/main, a
# detached HEAD, a branch missing commits of origin/main) is refused, saying
# what to do.
#
# Env: PR_WAIT_SECONDS (default 20) between polls. TAG_PREFIX (default v when
# unset; e.g. db-v for one of several release projects in a repository, empty
# for bare-version tags) and WRITE_VERSION (default _write-version; the
# project's recipe).
set -euo pipefail

wait_s=${PR_WAIT_SECONDS:-20}

die() { echo "$*" >&2; exit 1; }

# gh, retried: from a laptop the connection to GitHub drops now and then
# ("connection refused"), which must not end a run that only waits. Prints the
# output of the first attempt that succeeds; fails after five.
gh_retry() {
  local attempt out
  for attempt in 1 2 3 4 5; do
    if out=$(gh "$@" 2>/dev/null); then
      printf '%s\n' "$out"
      return 0
    fi
    [ "$attempt" = 5 ] || sleep "$wait_s"
  done
  return 1
}

# gh must act as the person running this. An exported GH_TOKEN or GITHUB_TOKEN
# takes precedence over gh's own login, and a stale one fails every call (401).
require_gh() {
  local err exported=""
  err=$(gh api user --jq .login 2>&1 >/dev/null) && return 0
  [ -z "${GH_TOKEN:-}" ] || exported+=" GH_TOKEN"
  [ -z "${GITHUB_TOKEN:-}" ] || exported+=" GITHUB_TOKEN"
  if [ -n "$exported" ]; then
    die "gh cannot use GitHub: ${err:-no answer}
This shell exports$exported, which gh uses instead of its own login. Run: unset$exported; gh auth status; then this again."
  fi
  die "gh cannot use GitHub: ${err:-no answer}
Check gh auth status (gh auth login renews an expired login), then run this again."
}

# A release starts from main only when it is origin/main exactly.
check_main() { # check_main <level>
  local behind ahead
  read -r behind ahead < <(git rev-list --left-right --count origin/main...main)
  if [ "$behind" = 0 ] && [ "$ahead" = 0 ]; then return 0; fi
  [ "$ahead" != 0 ] ||
    die "release: main is $behind commit(s) behind origin/main. Run: git pull --ff-only; then this again."
  die "release: main has $ahead commit(s) that origin/main lacks:
$(git log --format='  %h %s' origin/main..main | head -n 5)
main is protected: they reach it only through a pull request. Move them onto a branch, put main back on origin/main, and release from the branch:
  git switch -c <topic>
  git branch -f main origin/main
  just release-$1"
}

# The current branch misses commits of origin/main: which, and how to take them.
lacks_main() { # lacks_main <command> <branch>
  die "$1: origin/main has $(git rev-list --count HEAD..origin/main) commit(s) that $2 lacks:
$(git log --format='  %h %s' HEAD..origin/main | head -n 5)
Run: git rebase origin/main (or git merge origin/main); then this again."
}

# merged_pr <branch>: "<number> <head commit> <merge commit> <title>" of the
# branch's merged pull request, if it has one.
merged_pr() {
  gh_retry pr list --head "$1" --state merged --limit 1 \
    --json number,title,headRefOid,mergeCommit \
    --jq '.[0] // empty | "\(.number) \(.headRefOid) \(.mergeCommit.oid) \(.title)"'
}

# The current branch lacks origin/main. Usually its pull request was merged
# (squash) already, by a run whose wait broke off: then this leaves the branch
# for main, when nothing on it is newer than that pull request, and prints
# "<number> <merge commit> <title>". Dies in every other case, saying why.
merged_branch() { # merged_branch <command> <branch>
  local info pr head sha title
  info=$(merged_pr "$2") || die "$1: cannot ask GitHub for the pull requests of $2 (gh pr list failed); run this again"
  [ -n "$info" ] || lacks_main "$1" "$2"
  read -r pr head sha title <<<"$info"
  [ "$(git rev-parse HEAD)" = "$head" ] ||
    die "$1: $2 was merged as #$pr ($title) and has commits since. Run: git rebase origin/main; then this again."
  leave_branch "$2" >&2
  echo "$pr $sha $title"
}

# version <file> [<rev>]: a package.json's `version`, a pyproject.toml's
# `[project] version`, otherwise the content without whitespace (same rule as
# release.sh).
version() {
  local content
  if [ -n "${2:-}" ]; then
    content=$(git show "$2:$1" 2>/dev/null) || return 0
  else
    content=$(cat "$1")
  fi
  case "$(basename "$1")" in
    package.json) jq -r '.version // empty' <<<"$content" ;;
    pyproject.toml) awk '/^\[/ { p = ($0 ~ /^\[project\][[:space:]]*(#.*)?$/) } p && /^version[[:space:]]*=/ { sub(/^version[[:space:]]*=[[:space:]]*/, ""); sub(/[[:space:]]*#.*$/, ""); gsub(/["'"'"']/, ""); print; exit }' <<<"$content" ;;
    *) tr -d '[:space:]' <<<"$content" ;;
  esac
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

# Auto-merge waits for the required checks only where a ruleset demands them;
# without any, GitHub merges at once, untested. So both commands refuse.
require_checks() {
  local n
  n=$(gh api 'repos/{owner}/{repo}/rules/branches/main' \
    --jq '[.[] | select(.type == "required_status_checks")] | length')
  [ "${n:-0}" -gt 0 ] ||
    die "main has no required checks: auto-merge would merge untested. Protect main first (a ruleset requiring ci-ok and security / report)."
}

open_pr() { # open_pr <branch>: number of the branch's open pull request, if any
  gh pr list --head "$1" --state open --json number --jq '.[0].number // empty'
}

await_merge() { # await_merge <branch>: waits up to 40 minutes
  local state="" misses=0
  echo "==> waiting for the required checks and the merge of $1"
  for _ in $(seq 1 120); do
    if state=$(gh pr view "$1" --json state --jq .state 2>/dev/null); then
      misses=0
      case "$state" in
        MERGED) return 0 ;;
        CLOSED) die "the pull request of $1 was closed without merging" ;;
      esac
    else
      misses=$((misses + 1))
      [ "$misses" -lt 10 ] ||
        die "lost the connection to GitHub while waiting for the merge of $1. The pull request still merges by itself, and its merge releases: run this again to follow it."
    fi
    sleep "$wait_s"
  done
  die "the pull request of $1 is not merged after 40 minutes: gh pr checks $1"
}

# Waits for the release run of <tag>, which the merge commit <sha> started, and
# fetches the tag.
await_release() { # await_release <workflow> <sha> <tag>
  local workflow=$1 sha=$2 tag=$3 run="" state tries=0
  echo "==> waiting for the release run of $tag ($workflow on $sha)"
  for _ in $(seq 1 30); do
    run=$(gh_retry run list --workflow "$workflow" --commit "$sha" --json databaseId,event \
      --jq 'map(select(.event == "push")) | .[0].databaseId // empty') || run=""
    [ -n "$run" ] && break
    sleep 5
  done
  [ -n "$run" ] || die "no run of $workflow started for $sha: check GitHub Actions"
  # A failed watch is a failed run or a dropped connection: the run says which.
  until gh run watch "$run" --exit-status --interval "$wait_s" >/dev/null 2>&1; do
    state=$(gh_retry run view "$run" --json status,conclusion --jq '"\(.status) \(.conclusion)"') ||
      die "lost the connection to GitHub while the release run $run of $tag was running; it carries on in CI: gh run watch $run, or run this again"
    case "$state" in
      "completed success") break ;;
      completed*) die "the release run $run of $tag failed (${state#completed }): gh run view $run --log-failed (a re-run is safe)" ;;
    esac
    tries=$((tries + 1))
    [ "$tries" -lt 10 ] ||
      die "the connection to GitHub keeps dropping while the release run $run of $tag runs; it carries on in CI: gh run watch $run"
    sleep "$wait_s"
  done
  git fetch --quiet origin tag "$tag"
  echo "==> $tag published and tagged by CI (run $run)"
}

# Back on main after the merge, when the local main can simply follow
# origin/main. Otherwise (main is checked out in another worktree, or holds
# commits origin/main lacks) this continues detached on origin/main and leaves
# the local main as it is.
leave_branch() {
  git fetch --quiet origin main
  if git merge-base --is-ancestor main origin/main 2>/dev/null && git switch --quiet main 2>/dev/null; then
    git merge --quiet --ff-only origin/main
  else
    git switch --quiet --detach origin/main
    echo "==> continuing detached on origin/main; the local main is left as it is"
  fi
  git branch -D "$1" >/dev/null 2>&1 || true
}

cmd_merge() {
  [ $# -ge 1 ] || die "usage: pr.sh merge <version-file[,version-file...]|-> [<title>]"
  local vfs=$1 title=${2:-} branch here there vf
  local merged pr sha mtitle
  branch=$(git rev-parse --abbrev-ref HEAD)
  if [ "$branch" = main ] || [ "$branch" = HEAD ]; then
    die "merge: run on a feature branch"
  fi
  require_clean
  require_gh
  require_checks
  git fetch --quiet origin main
  if ! git merge-base --is-ancestor origin/main HEAD; then
    merged=$(merged_branch merge "$branch")
    read -r pr sha mtitle <<<"$merged"
    echo "==> $branch is merged already, as #$pr ($mtitle): nothing to do; now on $(git rev-parse --abbrev-ref HEAD)"
    return 0
  fi
  if [ "$vfs" != - ]; then
    for vf in ${vfs//,/ }; do
      here=$(version "$vf")
      there=$(version "$vf" origin/main)
      [ "$here" = "$there" ] ||
        die "merge: $branch changes $vf ($there -> $here): that is a release (just release-patch)"
    done
  fi
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
  local base next tag title branch pr sha merged mtitle
  require_clean
  require_gh
  require_checks
  git fetch --quiet origin main
  branch=$(git rev-parse --abbrev-ref HEAD)
  [ "$branch" != HEAD ] ||
    die "release: HEAD is detached. A finished release leaves it so when the local main holds commits origin/main lacks (git log origin/main..main lists them). Switch to main or to your feature branch; then run this again."
  if [ "$branch" = main ]; then
    check_main "$level"
  elif ! git merge-base --is-ancestor origin/main HEAD; then
    # Merged already: a run whose wait broke off, or `just merge`.
    merged=$(merged_branch release "$branch")
    read -r pr sha mtitle <<<"$merged"
    if [[ "$mtitle" == "release $name "* ]]; then
      tag=${mtitle##* }
      if git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null 2>&1; then
        git fetch --quiet origin tag "$tag"
        echo "==> #$pr ($mtitle) is merged, and $tag published and tagged already: nothing to do"
        return 0
      fi
      echo "==> #$pr ($mtitle) is merged already: following its release, not releasing again"
      await_release "$workflow" "$sha" "$tag"
      return 0
    fi
    [ "$(git rev-parse --abbrev-ref HEAD)" = main ] ||
      die "release: $branch was merged as #$pr ($mtitle) without a release, and the local main cannot follow origin/main (it holds commits origin/main lacks, or another worktree has it). Release from an up-to-date main."
    echo "==> $branch was merged as #$pr ($mtitle) without a release: releasing main, which holds it"
    branch=main
  fi

  base=$(version "$vf" origin/main)
  [ -n "$base" ] || die "release: $vf has no version on origin/main"
  next=$(next_version "$level" "$base")
  tag="${TAG_PREFIX-v}$next"
  title="release $name $tag"
  if [ "$(version "$vf")" != "$next" ]; then
    just "${WRITE_VERSION:-_write-version}" "$next"
    [ "$(version "$vf")" = "$next" ] || die "release: just ${WRITE_VERSION:-_write-version} $next left $vf at $(version "$vf")"
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
  sha=$(gh_retry pr view "$branch" --json mergeCommit --jq '.mergeCommit.oid') ||
    die "lost the connection to GitHub after the merge of $branch; it releases in CI: run this again to follow it"
  leave_branch "$branch"
  await_release "$workflow" "$sha" "$tag"
}

case "${1:-}" in
  merge) shift; cmd_merge "$@" ;;
  release) shift; cmd_release "$@" ;;
  *) die "usage: pr.sh merge|release ..." ;;
esac
