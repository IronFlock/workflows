#!/usr/bin/env bash
# Tests of release.sh against throwaway git repositories:
#   bash scripts/test_release.sh
set -euo pipefail

script="$(cd "$(dirname "$0")" && pwd)/release.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

check() { # check <name> <expected exit: 0|1> <command...>
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

expect_output() { # expect_output <name> <line>
  if grep -qx -- "$2" "$GITHUB_OUTPUT"; then
    echo "ok   $1"
  else
    echo "FAIL $1: '$2' not in output:"
    sed 's/^/     /' "$GITHUB_OUTPUT"
    failures=$((failures + 1))
  fi
}

# repo <dir> <version file> <version>: a repository with one commit
repo() {
  mkdir -p "$1"
  git -C "$1" init -q -b main
  git -C "$1" config user.email t@example.invalid
  git -C "$1" config user.name test
  setv "$1" "$2" "$3"
  git -C "$1" add -A
  git -C "$1" commit -qm initial
}

setv() { # setv <dir> <file> <version>
  case "$2" in
    package.json) printf '{\n  "name": "x",\n  "version": "%s"\n}\n' "$3" > "$1/$2" ;;
    # Other tables with a version key: only [project] counts.
    pyproject.toml) printf '[tool.other]\nversion = "0.0.1"\n\n[project]\nname = "x"\nversion = "%s"  # uv version\n\n[tool.later]\nversion = "9.9.9"\n' "$3" > "$1/$2" ;;
    *) printf '%s\n' "$3" > "$1/$2" ;;
  esac
}

commit() { # commit <dir> <message>: commit every change, print the sha
  touch "$1/change-$RANDOM"
  git -C "$1" add -A
  git -C "$1" commit -qm "$2"
  git -C "$1" rev-parse HEAD
}

intent() { # intent <dir> <file> <base> <head> <title>
  (cd "$1" && VERSION_FILE=$2 TAG_PREFIX=v BASE_SHA=$3 HEAD_SHA=$4 TITLE=$5 "$script" intent)
}

for vf in VERSION package.json pyproject.toml; do
  r="$work/intent-$vf"
  repo "$r" "$vf" 1.2.3
  base=$(git -C "$r" rev-parse HEAD)

  same=$(commit "$r" "docs")
  check "$vf: no-release, version unchanged" 0 intent "$r" "$vf" "$base" "$same" "fix a typo"
  check "$vf: no-release, any title" 0 intent "$r" "$vf" "$base" "$same" "deps: bump express (dependabot)"
  check "$vf: release title without a bump" 1 intent "$r" "$vf" "$base" "$same" "release x v1.2.3"
  check "$vf: any title starting with release, without a bump" 1 intent "$r" "$vf" "$base" "$same" "Release notes cleanup"
  check "$vf: no-release title mentioning a release later" 0 intent "$r" "$vf" "$base" "$same" "docs: explain the release flow"

  git -C "$r" checkout -q "$base"
  setv "$r" "$vf" 1.2.4
  bump=$(commit "$r" "bump")
  export GITHUB_OUTPUT="$work/out-$vf"
  : > "$GITHUB_OUTPUT"
  check "$vf: release PR" 0 intent "$r" "$vf" "$base" "$bump" "release x v1.2.4"
  expect_output "$vf: release PR reports its tag" "tag=v1.2.4"
  unset GITHUB_OUTPUT
  check "$vf: bump without a release title" 1 intent "$r" "$vf" "$base" "$bump" "fix a typo"
  check "$vf: release title names another version" 1 intent "$r" "$vf" "$base" "$bump" "release x v1.2.5"
  check "$vf: release title with text after the tag" 1 intent "$r" "$vf" "$base" "$bump" "release x v1.2.4 and more"

  git -C "$r" checkout -q "$base"
  setv "$r" "$vf" 1.2.2
  down=$(commit "$r" "downgrade")
  check "$vf: lower version" 1 intent "$r" "$vf" "$base" "$down" "release x v1.2.2"

  git -C "$r" checkout -q "$base"
  setv "$r" "$vf" 1.10.0
  minor=$(commit "$r" "minor")
  check "$vf: 1.2.3 -> 1.10.0 is higher (version sort)" 0 intent "$r" "$vf" "$base" "$minor" "release x v1.10.0"
done

mode() { # mode <dir> <event> <ref> <ref type> <ref name> <commit title>
  (cd "$1" && VERSION_FILE=VERSION TAG_PREFIX=v EVENT=$2 REF=$3 REF_TYPE=$4 REF_NAME=$5 \
    RELEASE_BRANCH=main COMMIT_TITLE=$6 SHA=$(git rev-parse HEAD) "$script" mode)
}

r="$work/mode"
repo "$r" VERSION 2.0.0
export GITHUB_OUTPUT="$work/out-mode"

: > "$GITHUB_OUTPUT"
check "merge of a release PR releases" 0 mode "$r" push refs/heads/main branch main "release x v2.0.0 (#12)"
expect_output "merge of a release PR: mode release" "mode=release"
expect_output "merge of a release PR: tag" "tag=v2.0.0"
check "merge title with the PR body below" 0 mode "$r" push refs/heads/main branch main $'release x v2.0.0 (#12)\n\nbody'
check "merge of a no-release PR is refused" 1 mode "$r" push refs/heads/main branch main "docs: typo (#13)"
check "merge naming another version is refused" 1 mode "$r" push refs/heads/main branch main "release x v1.9.0 (#14)"
git -C "$r" tag -a v2.0.0 -m "release x v2.0.0"
: > "$GITHUB_OUTPUT"
check "a re-run after a complete release passes" 0 mode "$r" push refs/heads/main branch main "release x v2.0.0 (#12)"
expect_output "re-run after a complete release: mode released" "mode=released"
commit "$r" "release x v2.0.0 again" >/dev/null
check "a version tagged on another commit is not released again" 1 mode "$r" push refs/heads/main branch main "release x v2.0.0 (#15)"

: > "$GITHUB_OUTPUT"
check "a pushed tag matching the version releases" 0 mode "$r" push refs/tags/v2.0.0 tag v2.0.0 "anything"
expect_output "pushed tag: mode tag" "mode=tag"
check "a pushed tag not matching the version fails" 1 mode "$r" push refs/tags/v2.0.1 tag v2.0.1 "anything"

: > "$GITHUB_OUTPUT"
check "a pull request is a dry run" 0 mode "$r" pull_request refs/pull/3/merge branch 3/merge "x"
expect_output "pull request: mode dry-run" "mode=dry-run"
: > "$GITHUB_OUTPUT"
check "a push to another branch is a dry run" 0 mode "$r" push refs/heads/feature branch feature "release x v2.0.0"
expect_output "other branch: mode dry-run" "mode=dry-run"
: > "$GITHUB_OUTPUT"
check "workflow_dispatch on main is a dry run" 0 mode "$r" workflow_dispatch refs/heads/main branch main "release x v2.0.0"
expect_output "workflow_dispatch: mode dry-run" "mode=dry-run"

unset GITHUB_OUTPUT

# release.sh tag against a fake `gh` that keeps refs and tag objects in a folder.
mkdir -p "$work/bin" "$work/gh"
cat > "$work/bin/gh" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
state=$FAKE_GH_STATE
path=$2
shift 2
object="" message="" sha="" ref=""
while [ $# -gt 0 ]; do
  case "$1" in
    -f)
      case "$2" in
        object=*) object=${2#*=} ;;
        message=*) message=${2#*=} ;;
        sha=*) sha=${2#*=} ;;
        ref=*) ref=${2#*=} ;;
      esac
      shift 2 ;;
    --jq | -X | -F) shift 2 ;;
    *) shift ;;
  esac
done
case "$path" in
  */git/ref/tags/*) cat "$state/ref-${path##*/}" 2>/dev/null || exit 1 ;;
  */git/ref/heads/*) cat "$state/head-${path##*/}" 2>/dev/null || exit 1 ;;
  */git/refs/heads/*) echo "$sha" > "$state/head-${path##*/}" ;;
  */compare/*)
    range=${path##*/}
    if grep -qx "${range%...*} ${range#*...}" "$state/ancestors" 2>/dev/null; then echo ahead; else echo diverged; fi ;;
  */git/tags/*) cat "$state/obj-${path##*/}" ;;
  */git/tags)
    obj=t$RANDOM
    echo "$object" > "$state/obj-$obj"
    echo "$message" > "$state/msg-$obj"
    echo "$obj" ;;
  */git/refs)
    case "$ref" in
      refs/heads/*) echo "$sha" > "$state/head-${ref##*/}" ;;
      *) echo "tag $sha" > "$state/ref-${ref##*/}" ;;
    esac ;;
  *) echo "fake gh: unexpected $path" >&2; exit 2 ;;
esac
FAKE
chmod +x "$work/bin/gh"

tag() { # tag <tag> <sha>
  PATH="$work/bin:$PATH" FAKE_GH_STATE="$work/gh" REPO=o/r TAG=$1 SHA=$2 \
    MESSAGE="release x $1" GH_TOKEN=unused "$script" tag
}
check "tag: a new tag is created" 0 tag v3.0.0 aaa
if grep -qx "release x v3.0.0" "$work"/gh/msg-*; then echo "ok   tag: annotated with the release title"; else
  echo "FAIL tag: message missing"; failures=$((failures + 1)); fi
check "tag: a re-run on the same commit passes" 0 tag v3.0.0 aaa
check "tag: the same tag on another commit fails" 1 tag v3.0.0 bbb
echo "commit ccc" > "$work/gh/ref-v3.0.1"
check "tag: a lightweight tag on the same commit passes" 0 tag v3.0.1 ccc

promote() { # promote <sha>
  PATH="$work/bin:$PATH" FAKE_GH_STATE="$work/gh" REPO=o/r BRANCH=production SHA=$1 \
    GH_TOKEN=unused "$script" promote
}
head_is() { # head_is <name> <sha>
  if [ "$(cat "$work/gh/head-production" 2>/dev/null)" = "$2" ]; then echo "ok   $1"; else
    echo "FAIL $1: production is on '$(cat "$work/gh/head-production" 2>/dev/null)', expected $2"; failures=$((failures + 1)); fi
}
check "promote: a missing branch is created" 0 promote aaa
head_is "promote: created on the release commit" aaa
check "promote: a re-run on the same commit passes" 0 promote aaa
echo "aaa bbb" > "$work/gh/ancestors"
check "promote: a fast-forward moves the branch" 0 promote bbb
head_is "promote: moved to the new release" bbb
check "promote: a commit that does not descend fails" 1 promote zzz
head_is "promote: not moved after a refusal" bbb

[ "$failures" = 0 ] || { echo "$failures failure(s)"; exit 1; }
echo "all release.sh tests passed"
