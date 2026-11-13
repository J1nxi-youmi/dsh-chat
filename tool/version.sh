#!/usr/bin/env bash
# Build number to dotted version:
#   #122 -> 1.2.2
#   #1000 -> 1.0.0.0
# Pad to at least 3 digits, then put a dot between digits.
# Usage: bash tool/version.sh <run_number>
set -euo pipefail
RUN=${1:?need run number}
padded=$(printf '%03d' "$RUN")
version="${padded:0:1}"
for ((i = 1; i < ${#padded}; i++)); do
  version="$version.${padded:i:1}"
done
printf '%s\n' "$version"
