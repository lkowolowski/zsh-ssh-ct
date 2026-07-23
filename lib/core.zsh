# lib/core.zsh — Core _ssh() function, ping helper, and usage
#
# shellcheck shell=bash
# ─────────────────────────────────────────────────────────────────────────────

# ---------------------------------------------------------------------------
# Portable ping helper
# Detects OS once at source time and sets a flag rather than calling uname
# on every ping attempt.
# ---------------------------------------------------------------------------
_ssh_ping() {
    local host="${1}"
    case "${_SSH_OS}" in
        Darwin) ping -c1 -t2  -q "${host}" &>/dev/null ;;
        Linux)  ping -c1 -W2  -q "${host}" &>/dev/null ;;
        *)      ping -c1 -W2     "${host}" &>/dev/null \
             || ping -c1 -t2     "${host}" &>/dev/null ;;
    esac
}

# Detect OS once at source time
typeset -g _SSH_OS
_SSH_OS="$(uname -s 2>/dev/null)"

# ---------------------------------------------------------------------------
# DNS resolution check (distinct from ping / ICMP reachability)
# Returns 0 if the name resolves, 1 if DNS fails entirely.
# ---------------------------------------------------------------------------
_ssh_resolves() {
    local host="${1}"
    if   command -v host     &>/dev/null; then host     "${host}"       &>/dev/null && return 0
    elif command -v nslookup &>/dev/null; then nslookup "${host}"       &>/dev/null && return 0
    elif command -v getent   &>/dev/null; then getent hosts "${host}"   &>/dev/null && return 0
    fi
    # Last resort: 1-second TCP probe to port 22 (works when ICMP is blocked)
    if command -v nc &>/dev/null; then
        nc -z -w1 "${host}" 22 &>/dev/null && return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# Read known_hosts — prints one hostname per line to stdout.
# Skips hashed entries, splits comma-separated groups, strips port/IPv6 zone.
# ---------------------------------------------------------------------------
_ssh_read_known_hosts() {
    local kh="${1:-${HOME}/.ssh/known_hosts}"
    [[ -r "${kh}" ]] || return 1
    while IFS= read -r line; do
        [[ "${line}" == \|* ]] && continue
        local hf="${line%% *}"
        local -a hf_parts=( ${(s:,:)hf} )
        for hf in "${hf_parts[@]}"; do
            hf="${hf#\[}"; hf="${hf%%\]*}"; hf="${hf%%:*}"
            [[ -n "${hf}" ]] && print -- "${hf}"
        done
    done < "${kh}"
}

# ---------------------------------------------------------------------------
# Read ~/.ssh/config Host entries — prints hostnames to stdout.
# Skips wildcard patterns (*, ?).
# ---------------------------------------------------------------------------
_ssh_read_ssh_config_hosts() {
    local cfg="${1:-${HOME}/.ssh/config}"
    [[ -r "${cfg}" ]] || return 1
    while IFS= read -r line; do
        if [[ "${line}" =~ ^[[:space:]]*[Hh]ost[[:space:]] ]]; then
            local hval="${line#*[Hh]ost }"
            for h in ${=hval}; do
                [[ "${h}" == *\** || "${h}" == *\?* ]] && continue
                print -- "${h}"
            done
        fi
    done < "${cfg}"
}

# ---------------------------------------------------------------------------
# Usage / help
# ---------------------------------------------------------------------------
_ssh_usage() {
    cat <<EOF
${_SSH_PLUGIN_NAME} v${_SSH_PLUGIN_VERSION}

Usage: _ssh -<profile> <host> [remote_command] [-v] [-n]

Profiles:
  -j  Juniper        (ct -c ${_SSH_CT_CONFIG_DIR}/juniper.yml)
  -c  Cisco          (ct -c ${_SSH_CT_CONFIG_DIR}/cisco.yml)
  -p  PAN-OS         (ct -c ${_SSH_CT_CONFIG_DIR}/panos.yml)
  -u  Unix / Linux   (ct -c ${_SSH_CT_CONFIG_DIR}/unix.yml)

Options:
  -v         Pass verbose flag to ssh
  -n         Dry run — print the resolved command without executing
  -f         Force — skip ping/DNS checks, try SSH immediately

Examples:
  _ssh -j core-router
  _ssh -c access-switch "show version"
  _ssh -u web-server "uname -a"
  _ssh -p fw-01 -v
  _ssh -j rtr -n

Configuration (set in .zshrc before loading):
  _SSH_CT_CONFIG_DIR          Config dir         (current: ${_SSH_CT_CONFIG_DIR})
  _SSH_MAX_RETRIES            Max retries        (current: ${_SSH_MAX_RETRIES})
  _SSH_RETRY_SLEEP            Retry delay        (current: ${_SSH_RETRY_SLEEP}s)
  _SSH_REMOTE_CMDS            Init-cmds YAML     (current: ${_SSH_REMOTE_CMDS})
  _SSH_INIT_CMD_SKIP_PROFILES Init-cmd skip      (current: ${_SSH_INIT_CMD_SKIP_PROFILES})
EOF
}

# ---------------------------------------------------------------------------
# _ssh_build_ssh_cmd  — assemble ct + ssh command arrays
#
# Shared by _ssh() (core.zsh) and _ssh_init_execute() (init.zsh) so the
# ct-availability / ct-config branching lives in exactly one place.
#
# Args: <ct_available> <ct_config> <verbose_flag> <ssh_target> [remote_cmd...]
# Sets globals: _SSH_BUILT_CT_CMD, _SSH_BUILT_SSH_CMD
# ---------------------------------------------------------------------------
_ssh_build_ssh_cmd() {
    local -i ct_available="${1}"
    local ct_config="${2}" verbose_flag="${3}" ssh_target="${4}"
    shift 4
    local -a remote_cmd=( "${@}" )

    local -a ssh_extra_flags
    [[ -n "${verbose_flag}" ]] && ssh_extra_flags+=( "${verbose_flag}" )

    typeset -ga _SSH_BUILT_CT_CMD=()
    if (( ct_available )) && [[ -n "${ct_config}" ]]; then
        _SSH_BUILT_CT_CMD=( ct -c "${ct_config}" )
    elif (( ct_available )); then
        _SSH_BUILT_CT_CMD=( ct )
    fi

    if (( ${#remote_cmd[@]} > 0 )); then
        typeset -ga _SSH_BUILT_SSH_CMD=( ssh "${ssh_extra_flags[@]}" "${ssh_target}" "${remote_cmd[@]}" )
    else
        typeset -ga _SSH_BUILT_SSH_CMD=( ssh "${ssh_extra_flags[@]}" "${ssh_target}" )
    fi
}

# ---------------------------------------------------------------------------
# Core _ssh function
# ---------------------------------------------------------------------------
# shellcheck disable=SC1072,SC1073,SC1056,SC1141
_ssh() {
    # Wrap entire execution body so _ssh_ghostty_reset_bg runs on every exit
    # path (normal return, error, SIGINT, etc.).
    {
    # ── ct is optional — fall back to plain ssh if not installed ─────────────
    local ct_available=0
    command -v ct &>/dev/null && ct_available=1

    # ── Parse arguments ───────────────────────────────────────────────────────
    local profile_flag="" verbose_flag="" dry_run=0 force_flag=0
    local host=""
    local -a remote_cmd args=( "$@" )
    local -i i=0 nargs=${#args[@]}

    while (( i < nargs )); do
        local arg="${args[i+1]}"
        case "${arg}" in
            -j|-c|-p|-u)
                if [[ -n "${profile_flag}" ]]; then
                    echo "[_ssh] Error: multiple profile flags specified." >&2
                    return 1
                fi
                profile_flag="${arg#-}"
                ;;
            -v) verbose_flag="-v" ;;
            -n) dry_run=1 ;;
            -f) force_flag=1 ;;
            -h|--help) _ssh_usage; return 0 ;;
            -*)
                echo "[_ssh] Unknown option: ${arg}" >&2
                _ssh_usage
                return 1
                ;;
            *)
                if [[ -z "${host}" ]]; then
                    host="${arg}"
                else
                    remote_cmd+=("${arg}")
                fi
                ;;
        esac
        (( i++ ))
    done

    # ── Validate ──────────────────────────────────────────────────────────────
    if [[ -z "${profile_flag}" ]]; then
        echo "[_ssh] Error: a profile flag (-j, -c, -p, -u) is required." >&2
        _ssh_usage; return 1
    fi
    if [[ -z "${host}" ]]; then
        echo "[_ssh] Error: no host specified." >&2
        _ssh_usage; return 1
    fi
    # ── Split user@host — preserve full string for ssh, extract host for ping ──
    # Handles: host, user@host, user:password@host, user:port@host
    # The ssh_target is passed to ssh as-is; ping_host is used for DNS/ping.
    local ssh_target="${host}"
    local ping_host="${host}"
    if [[ "${host}" == *@* ]]; then
        ping_host="${host##*@}"
    fi

    # ── Resolve ct config — fall back to generic.yml if profile file missing ────
    local ct_config=""
    if (( ct_available )); then
        local yaml_file="${_SSH_PROFILE_MAP[$profile_flag]}"
        local ct_profile="${_SSH_CT_CONFIG_DIR}/${yaml_file}"
        local ct_generic="${_SSH_CT_CONFIG_DIR}/generic.yml"
        if [[ -f "${ct_profile}" ]]; then
            ct_config="${ct_profile}"
        elif [[ -f "${ct_generic}" ]]; then
            echo "[_ssh] Warning: '${yaml_file}' not found — falling back to generic.yml." >&2
            ct_config="${ct_generic}"
        else
            echo "[_ssh] Warning: no ct config found. Using ct default." >&2
        fi
    fi

    # ── Show resolved ct config path ──────────────────────────────────────────
    local ct_config_display
    if (( ! ct_available )); then
        ct_config_display="(no ct)"
    elif [[ -n "${ct_config}" ]]; then
        ct_config_display="${ct_config:t}"
    else
        ct_config_display="(ct default)"
    fi

    # ── Build command arrays ──────────────────────────────────────────────────
    _ssh_build_ssh_cmd "${ct_available}" "${ct_config}" "${verbose_flag}" \
        "${ssh_target}" "${remote_cmd[@]}"
    local -a ct_cmd=( "${_SSH_BUILT_CT_CMD[@]}" )
    local -a ssh_cmd=( "${_SSH_BUILT_SSH_CMD[@]}" )

    # ── Dry run ───────────────────────────────────────────────────────────────
    if (( dry_run )); then
        echo "[_ssh] Dry run — resolved command:"
        echo "  ${ct_cmd[*]} ${ssh_cmd[*]}"
        echo "[_ssh] ct config: ${ct_config_display}"
        return 0
    fi

    # ── Set Ghostty background before SSH execution ─────────────────────────
    # This runs after all validation passes. The always block at the end of
    # the function restores the original background on any exit path.
    _ssh_ghostty_set_bg "${profile_flag}"

    local profile_name="${_SSH_PROFILE_NAMES[$profile_flag]}"
    local red=$'\033[0;31m'
    local green=$'\033[0;32m'
    local reset=$'\033[0m'

    # ── Force mode: skip ping / DNS, try SSH immediately ─────────────────────
    if (( force_flag )); then
        printf "[_ssh] ${green}✓${reset} ${ssh_target}  |  profile: ${profile_name}  |  force\n"
        if (( ${#ct_cmd[@]} > 0 )); then
            "${ct_cmd[@]}" "${ssh_cmd[@]}"
        else
            "${ssh_cmd[@]}"
        fi
        return $?
    fi

    # ── Retry loop ────────────────────────────────────────────────────────────
    local -i attempt=0 max_retries=${_SSH_MAX_RETRIES} sleep_sec=${_SSH_RETRY_SLEEP}

    local clreol=$'\033[K'

    local status_prefix="[_ssh] ${ssh_target} (${profile_name})"
    local marks=""

    # Print the initial status line without a newline
    printf '%s%s' "${clreol}" "${status_prefix}"

    # ── DNS check — fatal if hostname doesn't resolve ──────────────────────
    if ! _ssh_resolves "${ping_host}"; then
        printf '\n'
        echo "[_ssh] Error: '${ping_host}' does not resolve. Check the hostname or DNS." >&2
        return 1
    fi

    while (( attempt < max_retries )); do
        (( attempt++ ))

        # ── Ping ───────────────────────────────────────────────────────────
        if _ssh_ping "${ping_host}"; then
            printf '\r%s\n' "${clreol}"
            printf "[_ssh] ${green}✓${reset} ${ssh_target}  |  profile: ${profile_name}\n"

            # Try init-commands first (replaces normal SSH if commands found)
            local -i init_exit
            _ssh_init_execute "${profile_flag}" "${ping_host}" \
                "${ssh_target}" "${ct_config}" "${verbose_flag:-}" \
                "${ct_available}" "${remote_cmd[@]}"
            init_exit=$?

            if (( init_exit == 0 )) && _ssh_init_did_run; then
                return "${init_exit}"
            fi

            if (( ${#ct_cmd[@]} > 0 )); then
                "${ct_cmd[@]}" "${ssh_cmd[@]}"
            else
                "${ssh_cmd[@]}"
            fi
            local -i exit_code=$?

            if (( exit_code == 255 )); then
                echo "[_ssh] SSH connection failed (exit 255)." >&2
            fi
            return "${exit_code}"
        fi

        # ── Ping failed — append a red ✗ and sleep ─────────────────────────
        marks+=" ${red}✗${reset}"
        printf '\r%s%s%s' "${clreol}" "${status_prefix}" "${marks}"

        if (( attempt >= max_retries )); then
            printf '\n'
            echo "[_ssh] Max retries (${max_retries}) reached. Host '${ping_host}' unreachable." >&2
            return 1
        fi

        sleep "${sleep_sec}"
    done

    return 1
    } always {
        _ssh_ghostty_reset_bg
    }
}
