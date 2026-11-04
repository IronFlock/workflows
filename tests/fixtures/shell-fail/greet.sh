#!/usr/bin/env bash
# Negative control of the shell gate: an unquoted expansion (SC2086) and a
# greeting the test does not expect.
name=$1
echo hi $name
