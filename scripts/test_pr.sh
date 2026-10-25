#!/usr/bin/env bash
# Tests for pr.sh against a local bare remote, with stubs for gh and just
# (they record their calls; nothing reaches GitHub). Run: bash scripts/test_pr.sh
set -euo pipefail

script="$(cd "$(dirname "$0")" && pwd)/pr.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail=0

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export PR_WAIT_SECONDS=0

# gh: `pr list` prints the number in $STUB/pr (if any), `pr create` writes it,
# `pr view` reports MERGED and the merge commit $STUB/sha, `run list` run 42,
# `run watch` exits with $STUB/watch (default 0). Every call goes to $STUB/log.
mkdir -p "$work/bin"
cat >"$work/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >>"$STUB/log"
case "$1 $2" in
  "pr list") cat "$STUB/pr" 2>/dev/null || true ;;
  "pr create") echo 7 >"$STUB/pr" ;;
  "pr view")
    case "$*" in
      *mergeCommit*) cat "$STUB/sha" ;;
      *) echo MERGED ;;
    esac ;;
  "run list") echo 42 ;;
  "run watch") exit "$(cat "$STUB/watch" 2>/dev/null || echo 0)" ;;
esac
EOF
# just: `_write-version <v>` writes the version file named in $STUB/vf (a
# package.json through jq) and, if $STUB/extra exists, touches that file too.
cat >"$work/bin/just" <<'EOF'
#!/usr/bin/env bash
echo "just $*" >>"$STUB/log"
[ "$1" = _write-version ] || exit 1
vf=$(cat "$STUB/vf")
if [ "$(basename "$vf")" = package.json ]; then
  jq --arg v "$2" '.version = $v' "$vf" >"$vf.tmp" && mv "$vf.tmp" "$vf"
else
  echo "$2" >"$vf"
fi
if [ -f "$STUB/extra" ]; then echo x >>"$(cat "$STUB/extra")"; fi
EOF
chmod +x "$work/bin/gh" "$work/bin/just"
export PATH="$work/bin:$PATH"

n=0
# setup <version-file> <version>: a fresh remote with main at <version> and a
# clone in $repo with a feature branch `feat` holding one work commit.
setup() {
  n=$((n + 1))
  export STUB="$work/stub-$n"
  mkdir -p "$STUB"
  : >"$STUB/log"
  echo "$1" >"$STUB/vf"
  origin="$work/origin-$n.git"
  repo="$work/repo-$n"
  git init -q --bare -b main "$origin"
  git init -q -b main "$repo"
  if [ "$(basename "$1")" = package.json ]; then
    mkdir -p "$repo/$(dirname "$1")"
    printf '{\n  "name": "x",\n  "version": "%s"\n}\n' "$2" >"$repo/$1"
  else
    mkdir -p "$repo/$(dirname "$1")"
    echo "$2" >"$repo/$1"
  fi
  echo a >"$repo/work.txt"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "initial"
  git -C "$repo" remote add origin "$origin"
  git -C "$repo" push -q -u origin main
  git -C "$repo" switch -q -c feat
  echo b >>"$repo/work.txt"
  git -C "$repo" commit -q -am "fix the widget"
  # The merge commit the stub reports, and the tag CI would have set on it.
  git -C "$repo" rev-parse HEAD >"$STUB/sha"
}

# The tag that a successful release run leaves on origin.
ci_tag() { git -C "$repo" push -q origin "HEAD:refs/tags/$1"; }

check() { # check <name> <expected exit> <pr.sh args...>
  local name=$1 want=$2 got=0
  shift 2
  (cd "$repo" && "$script" "$@") >"$work/out" 2>&1 || got=$?
  if [ "$got" = "$want" ]; then
    echo "ok   $name"
  else
    echo "FAIL $name: exit $got, expected $want"
    sed 's/^/     /' "$work/out"
    fail=1
  fi
}

expect() { # expect <name> <command...>: the command succeeds
  local name=$1
  shift
  if "$@" >/dev/null 2>&1; then echo "ok   $name"; else echo "FAIL $name"; fail=1; fi
}

# shellcheck disable=SC2329 # called through expect
logged() { grep -qF -- "$1" "$STUB/log"; }
# shellcheck disable=SC2329 # called through expect
not_logged() { ! grep -qF -- "$1" "$STUB/log"; }
subject() { git -C "$repo" log -1 --format=%s "$1"; }
files_of() { git -C "$repo" show --name-only --format= "$1" | tr '\n' ' '; }

# ---- merge
setup VERSION 1.2.3
check "merge: from a feature branch" 0 merge VERSION
expect "merge: the branch is on origin" git -C "$origin" rev-parse --verify feat
expect "merge: title = the first commit's subject" logged "gh pr create --base main --head feat --title fix the widget"
expect "merge: squash auto-merge" logged "gh pr merge feat --squash --auto --delete-branch"
: >"$STUB/log"
check "merge: an existing pull request is reused" 0 merge VERSION "docs: another title"
expect "merge: no second pull request" not_logged "gh pr create"

setup VERSION 1.2.3
git -C "$repo" rm -q VERSION
git -C "$repo" commit -q -m "a repository without a version"
# stdin holds a version: read as a file name, '-' would compare it with main's.
check "merge: '-' for a repository without a version file" 0 merge - <<<"9.9.9"
expect "merge: '-' still opens the pull request" logged "gh pr create --base main --head feat"

setup VERSION 1.2.3
git -C "$repo" switch -q main
check "merge: refused on main" 1 merge VERSION

setup VERSION 1.2.3
echo dirty >>"$repo/work.txt"
check "merge: refused with uncommitted changes" 1 merge VERSION

setup VERSION 1.2.3
echo 1.2.4 >"$repo/VERSION"
git -C "$repo" commit -q -am "bump by hand"
check "merge: refused when the version changes" 1 merge VERSION

setup VERSION 1.2.3
check "merge: refused for a title starting with 'Release '" 1 merge VERSION "Release notes cleanup"
expect "merge: nothing pushed after a refusal" not_logged "gh pr"

setup VERSION 1.2.3
git -C "$repo" switch -q main
echo c >>"$repo/work.txt"
git -C "$repo" commit -q -am "on main"
git -C "$repo" push -q origin main
git -C "$repo" switch -q feat
check "merge: refused when the branch lacks origin/main" 1 merge VERSION

# ---- release
setup VERSION 1.2.3
ci_tag v1.2.4
check "release: patch from a feature branch" 0 release patch x VERSION release.yml VERSION
expect "release: commit 'release x v1.2.4' on origin/feat" test "$(subject origin/feat 2>/dev/null || git -C "$origin" log -1 --format=%s feat)" = "release x v1.2.4"
expect "release: the release commit holds only VERSION" test "$(files_of "$(git -C "$origin" rev-parse feat)")" = "VERSION "
expect "release: work commit below the release commit" test "$(git -C "$origin" log -1 --format=%s feat~1)" = "fix the widget"
expect "release: pull request titled like the commit" logged "gh pr create --base main --head feat --title release x v1.2.4"
expect "release: waits for the release run" logged "gh run watch 42 --exit-status"
expect "release: run looked up on the merge commit" logged "gh run list --workflow release.yml --commit $(cat "$STUB/sha")"
expect "release: back on main" test "$(git -C "$repo" rev-parse --abbrev-ref HEAD)" = main
expect "release: tag fetched" git -C "$repo" rev-parse --verify refs/tags/v1.2.4

setup VERSION 1.2.3
ci_tag v1.2.4
echo 1.2.4 >"$repo/VERSION"
git -C "$repo" commit -q -am "release x v1.2.4"
echo 7 >"$STUB/pr"
check "release: a second run on the same branch does not bump twice" 0 release patch x VERSION release.yml VERSION
expect "release: still v1.2.4" test "$(git -C "$origin" show feat:VERSION)" = 1.2.4
expect "release: no _write-version when already bumped" not_logged "just _write-version"
expect "release: existing pull request retitled" logged "gh pr edit 7 --title release x v1.2.4"
expect "release: no second pull request" not_logged "gh pr create"

setup VERSION 1.2.3
git -C "$repo" switch -q main
git -C "$repo" merge -q --ff-only feat
git -C "$repo" push -q origin main
ci_tag v1.3.0
check "release: minor from an up-to-date main" 0 release minor x VERSION release.yml VERSION
expect "release: branch release/v1.3.0 on origin" test "$(git -C "$origin" log -1 --format=%s release/v1.3.0)" = "release x v1.3.0"

setup VERSION 1.2.3
git -C "$repo" switch -q main
git -C "$repo" commit -q --allow-empty -m "local only"
check "release: refused on a main ahead of origin" 1 release patch x VERSION release.yml VERSION

setup VERSION 1.2.3
ci_tag v2.0.0
check "release: major" 0 release major x VERSION release.yml VERSION
expect "release: 2.0.0" test "$(git -C "$origin" show feat:VERSION)" = 2.0.0

setup VERSION 1.2.3
echo work.txt >"$STUB/extra"
check "release: refused when _write-version touches a file outside the list" 1 release patch x VERSION release.yml VERSION
expect "release: nothing pushed" not_logged "gh pr create"

setup VERSION 1.2.3
echo 1 >"$STUB/watch"
check "release: a failed release run fails" 1 release patch x VERSION release.yml VERSION

setup VERSION 1.2.3
check "release: unknown level" 1 release huge x VERSION release.yml VERSION

setup backend/package.json 1.4.22
ci_tag v1.4.23
check "release: package.json in a subdirectory" 0 release patch reauth-login backend/package.json release.yml backend/package.json
expect "release: package.json at 1.4.23" test "$(git -C "$origin" show feat:backend/package.json | jq -r .version)" = 1.4.23

[ "$fail" = 0 ] && echo "all pr.sh tests passed"
exit "$fail"
