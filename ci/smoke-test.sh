#!/usr/bin/env bash
# CI/local: configure all tools, source a profile, assert on `cooldowns.sh check`.
# Usage:
#   bash ci/smoke-test.sh <profile-to-source>
#   bash -s <profile-to-source> < ci/smoke-test.sh   # stdin (Docker-friendly)
# Expects cooldowns.sh on PATH.
set -euo pipefail

profile="${1:?usage: ci/smoke-test.sh <profile-to-source>}"

for t in pip uv npm pnpm yarn bun deno cargo; do
  cooldowns.sh set "$t" 7d
done

# shellcheck disable=SC1090
. "$profile"

echo
check_log=$(mktemp)
trap 'rm -f "$check_log"' EXIT

if ! cooldowns.sh check >"$check_log" 2>&1; then
  echo "cooldowns.sh check exited non-zero"
  cat "$check_log"
  exit 1
fi

grep -q "Checking dependency cooldown configurations" "$check_log" || {
  echo "expected check header missing"
  cat "$check_log"
  exit 1
}
grep -q "8 configured, 0 warnings, 0 not configured" "$check_log" || {
  echo "expected check summary missing"
  cat "$check_log"
  exit 1
}
for t in pip uv npm pnpm yarn bun deno cargo; do
  grep -qE "^  ok[[:space:]]+${t}[[:space:]]" "$check_log" || {
    echo "expected ok line for ${t} missing"
    cat "$check_log"
    exit 1
  }
done
if grep -qE "^  (WARN|MISS)[[:space:]]" "$check_log"; then
  echo "unexpected WARN or MISS line"
  cat "$check_log"
  exit 1
fi

cat "$check_log"
echo "=== sourced profile (${profile}) ==="
cat "$profile"
