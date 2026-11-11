#!/usr/bin/env bash
# Tests for apt-install.sh against stand-ins for apt-get, getent and timeout
# (nothing is installed, no resolver is changed), and that the workflows
# install packages on a runner only through it:
#   bash scripts/test_apt_install.sh
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
script="$here/apt-install.sh"
workflows="$here/../.github/workflows"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail=0

n=0
# setup: the runner's resolver; package sources as on a hosted runner (a
# deb822 file whose archive lives in the mirror list, a classic list with the
# security archive); stand-ins in $t/bin:
#   timeout  runs the command, without the limit
#   getent   every name resolves unless it is listed in $t/unknown
#   apt-get  logs its call and the resolver file of that moment; fails as
#            often as $t/fail says
setup() {
  n=$((n + 1))
  t="$work/$n"
  mkdir -p "$t/bin" "$t/sources"
  echo "nameserver 127.0.0.53" >"$t/resolv.conf"
  printf 'Types: deb\nURIs: mirror+file:/etc/apt/apt-mirrors.txt\nSuites: noble\n' >"$t/sources/ubuntu.sources"
  printf 'http://azure.archive.ubuntu.com/ubuntu/\tpriority:1\nhttp://archive.ubuntu.com/ubuntu/\tpriority:2\n' >"$t/apt-mirrors.txt"
  printf 'deb https://security.ubuntu.com/ubuntu noble-security main\n' >"$t/sources/security.list"
  printf '#!/usr/bin/env bash\nshift\nexec "$@"\n' >"$t/bin/timeout"
  cat >"$t/bin/getent" <<EOF
#!/usr/bin/env bash
! grep -qxF "\$2" "$t/unknown" 2>/dev/null
EOF
  cat >"$t/bin/apt-get" <<EOF
#!/usr/bin/env bash
echo "\$* [\$(tr '\n' ' ' <"$t/resolv.conf")]" >>"$t/calls"
n=\$(cat "$t/fail" 2>/dev/null || echo 0)
if [ "\$n" -gt 0 ]; then echo \$((n - 1)) >"$t/fail"; exit 100; fi
EOF
  chmod +x "$t/bin/"*
}

kind=github-hosted # the runner's RUNNER_ENVIRONMENT
check() { # check <name> <expected exit: 0|1> <package...>
  local name=$1 want=$2 got=0
  shift 2
  env PATH="$t/bin:$PATH" APT_INSTALL_SUDO="" APT_INSTALL_RESOLV_CONF="$t/resolv.conf" \
    APT_INSTALL_SOURCES="$t/sources $t/apt-mirrors.txt $t/missing" RUNNER_ENVIRONMENT="$kind" \
    bash "$script" "$@" >"$t/out" 2>&1 </dev/null || got=$?
  if { [ "$want" = 0 ] && [ "$got" = 0 ]; } || { [ "$want" = 1 ] && [ "$got" != 0 ]; }; then
    echo "ok   $name"
  else
    echo "FAIL $name (exit $got, wanted $want)"
    sed 's/^/     /' "$t/out"
    fail=1
  fi
}

expect() { # expect <name> <command...>: the command succeeds
  local name=$1
  shift
  if "$@" >/dev/null 2>&1; then echo "ok   $name"; else echo "FAIL $name"; fail=1; fi
}

# shellcheck disable=SC2329 # called through expect
said() { grep -qF -- "$1" "$t/out"; }
# shellcheck disable=SC2329 # called through expect
call() { sed -n "${1}p" "$t/calls" 2>/dev/null; }
# shellcheck disable=SC2329 # called through expect
calls() { if [ -e "$t/calls" ]; then wc -l <"$t/calls" | tr -d ' '; else echo 0; fi; }

runner="[nameserver 127.0.0.53 ]"
public="[nameserver 1.1.1.1 nameserver 8.8.8.8 ]"

setup
check "names resolve and apt-get works" 0 yamllint bats
expect "works: the runner's resolver stays" test "$(cat "$t/resolv.conf")" = "nameserver 127.0.0.53"
expect "works: update, then install" test "$(calls)" = 2
expect "works: update through the runner's resolver" test "$(call 1)" = "update -qq $runner"
expect "works: install with the gates' flags" test "$(call 2)" = "install -y -qq --no-install-recommends yamllint bats $runner"
expect "works: no warning" test -z "$(grep '::warning::' "$t/out")"

setup
echo azure.archive.ubuntu.com >"$t/unknown"
check "a name of the mirror list does not resolve" 0 bats
expect "unresolved: names it" said "azure.archive.ubuntu.com does not resolve"
expect "unresolved: warns" said "::warning::apt-install: a name of the package sources does not resolve; asking public resolvers"
expect "unresolved: public resolvers before the first try" test "$(call 1)" = "update -qq $public"
expect "unresolved: one try" test "$(calls)" = 2

setup
echo security.ubuntu.com >"$t/unknown"
check "a name of a classic list does not resolve" 0 bats
expect "classic list: public resolvers before the first try" test "$(call 1)" = "update -qq $public"

setup
echo 1 >"$t/fail"
check "apt-get fails once" 0 bats
expect "fails once: warns" said "::warning::apt-install: apt-get failed; asking public resolvers"
expect "fails once: the first try through the runner's resolver" test "$(call 1)" = "update -qq $runner"
expect "fails once: the second try through public resolvers" test "$(call 3)" = "install -y -qq --no-install-recommends bats $public"
expect "fails once: three calls" test "$(calls)" = 3

setup
# update succeeds, install fails, then update and install succeed
cat >"$t/bin/apt-get" <<EOF
#!/usr/bin/env bash
echo "\$1" >>"$t/calls"
[ "\$1" != install ] || [ -e "$t/second" ] || { touch "$t/second"; exit 100; }
EOF
check "the install fails once after a good update" 0 bats
expect "install fails once: both run again" test "$(tr '\n' ' ' <"$t/calls")" = "update install update install "

setup
echo 5 >"$t/fail"
check "apt-get fails twice: the step fails" 1 bats
expect "fails twice: says so" said "apt-get failed twice: bats"
expect "fails twice: two tries" test "$(calls)" = 2

setup
echo security.ubuntu.com >"$t/unknown"
echo 1 >"$t/fail"
check "public resolvers already asked and apt-get fails once" 0 bats
expect "asked already: one more try" said "::warning::apt-install: apt-get failed; second try"
expect "asked already: no second switch" test "$(grep -c 'asking public resolvers' "$t/out")" = 1

setup
echo azure.archive.ubuntu.com >"$t/unknown"
echo 1 >"$t/fail"
kind=self-hosted
check "a self-hosted runner" 0 bats
kind=github-hosted
expect "self-hosted: keeps its resolver" test "$(cat "$t/resolv.conf")" = "nameserver 127.0.0.53"
expect "self-hosted: says so" said "a self-hosted runner keeps its resolver"
expect "self-hosted: still a second try" said "::warning::apt-install: apt-get failed; second try"
expect "self-hosted: both tries through its resolver" test "$(call 3)" = "install -y -qq --no-install-recommends bats $runner"

setup
check "no package is a usage error" 1
expect "no package: says how" said "usage: apt-install.sh"
expect "no package: nothing installed" test "$(calls)" = 0

# The workflows: no apt-get of their own; the shell gate's three jobs through
# their harness checkout, the self-test's planted-failure job through this
# repository's checkout.
if grep -rnE 'apt(-get)? +(update|install)' "$workflows" >"$work/apt" 2>&1; then
  echo "FAIL the workflows install packages only through apt-install.sh:"
  sed 's/^/     /' "$work/apt"
  fail=1
else
  echo "ok   the workflows install packages only through apt-install.sh"
fi
# shellcheck disable=SC2016 # $HARNESS of the workflow's text, not of this shell
expect "shell-gate.yml: lint, unit and build use it" test "$(grep -cF '"$HARNESS/scripts/apt-install.sh"' "$workflows/shell-gate.yml")" = 3
expect "selftest.yml: shell-gate-fail uses it" grep -q 'scripts/apt-install.sh bats bats-support bats-assert' "$workflows/selftest.yml"

[ "$fail" = 0 ] && echo "all apt-install.sh tests passed"
exit "$fail"
