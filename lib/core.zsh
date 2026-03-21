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
        Darwin) ping -c1 -t2  -q "${host}" &>/dev/null 2>&1 ;;
        Linux)  ping -c1 -W2  -q "${host}" &>/dev/null 2>&1 ;;
        *)      ping -c1 -W2     "${host}" &>/dev/null 2>&1 \
             || ping -c1 -t2     "${host}" &>/dev/null 2>&1 ;;
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
    if   command -v getent   &>/dev/null; then getent hosts "${host}"   &>/dev/null && return 0
    elif command -v host     &>/dev/null; then host     "${host}"       &>/dev/null && return 0
    elif command -v nslookup &>/dev/null; then nslookup "${host}"       &>/dev/null && return 0
    fi
    # Last resort: 1-second TCP probe to port 22 (works when ICMP is blocked)
    if command -v nc &>/dev/null; then
        nc -z -w1 "${host}" 22 &>/dev/null && return 0
    fi
    return 1
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
    if [[ -r "${HOME}/.ssh/known_hosts" ]]; then
        while IFS= read -r line; do
            [[ "${line}" == \|* ]] && continue
            local hf="${line%% *}"
            # known_hosts allows comma-separated name,ip pairs — split them
            local -a hf_parts=( ${(s:,:)hf} )
            for hf in "${hf_parts[@]}"; do
                hf="${hf#\[}"; hf="${hf%%\]*}"; hf="${hf%%:*}"
                [[ -n "${hf}" ]] && candidates+=("${hf}")
            done
        done < "${HOME}/.ssh/known_hosts"
    fi

    # ~/.ssh/config Host entries (skip wildcards)
    if [[ -r "${HOME}/.ssh/config" ]]; then
        while IFS= read -r line; do
            if [[ "${line}" =~ ^[[:space:]]*[Hh]ost[[:space:]] ]]; then
                local hval="${line#*[Hh]ost }"
                for h in ${=hval}; do
                    [[ "${h}" == *\** || "${h}" == *\?* ]] && continue
                    candidates+=("${h}")
                done
            fi
        done < "${HOME}/.ssh/config"
    fi

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

    local candidate lc_candidate lc_query
    local -i score ci qi qlen clen

    for candidate in "${unique_candidates[@]}"; do
        lc_candidate="${candidate:l}"
        lc_query="${query:l}"
        score=0

        [[ "${lc_candidate}" == *"${lc_query}"* ]] && (( score += 15 ))
        [[ "${lc_candidate}" == "${lc_query}"*  ]] && (( score += 5  ))

        # Sequential character scan
        ci=0; qi=0
        qlen=${#lc_query}
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
  _SSH_CT_CONFIG_DIR   Config dir     (current: ${_SSH_CT_CONFIG_DIR})
  _SSH_CACHE_FILE      Cache path     (current: ${_SSH_CACHE_FILE})
  _SSH_MAX_RETRIES     Max retries    (current: ${_SSH_MAX_RETRIES})
  _SSH_RETRY_SLEEP     Retry delay    (current: ${_SSH_RETRY_SLEEP}s)
  _SSH_CACHE_TTL_DAYS  Cache TTL      (current: ${_SSH_CACHE_TTL_DAYS}d, 0=forever)
  _SSH_FUZZY_CONFIRM   Confirm fuzzy  (current: ${_SSH_FUZZY_CONFIRM})
EOF
}

# ---------------------------------------------------------------------------
# Core _ssh function
# ---------------------------------------------------------------------------
_ssh() {
    # ── Guard: ct must be available ──────────────────────────────────────────
    if ! command -v ct &>/dev/null; then
        echo "[_ssh] Error: 'ct' (ChromaTerm) not found in \$PATH." >&2
        echo "[_ssh] Install with: pip3 install chromaterm" >&2
        return 1
    fi

    # ── Parse arguments ───────────────────────────────────────────────────────
    local profile_flag="" verbose_flag="" exact_host="" dry_run=0
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

    local yaml_file="${_SSH_PROFILE_MAP[$profile_flag]}"
    if [[ -z "${yaml_file}" ]]; then
        echo "[_ssh] Error: unknown profile flag '-${profile_flag}'." >&2
        return 1
    fi

    # ── Resolve ct config ─────────────────────────────────────────────────────
    local ct_config="${_SSH_CT_CONFIG_DIR}/${yaml_file}"
    if [[ ! -f "${ct_config}" ]]; then
        echo "[_ssh] Warning: ct config not found at '${ct_config}'. Using ct default." >&2
        ct_config=""
    fi

    # ── Detect bare IP addresses — treat like -H (skip fuzzy matching) ───────
    local ipv4_regex='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
    local ipv6_regex='^[0-9a-fA-F:]+:[0-9a-fA-F:]*$'
    if [[ -z "${exact_host}" && ( "${host}" =~ ${ipv4_regex} || "${host}" =~ ${ipv6_regex} ) ]]; then
        exact_host="${host}"
    fi

    # ── Fuzzy match (single call) ─────────────────────────────────────────────
    local resolved_host fuzzy_matched=0

    if [[ -n "${exact_host}" ]]; then
        # -H flag or IP address: bypass fuzzy matching entirely
        resolved_host="${exact_host}"
    else
        local _fuzzy_result
        _fuzzy_result="$(_ssh_fuzzy_match "${host}")"
        local _fuzzy_rc=$?
        if (( _fuzzy_rc == 0 )) && [[ "${_fuzzy_result}" != "${host}" ]]; then
            resolved_host="${_fuzzy_result}"
            fuzzy_matched=1
        else
            resolved_host="${host}"
        fi
    fi

    if (( fuzzy_matched )); then
        echo "[_ssh] Fuzzy matched '${host}' → '${resolved_host}'"
        if (( _SSH_FUZZY_CONFIRM )); then
            printf '[_ssh] Connect to %s? [Y/n] ' "${resolved_host}"
            local reply
            # Read from /dev/tty explicitly so it works even when stdin is redirected
            read -r reply </dev/tty
            case "${reply:l}" in
                n|no) echo "[_ssh] Aborted."; return 1 ;;
            esac
        fi
    fi

    # ── Show resolved ct config path ──────────────────────────────────────────
    local ct_config_display
    [[ -n "${ct_config}" ]] && ct_config_display="${ct_config}" || ct_config_display="(ct default)"

    # ── Build command arrays ──────────────────────────────────────────────────
    local -a ct_cmd ssh_extra_flags ssh_cmd

    if [[ -n "${ct_config}" ]]; then
        ct_cmd=( ct -c "${ct_config}" )
    else
        ct_cmd=( ct )
    fi

    [[ -n "${verbose_flag}" ]] && ssh_extra_flags+=( "${verbose_flag}" )

    if (( ${#remote_cmd[@]} > 0 )); then
        ssh_cmd=( ssh "${ssh_extra_flags[@]}" "${resolved_host}" "${remote_cmd[@]}" )
    else
        ssh_cmd=( ssh "${ssh_extra_flags[@]}" "${resolved_host}" )
    fi

    # ── Dry run ───────────────────────────────────────────────────────────────
    if (( dry_run )); then
        echo "[_ssh] Dry run — resolved command:"
        echo "  ${ct_cmd[*]} ${ssh_cmd[*]}"
        echo "[_ssh] ct config: ${ct_config_display}"
        return 0
    fi

    # ── Retry loop ────────────────────────────────────────────────────────────
    local -i attempt=0 max_retries=${_SSH_MAX_RETRIES} sleep_sec=${_SSH_RETRY_SLEEP}
    local profile_name="${_SSH_PROFILE_NAMES[$profile_flag]}"

    local red=$'\033[0;31m'
    local green=$'\033[0;32m'
    local reset=$'\033[0m'
    local clreol=$'\033[K'

    local status_prefix="[_ssh] ${resolved_host} (${profile_name})"
    local marks=""

    # Print the initial status line without a newline
    printf '%s%s' "${clreol}" "${status_prefix}"

    while (( attempt < max_retries )); do
        (( attempt++ ))

        # ── DNS check — skip for IPs, fatal for hostnames ──────────────────
        if [[ -z "${exact_host}" ]] && ! _ssh_resolves "${resolved_host}"; then
            printf '\n'
            echo "[_ssh] Error: '${resolved_host}' does not resolve. Check the hostname or DNS." >&2
            return 1
        fi

        # ── Ping ───────────────────────────────────────────────────────────
        if _ssh_ping "${resolved_host}"; then
            printf '\r%s\n' "${clreol}"
            printf "[_ssh] ${green}✓${reset} ${resolved_host}  |  profile: ${profile_name}  |  config: ${ct_config_display}\n"
            _ssh_cache_add "${resolved_host}" "${profile_flag}"

            "${ct_cmd[@]}" "${ssh_cmd[@]}"
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
}
