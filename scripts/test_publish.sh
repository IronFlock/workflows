#!/usr/bin/env bash
# Tests for publish.sh against a local bare remote, with a stub for gh (it
# records its calls; nothing reaches GitHub). Run: bash scripts/test_publish.sh
set -euo pipefail

script="$(cd "$(dirname "$0")" && pwd)/publish.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail=0

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

# gh: `api .../commits/<sha>/pulls` prints the pull request in $STUB/pr (none
# when absent), `pr checks` exits with $STUB/checks (default 0: all green).
mkdir -p "$work/bin"
cat >"$work/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >>"$STUB/log"
case "$1 $2" in
  "api repos/{owner}/{repo}/commits/"*) cat "$STUB/pr" 2>/dev/null || true ;;
  "pr checks") exit "$(cat "$STUB/checks" 2>/dev/null || echo 0)" ;;
esac
EOF
chmod +x "$work/bin/gh"
export PATH="$work/bin:$PATH"

n=0
# setup: a remote whose main has two commits, v1 on the first; a clone in $repo
# on main at the second, the merge commit of pull request 21.
setup() {
  n=$((n + 1))
  export STUB="$work/stub-$n"
  mkdir -p "$STUB"
  : >"$STUB/log"
  echo 21 >"$STUB/pr"
  origin="$work/origin-$n.git"
  repo="$work/repo-$n"
  git init -q --bare -b main "$origin"
  git init -q -b main "$repo"
  echo a >"$repo/pr.sh"
  git -C "$repo" add -A && git -C "$repo" commit -q -m "first"
  git -C "$repo" remote add origin "$origin"
  git -C "$repo" tag v1
  echo b >>"$repo/pr.sh"
  git -C "$repo" commit -q -am "guards (#21)"
  git -C "$repo" push -q -u origin main
  git -C "$repo" push -q origin v1
  first=$(git -C "$repo" rev-parse HEAD~1)
  head=$(git -C "$repo" rev-parse HEAD)
}

on_origin() { git -C "$origin" rev-parse -q --verify "refs/tags/$1^{commit}" 2>/dev/null; }

check() { # check <name> <expected exit> <publish.sh args...>
  local name=$1 want=$2 got=0
  shift 2
  (cd "$repo" && "$script" "$@") >"$work/out" 2>&1 </dev/null || got=$?
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
said() { grep -qF -- "$1" "$work/out"; }
# shellcheck disable=SC2329 # called through expect
tags_on_origin() { git -C "$origin" tag -l | sort | tr '\n' ' '; }

export PUBLISH_YES=1

# ---- publishing
setup
check "patch: the first after v1 alone is v1.0.1" 0 patch
expect "patch: v1.0.1 on origin at HEAD" test "$(on_origin v1.0.1)" = "$head"
expect "patch: v1 moved to HEAD" test "$(on_origin v1)" = "$head"
expect "patch: v1.0.1 is annotated" test "$(git -C "$origin" cat-file -t v1.0.1)" = tag
expect "patch: says how to roll back" said "git tag -f v1 $first && git push -f origin v1"
expect "patch: asked for #21's checks" grep -qF "gh pr checks 21" "$STUB/log"

setup
git -C "$repo" tag -a v1.0.4 -m old "$first" && git -C "$repo" push -q origin v1.0.4
check "minor: from the last version" 0 minor
expect "minor: v1.1.0" test "$(on_origin v1.1.0)" = "$head"
expect "minor: v1 moved" test "$(on_origin v1)" = "$head"

setup
check "major: a new major" 0 major
expect "major: v2.0.0 and v2 at HEAD" test "$(on_origin v2.0.0)/$(on_origin v2)" = "$head/$head"
expect "major: v1 stays where it was" test "$(on_origin v1)" = "$first"
expect "major: says callers move to @v2" said "@v2"

# ---- refusals: nothing pushed
setup
before=$(tags_on_origin)
git -C "$repo" switch -q -c feature
check "refused off main" 1 patch
expect "off main: says to switch" said "run on main"
expect "off main: no tag" test "$(tags_on_origin)" = "$before"

setup
before=$(tags_on_origin)
echo dirty >>"$repo/pr.sh"
check "refused with uncommitted changes" 1 patch
expect "dirty: no tag" test "$(tags_on_origin)" = "$before"

setup
git -C "$repo" commit -q --allow-empty -m "local only"
check "refused on a main ahead of origin" 1 patch
expect "ahead: says main is not origin/main" said "main is not origin/main"

setup
git -C "$repo" commit -q --allow-empty -m "on origin only" && git -C "$repo" push -q origin main
git -C "$repo" reset -q --hard HEAD~1
check "refused on a main behind origin" 1 patch

setup
git -C "$repo" tag -a v1.0.1 -m 'published' && git -C "$repo" push -q origin v1.0.1
check "refused when HEAD is published already" 1 patch
expect "published: names the version" said "published already, as v1.0.1"

setup
before=$(tags_on_origin)
rm "$STUB/pr"
check "refused when HEAD is no pull request's merge commit" 1 patch
expect "no pull request: says so" said "not the merge commit of a pull request"
expect "no pull request: no tag" test "$(tags_on_origin)" = "$before"

setup
before=$(tags_on_origin)
echo 1 >"$STUB/checks"
check "refused when the pull request's checks are not green" 1 patch
expect "red checks: names the pull request" said "gh pr checks 21"
expect "red checks: no tag, v1 unmoved" test "$(tags_on_origin)/$(on_origin v1)" = "$before/$first"

setup
before=$(tags_on_origin)
PUBLISH_YES='' check "refused without a terminal to confirm in" 1 patch
expect "no confirmation: no tag" test "$(tags_on_origin)" = "$before"

setup
check "refused for an unknown level" 1 huge

[ "$fail" = 0 ] && echo "all publish.sh tests passed"
exit "$fail"
