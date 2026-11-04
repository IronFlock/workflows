#!/usr/bin/env bash
# Prints a greeting; the positive control of the shell gate.
set -euo pipefail

name=${1:?usage: greet.sh NAME}
printf 'hello %s\n' "$name"
