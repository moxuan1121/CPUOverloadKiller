#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
binary="$(mktemp)"
policy_binary="$(mktemp)"
trap 'rm -f "$binary" "$policy_binary"' EXIT

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

cc \
  -std=c11 \
  -Wall \
  -Wextra \
  -Werror \
  -I"$repo_root" \
  "$repo_root/VDTPolicyTransition.c" \
  "$repo_root/tests/test_policy_transition.c" \
  -o "$policy_binary"

"$policy_binary"
