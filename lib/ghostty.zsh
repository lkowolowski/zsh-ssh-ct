# lib/ghostty.zsh — Ghostty terminal integration
# Dynamic background colors for SSH sessions via OSC 11/111.
#
# Dependencies: zsh (no external tools)
#
# shellcheck shell=bash
# ─────────────────────────────────────────────────────────────────────────────

# Guard
[[ -n "${_SSH_GHOSTTY_LOADED}" ]] && return 0
typeset -g _SSH_GHOSTTY_LOADED=1

# Cached original background color (from OSC 11 query or config parse)
typeset -g _SSH_GHOSTTY_SAVED_BG=""

# Parsed YAML config (set once by _ssh_ghostty_load_config)
typeset -gA _SSH_GHOSTTY_CFG=()

# ---------------------------------------------------------------------------
# _ssh_ghostty_detect  — check if running under Ghostty
# Returns 0 if Ghostty, 1 otherwise
# ---------------------------------------------------------------------------
_ssh_ghostty_detect() {
    [[ "${TERM_PROGRAM}" == "ghostty" ]]
}

# ---------------------------------------------------------------------------
# _ssh_ghostty_query_bg  — query Ghostty for current background color via OSC 11
#
# Sends ESC ] 11 ; ? BEL, reads the response in raw mode, extracts the color.
# Falls back to reading the Ghostty config file if the query times out.
#
# Prints the color string (e.g. "rgb:1a1a/2a2a/3a3a" or "#1a1a2a") on stdout
# Returns 0 on success, 1 on failure.
# ---------------------------------------------------------------------------
_ssh_ghostty_query_bg() {
    # Must be on a tty for terminal I/O
    [[ -t 1 ]] || return 1

    local old_tty response color

    # Save terminal attrs, set raw mode with 500ms timeout
    old_tty=$(stty -g 2>/dev/null) || return 1
    stty raw -echo min 0 time 5 2>/dev/null || return 1

    # Send OSC 11 query (BEL terminator)
    printf '\e]11;?\a'

    # Read up to 256 bytes of response
    response=$(dd bs=256 count=1 2>/dev/null)

    # Restore terminal
    stty "${old_tty}" 2>/dev/null

    [[ -z "${response}" ]] && return 1

    # Extract color: response is ESC ] 11 ; <color> ST
    # Remove leading "11;", strip trailing control chars
    color="${response#*11;}"
    color="${color%%[[:cntrl:]]*}"
    color="${color%%$'\e'*}"
    color="$(_ssh_ghostty_rtrim "${color}")"

    # Validate we got something useful (not the query echo)
    [[ -z "${color}" || "${color}" == *\?* ]] && return 1

    print -r -- "${color}"
}

# ---------------------------------------------------------------------------
# _ssh_ghostty_read_cfg_bg  — read Ghostty config file for 'background' value
#
# Checks all standard Ghostty config locations, extracts the first
# non-comment "background = ..." value found.
#
# Prints the value (e.g. "#1a1a2a") on stdout, returns 0 on success.
# ---------------------------------------------------------------------------
_ssh_ghostty_read_cfg_bg() {
    local -a config_paths=(
        "${HOME}/.config/ghostty/config"
        "${HOME}/.config/ghostty/config.ghostty"
        "${HOME}/Library/Application Support/com.mitchellh.ghostty/config"
        "${HOME}/Library/Application Support/com.mitchellh.ghostty/config.ghostty"
    )

    local file line val
    for file in "${config_paths[@]}"; do
        [[ -r "${file}" ]] || continue
        while IFS= read -r line; do
            # Skip comments and blank lines
            [[ "${line}" =~ ^[[:space:]]*# ]] && continue
            [[ "${line}" =~ ^[[:space:]]*$ ]] && continue

            # Check for "background = ..."
            if [[ "${line}" =~ ^[[:space:]]*background[[:space:]]*= ]]; then
                val="${line#*=}"
                val="${val##[[:space:]]}"
                val="${val%%[[:space:]]}"
                # Strip optional quotes
                val="${val#\"}"; val="${val%\"}"
                val="${val#'}"; val="${val%'}"
                [[ -n "${val}" ]] && print -r -- "${val}" && return 0
            fi
        done < "${file}"
    done

    return 1
}

# ---------------------------------------------------------------------------
# _ssh_ghostty_save_bg  — cache current background color
#
# Tries OSC 11 query first (captures runtime-set colors), falls back to
# parsing the Ghostty config file (captures config-file colors).
# Stores result in _SSH_GHOSTTY_SAVED_BG.
# ---------------------------------------------------------------------------
_ssh_ghostty_save_bg() {
    local saved

    saved=$(_ssh_ghostty_query_bg) || saved=$(_ssh_ghostty_read_cfg_bg) || return 1

    _SSH_GHOSTTY_SAVED_BG="${saved}"
}

# ---------------------------------------------------------------------------
# _ssh_ghostty_ltrim / _ssh_ghostty_rtrim  — whitespace trim helpers
# ---------------------------------------------------------------------------
_ssh_ghostty_ltrim() {
    local s="${1}"
    print -r -- "${s#"${s%%[^ ]*}"}"
}

_ssh_ghostty_rtrim() {
    local s="${1}"
    print -r -- "${s%"${s##*[^ ]}"}"
}

# ---------------------------------------------------------------------------
# _ssh_ghostty_load_config  — parse the ghostty-bg YAML config
#
# Reads _SSH_GHOSTTY_BG_CONFIG (if it exists) and populates
# _SSH_GHOSTTY_CFG with profile → color mappings.
# Format:
#   j: "#1A3A2A"
#   c: "#1A2A3A"
# ---------------------------------------------------------------------------
_ssh_ghostty_load_config() {
    local config_file="${_SSH_GHOSTTY_BG_CONFIG}"

    # Clear any previously parsed values
    _SSH_GHOSTTY_CFG=()

    [[ -f "${config_file}" ]] || return 1

    setopt localoptions noextendedglob

    local line key val
    while IFS= read -r line; do
        # Strip inline comments (quote-aware)
        # For YAML, # is comment unless inside quotes — keep it simple:
        # strip # only when not preceded by a quote char on the line
        if [[ "${line}" != *"'"* ]] && [[ "${line}" != *'"'* ]]; then
            line="${line%%#*}"
        fi

        # Skip blank lines
        line="$(_ssh_ghostty_rtrim "${line}")"
        [[ -z "${line}" ]] && continue

        # Parse "key: value"
        [[ "${line}" != *:* ]] && continue

        key="${line%%:*}"
        key="$(_ssh_ghostty_rtrim "${key}")"

        val="${line#*:}"
        val="$(_ssh_ghostty_ltrim "${val}")"
        # Strip optional quotes
        val="${val#\"}"; val="${val%\"}"
        val="${val#'}"; val="${val%'}"

        # null/no/null means no color
        [[ "${val:l}" == "null" || "${val:l}" == "~" || "${val:l}" == "none" ]] && val=""

        # Only store recognized profile keys
        case "${key}" in
            j|c|p|u) _SSH_GHOSTTY_CFG["${key}"]="${val}" ;;
        esac
    done < "${config_file}"
}

# ---------------------------------------------------------------------------
# _ssh_ghostty_resolve  — resolve background color for a profile flag
#
# Layering (highest priority first):
#   1. Config file default for profile (_SSH_GHOSTTY_CFG)
#   2. Env var (_SSH_GHOSTTY_BG_J/C/P/U)
#   3. Built-in hardcoded defaults
#   4. Empty string → no change
#
# Prints the color string on stdout, returns 0.
# ---------------------------------------------------------------------------
_ssh_ghostty_resolve() {
    local profile_flag="${1}"

    # 1. Config file
    local cfg_color="${_SSH_GHOSTTY_CFG[${profile_flag}]}"
    if [[ -n "${cfg_color}" ]]; then
        print -r -- "${cfg_color}"
        return 0
    fi

    # 2. Env var (e.g. _SSH_GHOSTTY_BG_J)
    local var_name="_SSH_GHOSTTY_BG_${(U)profile_flag}"
    local env_color="${(P)var_name}"
    if [[ -n "${env_color}" ]]; then
        print -r -- "${env_color}"
        return 0
    fi

    # 3. Built-in defaults
    case "${profile_flag}" in
        j) print -r -- "#1A3A2A"; return 0 ;;
        c) print -r -- "#1A2A3A"; return 0 ;;
        p) print -r -- "#3A1A1A"; return 0 ;;
    esac

    # 4. No change (Unix profile or unrecognized)
    return 0
}

# ---------------------------------------------------------------------------
# _ssh_ghostty_set_bg  — set Ghostty background via OSC 11
#
# Saves the current background on first call (via _ssh_ghostty_save_bg),
# then resolves the target color for the profile and sends OSC 11.
# ---------------------------------------------------------------------------
_ssh_ghostty_set_bg() {
    (( _SSH_GHOSTTY_BG_ENABLE )) || return
    _ssh_ghostty_detect || return

    local profile_flag="${1}"
    [[ -z "${profile_flag}" ]] && return

    # Load config on first use
    if (( ${#_SSH_GHOSTTY_CFG[@]} == 0 )); then
        _ssh_ghostty_load_config
    fi

    # Save current background on first call (only once)
    if [[ -z "${_SSH_GHOSTTY_SAVED_BG}" ]]; then
        _ssh_ghostty_save_bg
    fi

    # Resolve target color
    local color
    color="$(_ssh_ghostty_resolve "${profile_flag}")"
    [[ -z "${color}" ]] && return

    # Sanitize: ensure color starts with # or rgb: or rrggbb
    case "${color}" in
        \#*|rgb:*|rgba:*) ;;
        [0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]*) color="#${color}" ;;
        *) return ;;
    esac

    printf '\e]11;%s\a' "${color}"
}

# ---------------------------------------------------------------------------
# _ssh_ghostty_reset_bg  — restore original background via OSC 11/111
#
# If a saved background exists, restores it via OSC 11.
# Otherwise sends OSC 111 (reset to config default).
# ---------------------------------------------------------------------------
_ssh_ghostty_reset_bg() {
    (( _SSH_GHOSTTY_BG_ENABLE )) || return
    _ssh_ghostty_detect || return

    if [[ -n "${_SSH_GHOSTTY_SAVED_BG}" ]]; then
        printf '\e]11;%s\a' "${_SSH_GHOSTTY_SAVED_BG}"
    else
        printf '\e]111\a'
    fi
}
