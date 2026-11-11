#!/usr/bin/env bash
# Installs Ubuntu packages on a runner with apt-get, and asks public resolvers
# for the archive's names when the runner's resolver does not know them.
#   apt-install.sh <package>...
#
# On 2026-11-11 the hosted runners could not resolve the names of Ubuntu's
# archive for hours, while the archive was up and public resolvers answered.
# apt-get waited out every name: jobs hung for 14 to 50 minutes and then
# failed. So this script
#
#   1. asks for the names in the runner's package sources first, and switches
#      to public resolvers (1.1.1.1, 8.8.8.8) at once when one of them does
#      not resolve;
#   2. gives one apt-get call 10 minutes;
#   3. tries a second time when the first try fails, through public resolvers
#      when the first try did not use them yet.
#
# What is installed is the same either way. A self-hosted runner
# (RUNNER_ENVIRONMENT=self-hosted) keeps its own resolver: it outlives the job
# and may need it for private names; it only gets the second try.
#
# Env (the tests set them): APT_INSTALL_RESOLV_CONF, APT_INSTALL_SOURCES (files
# and folders, space-separated), APT_INSTALL_SUDO (empty: none),
# APT_INSTALL_TIMEOUT (seconds per apt-get call).
set -euo pipefail

[ "$#" -gt 0 ] || { echo "usage: apt-install.sh <package>..." >&2; exit 2; }

resolv=${APT_INSTALL_RESOLV_CONF:-/etc/resolv.conf}
sources=${APT_INSTALL_SOURCES:-/etc/apt/sources.list /etc/apt/sources.list.d /etc/apt/apt-mirrors.txt}
sudo=${APT_INSTALL_SUDO-sudo}
limit=${APT_INSTALL_TIMEOUT:-600}

die() { echo "apt-install: $*" >&2; exit 1; }

# hosts: the host names in the runner's package sources, one per line.
hosts() {
  # shellcheck disable=SC2086 # a space-separated list of files and folders
  grep -rhoE 'https?://[A-Za-z0-9.-]+' $sources 2>/dev/null | sed 's|^[a-z]*://||' | sort -u || true
}

# resolves: does every host of the package sources resolve?
resolves() {
  local h bad=0
  for h in $(hosts); do
    timeout 15 getent hosts "$h" >/dev/null || {
      echo "apt-install: $h does not resolve" >&2
      bad=1
    }
  done
  return "$bad"
}

public=0
public_resolvers() {
  if [ "${RUNNER_ENVIRONMENT:-}" = self-hosted ]; then
    echo "::warning::apt-install: $1; a self-hosted runner keeps its resolver"
    return 0
  fi
  echo "::warning::apt-install: $1; asking public resolvers (1.1.1.1, 8.8.8.8)"
  # resolv.conf is a link into systemd-resolved's folder on the runners.
  $sudo rm -f "$resolv"
  printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' | $sudo tee "$resolv" >/dev/null
  public=1
}

fetch() {
  $sudo timeout "$limit" apt-get update -qq &&
    $sudo timeout "$limit" apt-get install -y -qq --no-install-recommends "$@"
}

resolves || public_resolvers "a name of the package sources does not resolve"
if ! fetch "$@"; then
  if [ "$public" = 0 ] && [ "${RUNNER_ENVIRONMENT:-}" != self-hosted ]; then
    public_resolvers "apt-get failed"
  else
    echo "::warning::apt-install: apt-get failed; second try"
  fi
  fetch "$@" || die "apt-get failed twice: $*"
fi
echo "installed $*"
