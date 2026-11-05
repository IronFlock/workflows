#!/usr/bin/env bash
# Install pinned tools from tools.lock: download, verify sha256, unpack, put on PATH.
#   install-tool.sh <name> [<name>...]
# Installs into $TOOLS_BIN (default $RUNNER_TEMP/bin, else ~/.local/bin) and
# appends that directory to $GITHUB_PATH when running in GitHub Actions.
# On an arm64 runner it takes the <name>/arm64 entry; the binary keeps its name.
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
lock="$here/tools.lock"
bin=${TOOLS_BIN:-${RUNNER_TEMP:-$HOME/.local}/bin}
mkdir -p "$bin"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

[ "$#" -gt 0 ] || { echo "usage: install-tool.sh <name>..." >&2; exit 2; }

machine=${INSTALL_TOOL_MACHINE:-$(uname -m)}
case "$machine" in
  x86_64 | amd64) suffix="" ;;
  aarch64 | arm64) suffix=/arm64 ;;
  *) echo "install-tool: tools.lock has no entries for $machine" >&2; exit 1 ;;
esac

for name in "$@"; do
  line=$(awk -v n="$name$suffix" '$1 == n { print; exit }' "$lock")
  [ -n "$line" ] || { echo "install-tool: $name$suffix is not in tools.lock" >&2; exit 1; }
  read -r _ version sha url member <<<"$line"
  dir="$work/$name"
  mkdir -p "$dir"
  file="$dir/${url##*/}"
  curl -fsSL --retry 3 --proto '=https' -o "$file" "$url"
  echo "$sha  $file" | sha256sum -c --quiet - || { echo "install-tool: checksum mismatch for $name $version" >&2; exit 1; }
  case "$file" in
    *.tar.gz | *.tgz) tar -xzf "$file" -C "$dir" ;;
    *.tar.xz) tar -xJf "$file" -C "$dir" ;;
    *.zip) unzip -q "$file" -d "$dir" ;;
  esac
  if [ "$member" = "-" ]; then
    src=$file
  else
    src="$dir/$member"
    # Release archives sometimes nest the binary in a versioned folder.
    [ -f "$src" ] || src=$(find "$dir" -type f -name "$(basename "$member")" | head -n 1)
  fi
  [ -n "$src" ] && [ -f "$src" ] || { echo "install-tool: $member not found in the $name archive" >&2; exit 1; }
  install -m 0755 "$src" "$bin/$name"
  echo "installed $name $version"
done

if [ -n "${GITHUB_PATH:-}" ]; then
  echo "$bin" >> "$GITHUB_PATH"
fi
