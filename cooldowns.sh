#!/bin/bash
#
# cooldowns.sh -- set and check dependency cooldown configurations
#
# Usage:
#   cooldowns.sh set <tool> <duration>    Set cooldown for a package manager
#   cooldowns.sh check                    Check cooldown status for all tools
#
# Examples:
#   cooldowns.sh set pip 3d
#   cooldowns.sh set uv "3 days"
#   cooldowns.sh set npm 7d
#   cooldowns.sh check
#
# Supported tools: pip, uv, npm, pnpm, yarn, bun, deno, cargo
#
# Where configs are written:
#   pip    Shell wrapper in /etc/profile.d/cooldowns.sh (or ~/.zshrc / ~/.bashrc)
#   uv     UV_EXCLUDE_NEWER export in /etc/profile.d/cooldowns.sh (or ~/.zshrc / ~/.bashrc)
#   npm    min-release-age in ~/.npmrc
#   pnpm   minimum-release-age in ~/.npmrc
#   yarn   YARN_NPM_MINIMAL_AGE_GATE export in /etc/profile.d/cooldowns.sh (or ~/.zshrc / ~/.bashrc)
#   bun    minimumReleaseAge in ~/.bunfig.toml
#   deno   Aliases in /etc/profile.d/cooldowns.sh (or ~/.zshrc / ~/.bashrc)
#   cargo  COOLDOWN_MINUTES export in /etc/profile.d/cooldowns.sh (or ~/.zshrc / ~/.bashrc)
#
# Profile scripts fall back to the user's rc file (~/.zshrc or ~/.bashrc, based
# on $SHELL) when /etc/profile.d is not writable.
# All paths are user-wide; project-level configs are not modified.
#
# In a Containerfile:
#   COPY cooldowns.sh /usr/local/bin/
#   RUN cooldowns.sh set pip 3d && cooldowns.sh set uv 3d

set -euo pipefail

# All platform-specific knobs live here. Callers (and emitted wrappers) never
# branch at invocation time.
#   SED_INPLACE      array form of `sed -i` for the local platform
#   date_to_epoch    YYYY-MM-DD -> epoch seconds
#   _date_days_ago   emits a `date ...` command string for "N days ago in UTC"
#   copy_mode_from   chmod DEST to SRC's mode (mktemp files are often 0600)
case "$OSTYPE" in
    darwin*|*bsd*)
        SED_INPLACE=(sed -i '')
        date_to_epoch()   { date -j -f '%Y-%m-%d' "$1" +%s 2>/dev/null; }
        _date_days_ago()  { echo "date -u -v-${1}d '+%Y-%m-%dT%H:%M:%SZ'"; }
        # macOS chmod has no --reference; %OLp is permission bits (not full st_mode).
        copy_mode_from() { local src="$1" dest="$2"; chmod "$(stat -f %OLp "$src")" "$dest"; }
        ;;
    *)
        SED_INPLACE=(sed -i)
        date_to_epoch()   { date -d "$1" +%s 2>/dev/null; }
        _date_days_ago()  { echo "date -u -d '$1 days ago' '+%Y-%m-%dT%H:%M:%SZ'"; }
        # GNU chmod: clone mode from SRC (see `chmod --help`).
        copy_mode_from() { local src="$1" dest="$2"; chmod --reference="$src" "$dest"; }
        ;;
esac

# Extract the first `key = value` style value from a file. Tolerates an
# optional `export ` prefix, whitespace around `=`, and surrounding quotes.
# Prints the value (no newline stripping beyond trailing WS/comment) and
# returns 0 if found, 1 otherwise. Portable alternative to `grep -oP ... \K`
# (which isn't available on macOS's BSD grep).
extract_kv() {
    local key="$1" file="$2" val
    [[ -f "$file" ]] || return 1
    val=$(awk -v key="$key" '
        {
            sub(/\r$/, "")
            if (match($0, "^[[:space:]]*(export[[:space:]]+)?" key "[[:space:]]*=[[:space:]]*")) {
                val = substr($0, RSTART + RLENGTH)
                sub(/[[:space:]]*(#.*)?$/, "", val)
                if (val ~ /^".*"$/ || val ~ /^'\''.*'\''$/) {
                    val = substr(val, 2, length(val) - 2)
                }
                print val
                exit
            }
        }
    ' "$file")
    [[ -n "$val" ]] && { printf '%s\n' "$val"; return 0; }
    return 1
}

PROFILE_DIR="/etc/profile.d"
PROFILE_SCRIPT="$PROFILE_DIR/cooldowns.sh"

# Pick the user's rc file based on $SHELL (used when /etc/profile.d isn't writable).
user_rc_file() {
    case "$(basename "${SHELL:-}")" in
        zsh)  echo "${ZDOTDIR:-$HOME}/.zshrc" ;;
        bash) echo "$HOME/.bashrc" ;;
        *)    echo "$HOME/.profile" ;;
    esac
}

# All locations where we might have written cooldown config
PROFILE_CANDIDATES=(
    "$PROFILE_DIR/cooldowns.sh"
    "${ZDOTDIR:-$HOME}/.zshrc"
    "$HOME/.bashrc"
    "$HOME/.profile"
)

# Search all candidate profile files for a marker
find_in_profiles() {
    local marker="$1"
    for f in "${PROFILE_CANDIDATES[@]}"; do
        if [[ -f "$f" ]] && grep -q "$marker" "$f" 2>/dev/null; then
            echo "$f"
            return 0
        fi
    done
    return 1
}

# ---------------------------------------------------------------------------
# Duration parsing
# ---------------------------------------------------------------------------

parse_days() {
    local input="$1"
    # Strip quotes, lowercase, trim whitespace
    input=$(echo "$input" | tr -d '"'"'" | tr '[:upper:]' '[:lower:]' | xargs)

    # Match: "3d", "3 days", "3days", "3 day", or just "3"
    if [[ "$input" =~ ^([0-9]+)[[:space:]]*(d|days?)?$ ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo "error: can't parse duration '$input' (expected something like '3d' or '3 days')" >&2
        return 1
    fi
}

minutes_to_days() {
    echo $(( $1 / 1440 ))
}

# Format duration for tools that want their own syntax
duration_for_tool() {
    local days="$1"
    local tool="$2"
    case "$tool" in
        uv)       echo "$days days" ;;
        npm)      echo "$days" ;;                       # days
        pnpm)     echo $(( days * 24 * 60 )) ;;         # minutes
        bun)      echo $(( days * 24 * 60 * 60 )) ;;    # seconds
        deno)     echo "P${days}D" ;;                    # ISO 8601
        yarn)     echo $(( days * 24 * 60 )) ;;          # minutes
        cargo)    echo $(( days * 24 * 60 )) ;;          # minutes
        *)        echo "$days" ;;
    esac
}

# ---------------------------------------------------------------------------
# Set cooldown
# ---------------------------------------------------------------------------

ensure_profile_dir() {
    if [[ ! -d "$PROFILE_DIR" ]] || [[ ! -w "$PROFILE_DIR" ]]; then
        PROFILE_SCRIPT="$(user_rc_file)"
    fi
}

# Remove any previous cooldown config for a tool from the profile script
clean_previous() {
    local tool="$1"
    local target="$2"
    if [[ -f "$target" ]]; then
        # Remove lines between markers
        "${SED_INPLACE[@]}" "/^# cooldowns:${tool}:start$/,/^# cooldowns:${tool}:end$/d" "$target"
    fi
}

set_pip() {
    local days="$1"
    ensure_profile_dir

    if ! find_in_profiles "cooldowns:pip:start" &>/dev/null; then
        if [[ -n "${PIP_UPLOADED_PRIOR_TO:-}" ]]; then
            echo "pip: PIP_UPLOADED_PRIOR_TO is already set to '$PIP_UPLOADED_PRIOR_TO', skipping"
            return
        fi
        for candidate in \
            "${HOME}/.config/pip/pip.conf" \
            "${HOME}/.pip/pip.conf" \
            "/etc/pip.conf" \
            "${XDG_CONFIG_HOME:-$HOME/.config}/pip/pip.conf"; do
            if [[ -f "$candidate" ]] && grep -q "uploaded-prior-to" "$candidate" 2>/dev/null; then
                echo "pip: uploaded-prior-to is already configured in $candidate, skipping"
                return
            fi
        done
        local existing_file
        if existing_file=$(find_in_profiles "PIP_UPLOADED_PRIOR_TO="); then
            echo "pip: PIP_UPLOADED_PRIOR_TO is already configured in $existing_file, skipping"
            return
        fi
    fi

    clean_previous pip "$PROFILE_SCRIPT"

    local date_cmd
    date_cmd=$(_date_days_ago "$days")

    cat >> "$PROFILE_SCRIPT" << SHELL
# cooldowns:pip:start
pip() {
    local pip_major cutoff
    pip_major=\$(command pip --version 2>/dev/null | awk '{ split(\$2, a, "."); print a[1]; exit }')
    case "\$1" in
        install|download|wheel)
            if [[ "\${pip_major:-0}" -ge 26 ]]; then
                cutoff=\$($date_cmd)
                command pip "\$1" --uploaded-prior-to "\$cutoff" "\${@:2}"
            else
                echo "warning: pip \${pip_major:-unknown} does not support --uploaded-prior-to (need >= 26), skipping cooldown" >&2
                command pip "\$@"
            fi
            ;;
        *)
            command pip "\$@"
            ;;
    esac
}
# cooldowns:pip:end
SHELL
    echo "pip: installed shell wrapper with ${days}-day cooldown in $PROFILE_SCRIPT"
}

set_uv() {
    local days="$1"
    local duration
    duration=$(duration_for_tool "$days" uv)
    ensure_profile_dir

    if ! find_in_profiles "cooldowns:uv:start" &>/dev/null; then
        if [[ -n "${UV_EXCLUDE_NEWER:-}" ]]; then
            echo "uv: UV_EXCLUDE_NEWER is already set to '$UV_EXCLUDE_NEWER', skipping"
            return
        fi
        local uv_toml="${HOME}/.config/uv/uv.toml"
        if [[ -f "$uv_toml" ]] && grep -q "exclude-newer" "$uv_toml" 2>/dev/null; then
            echo "uv: exclude-newer is already configured in $uv_toml, skipping"
            return
        fi
        local existing_file
        if existing_file=$(find_in_profiles "UV_EXCLUDE_NEWER="); then
            echo "uv: UV_EXCLUDE_NEWER is already configured in $existing_file, skipping"
            return
        fi
    fi

    clean_previous uv "$PROFILE_SCRIPT"

    cat >> "$PROFILE_SCRIPT" << SHELL
# cooldowns:uv:start
export UV_EXCLUDE_NEWER="$duration"
# cooldowns:uv:end
SHELL
    echo "uv: set UV_EXCLUDE_NEWER=\"$duration\" in $PROFILE_SCRIPT"
}

set_npmrc_key() {
    local tool="$1" key="$2" days="$3"
    local duration
    duration=$(duration_for_tool "$days" "$tool")
    local npmrc="${HOME}/.npmrc"

    if [[ -f "$npmrc" ]] && grep -q "^${key}=" "$npmrc" 2>/dev/null; then
        local val
        val=$(extract_kv "$key" "$npmrc" || echo "")
        echo "${tool}: ${key}=${val} is already configured in $npmrc, skipping"
        return
    fi

    echo "${key}=$duration" >> "$npmrc"
    echo "${tool}: set ${key}=$duration in $npmrc"
}

set_npm() {
    if command -v npm &>/dev/null; then
        local npm_major
        npm_major=$(npm --version 2>/dev/null | cut -d. -f1)
        if [[ -n "$npm_major" ]] && [[ "$npm_major" -lt 11 ]]; then
            echo "npm: warning: min-release-age requires npm >= 11 (found npm ${npm_major}.x)" >&2
        fi
    fi
    set_npmrc_key npm min-release-age "$1"
}

set_pnpm() {
    set_npmrc_key pnpm minimum-release-age "$1"
}

set_yarn() {
    local days="$1"
    local minutes
    minutes=$(duration_for_tool "$days" yarn)
    ensure_profile_dir

    if ! find_in_profiles "cooldowns:yarn:start" &>/dev/null; then
        if [[ -n "${YARN_NPM_MINIMAL_AGE_GATE:-}" ]]; then
            echo "yarn: YARN_NPM_MINIMAL_AGE_GATE is already set to '$YARN_NPM_MINIMAL_AGE_GATE', skipping"
            return
        fi
        local existing_file
        if existing_file=$(find_in_profiles "YARN_NPM_MINIMAL_AGE_GATE="); then
            echo "yarn: YARN_NPM_MINIMAL_AGE_GATE is already configured in $existing_file, skipping"
            return
        fi
    fi

    clean_previous yarn "$PROFILE_SCRIPT"

    cat >> "$PROFILE_SCRIPT" << SHELL
# cooldowns:yarn:start
export YARN_NPM_MINIMAL_AGE_GATE="$minutes"
# cooldowns:yarn:end
SHELL
    echo "yarn: set YARN_NPM_MINIMAL_AGE_GATE=$minutes in $PROFILE_SCRIPT"
    echo "  note: yarn usually reads from .yarnrc.yml per-project; add 'npmMinimalAgeGate: $minutes' there too"
}

set_bun() {
    local days="$1"
    local duration
    duration=$(duration_for_tool "$days" bun)
    local bunfig="${HOME}/.bunfig.toml"

    if [[ -f "$bunfig" ]] && grep -q "minimumReleaseAge" "$bunfig" 2>/dev/null; then
        local val
        val=$(extract_kv minimumReleaseAge "$bunfig" || echo "")
        echo "bun: minimumReleaseAge is already configured as $val in $bunfig, skipping"
        return
    fi

    if [[ -f "$bunfig" ]]; then
        if grep -q '^\[install\]' "$bunfig"; then
            # Insert `minimumReleaseAge = ...` right after the [install] header.
            # Use awk for portability: BSD sed's `a` command has different
            # syntax than GNU sed's.
            local tmp
            # mktemp files are often 0600; copy_mode_from matches bunfig mode on $tmp before mv.
            tmp=$(mktemp)
            awk -v line="minimumReleaseAge = $duration" '
                { print }
                /^\[install\][[:space:]]*$/ && !done { print line; done=1 }
            ' "$bunfig" > "$tmp" && copy_mode_from "$bunfig" "$tmp" && mv "$tmp" "$bunfig"
        else
            printf '\n[install]\nminimumReleaseAge = %s\n' "$duration" >> "$bunfig"
        fi
    else
        printf '[install]\nminimumReleaseAge = %s\n' "$duration" > "$bunfig"
    fi
    echo "bun: set minimumReleaseAge = $duration in $bunfig"
}

set_deno() {
    local days="$1"
    local duration
    duration=$(duration_for_tool "$days" deno)
    ensure_profile_dir
    clean_previous deno "$PROFILE_SCRIPT"

    cat >> "$PROFILE_SCRIPT" << SHELL
# cooldowns:deno:start
alias deno-update='deno update --minimum-dependency-age=$duration'
alias deno-outdated='deno outdated --minimum-dependency-age=$duration'
# cooldowns:deno:end
SHELL
    echo "deno: created aliases deno-update and deno-outdated with ${days}-day cooldown in $PROFILE_SCRIPT"
    echo "  note: deno has no persistent config for this; use 'deno-update' and 'deno-outdated' aliases"
}

set_cargo() {
    local days="$1"
    local minutes
    minutes=$(duration_for_tool "$days" cargo)
    ensure_profile_dir

    if ! find_in_profiles "cooldowns:cargo:start" &>/dev/null; then
        if [[ -n "${COOLDOWN_MINUTES:-}" ]]; then
            echo "cargo: COOLDOWN_MINUTES is already set to '$COOLDOWN_MINUTES', skipping"
            return
        fi
        local existing_file
        if existing_file=$(find_in_profiles "COOLDOWN_MINUTES="); then
            echo "cargo: COOLDOWN_MINUTES is already configured in $existing_file, skipping"
            return
        fi
    fi

    clean_previous cargo "$PROFILE_SCRIPT"

    cat >> "$PROFILE_SCRIPT" << SHELL
# cooldowns:cargo:start
export COOLDOWN_MINUTES="$minutes"
# cooldowns:cargo:end
SHELL
    echo "cargo: set COOLDOWN_MINUTES=$minutes in $PROFILE_SCRIPT (requires cargo-cooldown)"
}

do_set() {
    if [[ $# -lt 2 ]]; then
        echo "usage: cooldowns.sh set <tool> <duration>" >&2
        echo "tools: pip, uv, npm, pnpm, yarn, bun, deno, cargo" >&2
        return 1
    fi

    local tool="$1"
    local days
    days=$(parse_days "$2") || return 1

    case "$tool" in
        pip)   set_pip "$days" ;;
        uv)    set_uv "$days" ;;
        npm)   set_npm "$days" ;;
        pnpm)  set_pnpm "$days" ;;
        yarn)  set_yarn "$days" ;;
        bun)   set_bun "$days" ;;
        deno)  set_deno "$days" ;;
        cargo) set_cargo "$days" ;;
        *)
            echo "error: unknown tool '$tool'" >&2
            echo "supported: pip, uv, npm, pnpm, yarn, bun, deno, cargo" >&2
            return 1
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Check cooldowns
# ---------------------------------------------------------------------------

STATUS_OK=0
STATUS_WARN=1
STATUS_MISSING=2

check_results=()

record() {
    local tool="$1" status="$2" detail="$3"
    check_results+=("$status|$tool|$detail")
}

check_date_staleness() {
    local tool="$1" label="$2" raw_date="$3"
    local configured_date="${raw_date%%T*}"
    local configured_epoch today_epoch age_days
    configured_epoch=$(date_to_epoch "$configured_date")
    if [[ -z "$configured_epoch" ]]; then
        record "$tool" $STATUS_WARN "$label (can't parse date)"
        return
    fi
    today_epoch=$(date +%s)
    age_days=$(( (today_epoch - configured_epoch) / 86400 ))
    if [[ $age_days -gt 14 ]]; then
        record "$tool" $STATUS_WARN "$label (${age_days} days old, probably stale)"
    else
        record "$tool" $STATUS_OK "$label (${age_days}-day effective cooldown)"
    fi
}

check_pip() {
    local profile_file
    if profile_file=$(find_in_profiles "cooldowns:pip:start"); then
        local days
        # GNU date embeds "N days ago" in the emitted command; BSD/macOS uses -v-Nd.
        days=$(grep -Eo '[0-9]+ days ago' "$profile_file" 2>/dev/null | head -1 | awk '{ print $1 }') || true
        if [[ -z "$days" ]]; then
            days=$(grep -Eo -- '-v-[0-9]+d' "$profile_file" 2>/dev/null | head -1 | sed -e 's/-v-//' -e 's/d//') || true
        fi
        if [[ -n "$days" ]]; then
            record pip $STATUS_OK "shell wrapper with ${days}-day cooldown in $profile_file"
        else
            record pip $STATUS_OK "shell wrapper with cooldown in $profile_file"
        fi
        return
    fi

    # Check env var
    if [[ -n "${PIP_UPLOADED_PRIOR_TO:-}" ]]; then
        check_date_staleness pip "PIP_UPLOADED_PRIOR_TO='$PIP_UPLOADED_PRIOR_TO'" "$PIP_UPLOADED_PRIOR_TO"
        return
    fi

    # Check pip.conf
    local pip_conf=""
    for candidate in \
        "${HOME}/.config/pip/pip.conf" \
        "${HOME}/.pip/pip.conf" \
        "/etc/pip.conf" \
        "${XDG_CONFIG_HOME:-$HOME/.config}/pip/pip.conf"; do
        if [[ -f "$candidate" ]] && grep -q "uploaded-prior-to" "$candidate" 2>/dev/null; then
            pip_conf="$candidate"
            break
        fi
    done

    if [[ -n "$pip_conf" ]]; then
        local configured_date
        configured_date=$(extract_kv uploaded-prior-to "$pip_conf" || echo "")
        check_date_staleness pip "uploaded-prior-to=$configured_date in $pip_conf" "$configured_date"
        return
    fi

    # Check for unmarked PIP_UPLOADED_PRIOR_TO in profile files
    local profile_file
    if profile_file=$(find_in_profiles "PIP_UPLOADED_PRIOR_TO="); then
        local val
        val=$(extract_kv PIP_UPLOADED_PRIOR_TO "$profile_file" || echo "")
        check_date_staleness pip "PIP_UPLOADED_PRIOR_TO='$val' in $profile_file (not yet sourced)" "$val"
        return
    fi

    record pip $STATUS_MISSING "no cooldown configured"
}

check_uv() {
    if [[ -n "${UV_EXCLUDE_NEWER:-}" ]]; then
        record uv $STATUS_OK "UV_EXCLUDE_NEWER='$UV_EXCLUDE_NEWER'"
        return
    fi

    local uv_toml="${HOME}/.config/uv/uv.toml"
    if [[ -f "$uv_toml" ]] && grep -q "exclude-newer" "$uv_toml" 2>/dev/null; then
        local val
        val=$(extract_kv exclude-newer "$uv_toml" || echo "")
        record uv $STATUS_OK "exclude-newer=\"$val\" in $uv_toml"
        return
    fi

    local profile_file
    if profile_file=$(find_in_profiles "cooldowns:uv:start") \
       || profile_file=$(find_in_profiles "UV_EXCLUDE_NEWER="); then
        local val
        val=$(extract_kv UV_EXCLUDE_NEWER "$profile_file" || echo "")
        record uv $STATUS_OK "UV_EXCLUDE_NEWER=\"$val\" in $profile_file (not yet sourced)"
        return
    fi

    record uv $STATUS_MISSING "no cooldown configured"
}

check_npmrc_key() {
    local tool="$1" key="$2"
    local npmrc="${HOME}/.npmrc"
    local val
    if [[ -f "$npmrc" ]]; then
        if val=$(extract_kv "$key" "$npmrc"); then
            record "$tool" $STATUS_OK "${key}=$val in $npmrc"
            return 0
        fi
    fi
    return 1
}

check_npm() {
    local npm_major=""
    if command -v npm &>/dev/null; then
        npm_major=$(npm --version 2>/dev/null | cut -d. -f1)
    fi

    local npmrc="${HOME}/.npmrc"
    local val
    if [[ -f "$npmrc" ]]; then
        if val=$(extract_kv min-release-age "$npmrc"); then
            if [[ -n "$npm_major" ]] && [[ "$npm_major" -lt 11 ]]; then
                record npm $STATUS_WARN "min-release-age=$val in $npmrc but npm ${npm_major}.x does not enforce it (need >= 11)"
            else
                record npm $STATUS_OK "min-release-age=$val in $npmrc"
            fi
            return
        fi
    fi

    if [[ -n "$npm_major" ]]; then
        val=$(npm config get min-release-age 2>/dev/null || true)
        if [[ -n "$val" && "$val" != "undefined" ]]; then
            record npm $STATUS_OK "min-release-age=$val (npm config)"
            return
        fi
    fi

    record npm $STATUS_MISSING "no cooldown configured"
}

check_pnpm() {
    check_npmrc_key pnpm minimum-release-age && return
    record pnpm $STATUS_MISSING "no cooldown configured"
}

check_yarn() {
    if [[ -n "${YARN_NPM_MINIMAL_AGE_GATE:-}" ]]; then
        record yarn $STATUS_OK "YARN_NPM_MINIMAL_AGE_GATE=${YARN_NPM_MINIMAL_AGE_GATE} ($(minutes_to_days "$YARN_NPM_MINIMAL_AGE_GATE")d)"
        return
    fi

    local profile_file
    if profile_file=$(find_in_profiles "cooldowns:yarn:start") \
       || profile_file=$(find_in_profiles "YARN_NPM_MINIMAL_AGE_GATE="); then
        local val
        val=$(extract_kv YARN_NPM_MINIMAL_AGE_GATE "$profile_file" || echo "")
        record yarn $STATUS_OK "YARN_NPM_MINIMAL_AGE_GATE=$val ($(minutes_to_days "$val")d) in $profile_file (not yet sourced)"
        return
    fi

    record yarn $STATUS_MISSING "no cooldown configured (check per-project .yarnrc.yml)"
}

check_bun() {
    local bunfig="${HOME}/.bunfig.toml"
    if [[ -f "$bunfig" ]]; then
        local val
        if val=$(extract_kv minimumReleaseAge "$bunfig"); then
            record bun $STATUS_OK "minimumReleaseAge=\"$val\" in $bunfig"
            return
        fi
    fi

    record bun $STATUS_MISSING "no cooldown configured"
}

check_deno() {
    local profile_file
    if profile_file=$(find_in_profiles "cooldowns:deno:start"); then
        record deno $STATUS_OK "aliases configured in $profile_file"
        return
    fi

    record deno $STATUS_MISSING "no cooldown configured (deno only supports CLI flags)"
}

check_cargo() {
    if [[ -n "${COOLDOWN_MINUTES:-}" ]]; then
        record cargo $STATUS_OK "COOLDOWN_MINUTES=$COOLDOWN_MINUTES ($(minutes_to_days "$COOLDOWN_MINUTES")d, requires cargo-cooldown)"
        return
    fi

    local profile_file
    if profile_file=$(find_in_profiles "cooldowns:cargo:start") \
       || profile_file=$(find_in_profiles "COOLDOWN_MINUTES="); then
        local val
        val=$(extract_kv COOLDOWN_MINUTES "$profile_file" || echo "")
        record cargo $STATUS_OK "COOLDOWN_MINUTES=$val ($(minutes_to_days "$val")d) in $profile_file (not yet sourced)"
        return
    fi

    record cargo $STATUS_MISSING "no cooldown configured"
}

tool_is_relevant() {
    local tool="$1"
    command -v "$tool" &>/dev/null && return 0
    find_in_profiles "cooldowns:${tool}:start" &>/dev/null && return 0
    case "$tool" in
        pip)   [[ -f "${HOME}/.config/pip/pip.conf" || -f "${HOME}/.pip/pip.conf" || -n "${PIP_UPLOADED_PRIOR_TO:-}" ]] && return 0
               find_in_profiles "PIP_UPLOADED_PRIOR_TO=" &>/dev/null && return 0 ;;
        uv)    [[ -f "${HOME}/.config/uv/uv.toml" || -n "${UV_EXCLUDE_NEWER:-}" ]] && return 0
               find_in_profiles "UV_EXCLUDE_NEWER=" &>/dev/null && return 0 ;;
        npm)   [[ -f "${HOME}/.npmrc" ]] && grep -q "min-release-age" "${HOME}/.npmrc" 2>/dev/null && return 0 ;;
        pnpm)  [[ -f "${HOME}/.npmrc" ]] && grep -q "minimum-release-age" "${HOME}/.npmrc" 2>/dev/null && return 0 ;;
        bun)   [[ -f "${HOME}/.bunfig.toml" ]] && return 0 ;;
        cargo) [[ -n "${COOLDOWN_MINUTES:-}" ]] && return 0
               find_in_profiles "COOLDOWN_MINUTES=" &>/dev/null && return 0 ;;
        yarn)  [[ -n "${YARN_NPM_MINIMAL_AGE_GATE:-}" ]] && return 0
               find_in_profiles "YARN_NPM_MINIMAL_AGE_GATE=" &>/dev/null && return 0 ;;
    esac
    return 1
}

do_check() {
    echo "Checking dependency cooldown configurations..."
    echo ""

    local any_checked=false

    for tool in pip uv npm pnpm yarn bun deno cargo; do
        if tool_is_relevant "$tool"; then
            any_checked=true
            "check_${tool}"
        fi
    done

    if [[ "$any_checked" = false ]]; then
        echo "  No supported package managers found on this system."
        return 0
    fi

    local ok=0 warn=0 missing=0

    for entry in "${check_results[@]}"; do
        local status tool detail
        IFS='|' read -r status tool detail <<< "$entry"

        case $status in
            "$STATUS_OK")
                printf "  ok      %-8s %s\n" "$tool" "$detail"
                ok=$(( ok + 1 ))
                ;;
            "$STATUS_WARN")
                printf "  WARN    %-8s %s\n" "$tool" "$detail"
                warn=$(( warn + 1 ))
                ;;
            "$STATUS_MISSING")
                printf "  MISS    %-8s %s\n" "$tool" "$detail"
                missing=$(( missing + 1 ))
                ;;
        esac
    done

    echo ""
    echo "$ok configured, $warn warnings, $missing not configured"

    # Exit non-zero if anything is missing or stale -- useful for CI gates
    if [[ $warn -gt 0 || $missing -gt 0 ]]; then
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

usage() {
    cat << 'EOF'
usage: cooldowns.sh <command> [args]

commands:
  set <tool> <duration>   Configure cooldown for a package manager
  check                   Check cooldown status for all installed tools

tools: pip, uv, npm, pnpm, yarn, bun, deno, cargo

duration examples: 3d, "3 days", 7d, 1d

where configs are written (all user-wide; project-level configs are not modified):
  pip    shell wrapper      /etc/profile.d/cooldowns.sh (or ~/.zshrc / ~/.bashrc)
  uv     env var export     /etc/profile.d/cooldowns.sh (or ~/.zshrc / ~/.bashrc)
  npm    .npmrc key         ~/.npmrc
  pnpm   .npmrc key         ~/.npmrc
  yarn   env var export     /etc/profile.d/cooldowns.sh (or ~/.zshrc / ~/.bashrc)
  bun    bunfig.toml key    ~/.bunfig.toml
  deno   shell aliases      /etc/profile.d/cooldowns.sh (or ~/.zshrc / ~/.bashrc)
  cargo  env var export     /etc/profile.d/cooldowns.sh (or ~/.zshrc / ~/.bashrc)

  Fallback chooses ~/.zshrc or ~/.bashrc based on $SHELL.

examples:
  cooldowns.sh set pip 3d
  cooldowns.sh set uv "3 days"
  cooldowns.sh check
EOF
}

main() {
    if [[ $# -eq 0 ]]; then
        usage
        return 1
    fi

    local cmd="$1"
    shift

    case "$cmd" in
        set)   do_set "$@" ;;
        check) do_check ;;
        -h|--help|help) usage ;;
        *)
            echo "error: unknown command '$cmd'" >&2
            usage
            return 1
            ;;
    esac
}

main "$@"
