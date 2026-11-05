#!/usr/bin/env bash
# Scan a built root filesystem (the packages of an OS image) with trivy:
#   trivy-rootfs.sh <tree> <out.sarif> <out.cdx.json>
# Writes the CycloneDX SBOM of all packages and SARIF of the vulnerabilities
# that have a fix (the report job counts them), and prints the fixed HIGH and
# CRITICAL ones as a table. Never fails on findings; the report job decides.
# Fails when the tree holds no operating system with packages: trivy scans an
# empty or wrong directory without an error, and the report would look clean.
# Run as root when the build left the tree readable by root only.
# Optional env: VEX, TRIVYIGNORE (each used when the file exists).
set -euo pipefail

tree=$1
sarif=$2
sbom=$3

if [ ! -d "$tree" ]; then
  echo "::error::no root tree at $tree: the recipe did not leave one there (check the entry's path)"
  exit 1
fi

args=(--quiet --scanners vuln)
if [ -n "${VEX:-}" ] && [ -f "$VEX" ]; then args+=(--vex "$VEX"); fi
if [ -n "${TRIVYIGNORE:-}" ] && [ -f "$TRIVYIGNORE" ]; then args+=(--ignorefile "$TRIVYIGNORE"); fi

trivy rootfs "${args[@]}" --format cyclonedx --output "$sbom" "$tree"

# The SBOM names the operating system trivy detected (type debian, alpine,
# ...) and lists the packages it read from the package database (dpkg, apk,
# rpm) with that type.
packages=$(python3 -I -c '
import json, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
def props(c):
    return {p.get("name"): p.get("value") for p in c.get("properties") or []}
comps = doc.get("components") or []
systems = {props(c).get("aquasecurity:trivy:Type") for c in comps if c.get("type") == "operating-system"}
print(sum(1 for c in comps if c.get("type") == "library" and props(c).get("aquasecurity:trivy:PkgType") in systems - {None}))
' "$sbom")
if [ "$packages" -eq 0 ]; then
  echo "::error::trivy found no operating system with packages in $tree: the entry's path points elsewhere, or the build stopped before the packages were installed. The scan would report the image clean."
  exit 1
fi
echo "$packages OS packages in $tree" >&2

trivy rootfs "${args[@]}" --ignore-unfixed --format sarif --output "$sarif" "$tree"
trivy rootfs "${args[@]}" --ignore-unfixed --severity HIGH,CRITICAL --format table "$tree"
