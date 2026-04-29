#!/usr/bin/env bash
# CI/local: configure all tools, source a profile, assert on `cooldowns.sh check`.
# Usage:
#   bash ci/smoke-test.sh <profile-to-source>
#   bash -s <profile-to-source> < ci/smoke-test.sh   # stdin (Docker-friendly)
# Expects cooldowns.sh on PATH.
set -euo pipefail

profile="${1:?usage: ci/smoke-test.sh <profile-to-source>}"

# `set bun` rewrites ~/.bunfig.toml via mktemp+mv when [install] exists; mode must match
# the previous file (copy_mode_from). Seed that case only when bunfig is absent.
file_mode_octal() {
  local f="$1"
  case "$(uname -s)" in
    Darwin) stat -f %OLp "$f" ;; # permission octal only (%a is wrong on macOS)
    *)      stat -c %a "$f" ;;
  esac
}

bunfig="${HOME}/.bunfig.toml"
verify_bunfig_mode_preserved=false
if [[ ! -f "$bunfig" ]]; then
  ( umask 027; printf '[install]\n' >"$bunfig" )
  bunfig_mode_before=$(file_mode_octal "$bunfig")
  verify_bunfig_mode_preserved=true
fi

for t in pip uv npm pnpm yarn bun deno cargo; do
  cooldowns.sh set "$t" 7d
done

if [[ "$verify_bunfig_mode_preserved" == true ]]; then
  bunfig_mode_after=$(file_mode_octal "$bunfig")
  if (( "8#$bunfig_mode_before" != "8#$bunfig_mode_after" )); then
    echo "smoke: ~/.bunfig.toml mode changed (${bunfig_mode_before} -> ${bunfig_mode_after}) after bun set (expected unchanged; see copy_mode_from in cooldowns.sh)" >&2
    exit 1
  fi
fi

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
