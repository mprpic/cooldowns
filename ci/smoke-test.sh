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

# pnpm checks that its global bin directory is in PATH before accepting config
# commands. With an isolated HOME the directory doesn't exist yet; create it
# and add it so pnpm doesn't abort with "global bin directory ... is not in PATH".
if command -v pnpm &>/dev/null; then
    case "$(uname -s)" in
        Darwin) _pnpm_bin="${HOME}/Library/pnpm/bin" ;;
        *)      _pnpm_bin="${HOME}/.local/share/pnpm/bin" ;;
    esac
    mkdir -p "$_pnpm_bin"
    export PATH="$_pnpm_bin:$PATH"
fi

configured_tools=()
for t in pip uv npm pnpm yarn bun deno cargo; do
  set_out=$(cooldowns.sh set "$t" 7d)
  echo "$set_out"
  if ! echo "$set_out" | grep -q "not installed, skipping"; then
    configured_tools+=("$t")
  fi
done

# pnpm: verify minimum-release-age landed in pnpm's own global config, not ~/.npmrc.
if command -v pnpm &>/dev/null; then
    pnpm_val=$(pnpm config get minimum-release-age 2>/dev/null || true)
    [[ "$pnpm_val" == "10080" ]] || {
        echo "smoke: pnpm minimum-release-age: expected 10080 (7 days in minutes), got '${pnpm_val}'" >&2
        exit 1
    }
    if grep -q "^minimum-release-age=" "${HOME}/.npmrc" 2>/dev/null; then
        echo "smoke: minimum-release-age must not appear in ~/.npmrc (would break npm 12)" >&2
        exit 1
    fi
    echo "smoke: pnpm minimum-release-age=$pnpm_val in pnpm global config, absent from ~/.npmrc"
fi

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

cooldowns.sh check >"$check_log" 2>&1 || true

grep -q "Checking dependency cooldown configurations" "$check_log" || {
  echo "expected check header missing"
  cat "$check_log"
  exit 1
}
for t in "${configured_tools[@]}"; do
  grep -qE "^  (ok|WARN)[[:space:]]+${t}[[:space:]]" "$check_log" || {
    echo "expected ok or WARN line for ${t} missing"
    cat "$check_log"
    exit 1
  }
done
if grep -qE "^  MISS[[:space:]]" "$check_log"; then
  echo "unexpected MISS line"
  cat "$check_log"
  exit 1
fi

cat "$check_log"
echo "=== sourced profile (${profile}) ==="
cat "$profile"
