# lib/core.zsh — Core _ssh() function, ping helper, fuzzy matcher, usage
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
# Fuzzy host matching
#
# Collects candidate hostnames from /etc/hosts, ~/.ssh/known_hosts,
# ~/.ssh/config, and the host cache, scores them against the query, and
# prints the best match.  Returns 0 if a real match was found (score > 2),
# 1 if the original query is returned unchanged.
#
# Called ONCE — callers capture both stdout and return code together:
#
#   local result rc
#   result="$(_ssh_fuzzy_match "${query}")"
#   rc=$?
# ---------------------------------------------------------------------------
_ssh_fuzzy_match() {
    local query="${1}"
    local -a candidates

    # 1. Gather candidates ──────────────────────────────────────────────────

    # /etc/hosts (skip comments and blank lines)
    if [[ -r /etc/hosts ]]; then
        while IFS= read -r line; do
            [[ "${line}" =~ ^[[:space:]]*# ]] && continue
            [[ "${line}" =~ ^[[:space:]]*$ ]] && continue
            local fields=( ${=line} )
            for f in "${fields[@]:1}"; do
                [[ -n "${f}" ]] && candidates+=("${f}")
            done
        done < /etc/hosts
    fi

    # ~/.ssh/known_hosts (skip hashed entries)
    while IFS= read -r h; do
        candidates+=("${h}")
    done < <(_ssh_read_known_hosts)

    # ~/.ssh/config Host entries (skip wildcards)
    while IFS= read -r h; do
        candidates+=("${h}")
    done < <(_ssh_read_ssh_config_hosts)

    # Host cache
    while IFS= read -r cached; do
        [[ -n "${cached}" ]] && candidates+=("${cached}")
    done < <(_ssh_cache_hosts)

    # 2. Deduplicate ────────────────────────────────────────────────────────
    local -aU unique_candidates=( "${candidates[@]}" )

    # 3. Score ──────────────────────────────────────────────────────────────
    # +15  verbatim substring match
    # +5   prefix match
    # +1   per sequential character match (fuzzy)
    # Minimum winning score: 3  (must beat threshold of 2)
    local best_host="${query}"
    local -i best_score=2

    local lc_query="${query:l}"
    local -i qlen=${#lc_query}

    local candidate lc_candidate
    local -i score ci qi clen

    for candidate in "${unique_candidates[@]}"; do
        lc_candidate="${candidate:l}"
        score=0

        [[ "${lc_candidate}" == *"${lc_query}"* ]] && (( score += 15 ))
        [[ "${lc_candidate}" == "${lc_query}"*  ]] && (( score += 5  ))

        # Sequential character scan
        ci=0; qi=0
        clen=${#lc_candidate}
        while (( qi < qlen && ci < clen )); do
            [[ "${lc_candidate[ci+1]}" == "${lc_query[qi+1]}" ]] && (( qi++ ))
            (( ci++ ))
        done
        # Sequential match only counts if all query chars were consumed AND
        # no substring bonus already awarded
        if (( qi < qlen && score < 15 )); then
            score=0
        elif (( qi == qlen && score < 15 )); then
            (( score += qi ))
        fi

        if (( score > best_score )); then
            best_score=score
            best_host="${candidate}"
        fi
    done

    print -- "${best_host}"
    (( best_score > 2 ))   # return code: 0 = real match, 1 = no match
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
  -H <host>  Exact hostname — bypass fuzzy matching entirely
  -v         Pass verbose flag to ssh
  -n         Dry run — print the resolved command without executing
  -f         Force — skip ping/DNS checks, try SSH immediately

Examples:
  _ssh -j core-router
  _ssh -c access-switch "show version"
  _ssh -u web-server "uname -a"
  _ssh -p fw-01 -v
  _ssh -j rtr -n
  _ssh -j -H core-rtr-01          # skip fuzzy matching

Cache management:
  _ssh_cache_show                  Pretty-print the cache table
  _ssh_cache_clear                 Remove all cached entries
  _ssh_cache_prune                 Remove entries older than TTL
  _ssh_cache_delete <host>         Remove a specific host from cache
  _ssh_cache_delete <host> <prof>  Remove a specific host:profile pair

Configuration (set in .zshrc before loading):
  _SSH_CT_CONFIG_DIR          Config dir         (current: ${_SSH_CT_CONFIG_DIR})
  _SSH_CACHE_FILE             Cache path         (current: ${_SSH_CACHE_FILE})
  _SSH_MAX_RETRIES            Max retries        (current: ${_SSH_MAX_RETRIES})
  _SSH_RETRY_SLEEP            Retry delay        (current: ${_SSH_RETRY_SLEEP}s)
  _SSH_CACHE_TTL_DAYS         Cache TTL          (current: ${_SSH_CACHE_TTL_DAYS}d, 0=forever)
  _SSH_FUZZY_CONFIRM          Confirm fuzzy      (current: ${_SSH_FUZZY_CONFIRM})
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
    local profile_flag="" verbose_flag="" exact_host="" dry_run=0 force_flag=0
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
            -H)
                (( i++ ))
                exact_host="${args[i+1]}"
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
    if [[ -z "${host}" && -z "${exact_host}" ]]; then
        echo "[_ssh] Error: no host specified." >&2
        _ssh_usage; return 1
    fi
    # -H overrides positional host
    [[ -n "${exact_host}" ]] && host="${exact_host}"

    # ── Split user@host — preserve full string for ssh, extract host for ping ──
    # Handles: host, user@host, user:password@host, user:port@host
    # The ssh_target is passed to ssh as-is; ping_host is used for DNS/ping/fuzzy.
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

    # ── Detect bare IP addresses — treat like -H (skip fuzzy matching) ───────
    local ipv4_regex='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
    local ipv6_regex='^[0-9a-fA-F:]+:[0-9a-fA-F:]*$'
    if [[ -z "${exact_host}" && ( "${ping_host}" =~ ${ipv4_regex} || "${ping_host}" =~ ${ipv6_regex} ) ]]; then
        exact_host="${ping_host}"
    fi

    # ── Fuzzy match on ping_host only (never on user@ prefix) ────────────────
    local resolved_host fuzzy_matched=0

    if [[ -n "${exact_host}" ]]; then
        resolved_host="${exact_host}"
    else
        local _fuzzy_result
        _fuzzy_result="$(_ssh_fuzzy_match "${ping_host}")"
        local _fuzzy_rc=$?
        if (( _fuzzy_rc == 0 )) && [[ "${_fuzzy_result}" != "${ping_host}" ]]; then
            resolved_host="${_fuzzy_result}"
            fuzzy_matched=1
        else
            resolved_host="${ping_host}"
        fi
    fi

    # Rebuild ssh_target with resolved host, preserving any user@ prefix
    if [[ "${host}" == *@* ]]; then
        local user_prefix="${host%@*}@"
        ssh_target="${user_prefix}${resolved_host}"
    else
        ssh_target="${resolved_host}"
    fi

    if (( fuzzy_matched )); then
        echo "[_ssh] Fuzzy matched '${ping_host}' → '${resolved_host}'"
        if (( _SSH_FUZZY_CONFIRM )); then
            printf '[_ssh] Connect to %s? [Y/n] ' "${ssh_target}"
            local reply
            read -r reply </dev/tty
            # shellcheck disable=SC2299
            case "${reply:l}" in
                n|no) echo "[_ssh] Aborted."; return 1 ;;
            esac
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
        _ssh_cache_add "${resolved_host}" "${profile_flag}"
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

    # ── DNS check — skip for IPs, fatal for hostnames ──────────────────────
    if [[ -z "${exact_host}" ]] && ! _ssh_resolves "${resolved_host}"; then
        printf '\n'
        echo "[_ssh] Error: '${resolved_host}' does not resolve. Check the hostname or DNS." >&2
        return 1
    fi

    while (( attempt < max_retries )); do
        (( attempt++ ))

        # ── Ping ───────────────────────────────────────────────────────────
        if _ssh_ping "${resolved_host}"; then
            printf '\r%s\n' "${clreol}"
            printf "[_ssh] ${green}✓${reset} ${ssh_target}  |  profile: ${profile_name}\n"
            _ssh_cache_add "${resolved_host}" "${profile_flag}"

            # Try init-commands first (replaces normal SSH if commands found)
            local -i init_exit
            _ssh_init_execute "${profile_flag}" "${resolved_host}" \
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
            echo "[_ssh] Max retries (${max_retries}) reached. Host '${resolved_host}' unreachable." >&2
            return 1
        fi

        sleep "${sleep_sec}"
    done

    return 1
    } always {
        _ssh_ghostty_reset_bg
    }
}
