#!/usr/bin/env bash
# Install pinned tools from tools.lock: download, verify sha256, unpack, put on PATH.
#   install-tool.sh <name> [<name>...]
# Installs into $TOOLS_BIN (default $RUNNER_TEMP/bin, else ~/.local/bin) and
# appends that directory to $GITHUB_PATH when running in GitHub Actions.
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
lock="$here/tools.lock"
bin=${TOOLS_BIN:-${RUNNER_TEMP:-$HOME/.local}/bin}
mkdir -p "$bin"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

[ "$#" -gt 0 ] || { echo "usage: install-tool.sh <name>..." >&2; exit 2; }

for name in "$@"; do
  line=$(awk -v n="$name" '$1 == n { print; exit }' "$lock")
  [ -n "$line" ] || { echo "install-tool: $name is not in tools.lock" >&2; exit 1; }
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
