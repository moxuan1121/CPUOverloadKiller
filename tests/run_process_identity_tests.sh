#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
binary="$(mktemp)"
trap 'rm -f "$binary"' EXIT

cc \
  -std=c11 \
  -Wall \
  -Wextra \
  -Werror \
  -I"$repo_root" \
  "$repo_root/VDTProcessIdentity.c" \
  "$repo_root/tests/test_process_identity.c" \
  -o "$binary"

"$binary"
