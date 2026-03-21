# lib/cache.zsh — Host/profile cache with TTL, auto-prune, and secure init
# Cache format (one entry per line):  host:profile:epoch
#
# shellcheck shell=bash
# ─────────────────────────────────────────────────────────────────────────────

# ---------------------------------------------------------------------------
# Epoch helper — uses zsh built-in where available, forks date only as fallback
# ---------------------------------------------------------------------------
_ssh_epoch() {
    # $EPOCHSECONDS is a zsh built-in (no fork); available since zsh 5.0
    if (( ${+EPOCHSECONDS} )); then
        print -- "${EPOCHSECONDS}"
    else
        command date +%s
    fi
}

# ---------------------------------------------------------------------------
# Cache init — creates directory + file with secure permissions
# ---------------------------------------------------------------------------
_ssh_cache_init() {
    local cache_dir
    cache_dir="$(dirname "${_SSH_CACHE_FILE}")"
    if [[ ! -d "${cache_dir}" ]]; then
        mkdir -p "${cache_dir}"
        chmod 700 "${cache_dir}"
    fi
    if [[ ! -f "${_SSH_CACHE_FILE}" ]]; then
        touch "${_SSH_CACHE_FILE}"
        chmod 600 "${_SSH_CACHE_FILE}"
    fi
}

# ---------------------------------------------------------------------------
# Auto-prune on plugin load — runs at most once per day via a stamp file.
# Called from the plugin loader after all modules are sourced.
# ---------------------------------------------------------------------------
_ssh_cache_maybe_prune() {
    (( _SSH_CACHE_TTL_DAYS == 0 )) && return 0

    local stamp="${_SSH_CACHE_FILE}.pruned"
    local now
    now="$(_ssh_epoch)"

    # If stamp exists and is less than 86400s old, skip
    if [[ -f "${stamp}" ]]; then
        local stamp_ts
        stamp_ts="$(cat "${stamp}" 2>/dev/null)"
        if [[ "${stamp_ts}" =~ ^[0-9]+$ ]] && (( now - stamp_ts < 86400 )); then
            return 0
        fi
    fi

    # Prune silently in a background subshell, update stamp when done
    # &! (zsh disown) written as '& disown' for shellcheck compatibility
    {
        _ssh_cache_prune --quiet
        rm -f "${stamp}"
        print -- "${now}" > "${stamp}"
    } &
    disown
}

# ---------------------------------------------------------------------------
# Add or update a host+profile entry with the current timestamp.
# Uses awk for fixed-string matching — safe against regex metacharacters.
# Usage: _ssh_cache_add <host> <profile_flag>
# ---------------------------------------------------------------------------
_ssh_cache_add() {
    local host="${1}" profile="${2}"
    [[ -z "${host}" || -z "${profile}" ]] && return 1
    _ssh_cache_init

    local now
    now="$(_ssh_epoch)"

    local tmp
    tmp="$(mktemp)" || return 1

    # awk exact-field match: skip any existing entry for this host:profile pair
    awk -F: -v h="${host}" -v p="${profile}" \
        '!($1==h && $2==p)' "${_SSH_CACHE_FILE}" > "${tmp}" 2>/dev/null || true
    print -- "${host}:${profile}:${now}" >> "${tmp}"
    chmod 600 "${tmp}"
    command mv -f "${tmp}" "${_SSH_CACHE_FILE}" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Delete a single host entry (all profiles) or a specific host:profile pair.
# Usage: _ssh_cache_delete <host> [profile_flag]
# ---------------------------------------------------------------------------
_ssh_cache_delete() {
    local host="${1}" profile="${2:-}"
    if [[ -z "${host}" ]]; then
        echo "[_ssh] Usage: _ssh_cache_delete <host> [profile]" >&2
        return 1
    fi
    _ssh_cache_init

    local tmp
    tmp="$(mktemp)" || return 1

    if [[ -n "${profile}" ]]; then
        awk -F: -v h="${host}" -v p="${profile}" \
            '!($1==h && $2==p)' "${_SSH_CACHE_FILE}" > "${tmp}"
        echo "[_ssh] Removed ${host}:${profile} from cache."
    else
        awk -F: -v h="${host}" '$1!=h' "${_SSH_CACHE_FILE}" > "${tmp}"
        echo "[_ssh] Removed all entries for '${host}' from cache."
    fi

    chmod 600 "${tmp}"
    command mv -f "${tmp}" "${_SSH_CACHE_FILE}" 2>/dev/null
}

# ---------------------------------------------------------------------------
# List cached hosts — single file pass, TTL-aware.
# Prints one hostname per line.
# Usage: _ssh_cache_hosts [profile_flag]
# ---------------------------------------------------------------------------
_ssh_cache_hosts() {
    local profile="${1:-}"
    _ssh_cache_init

    local now ttl_secs cutoff
    now="$(_ssh_epoch)"
    ttl_secs=$(( _SSH_CACHE_TTL_DAYS * 86400 ))
    cutoff=$(( now - ttl_secs ))

    while IFS=: read -r h p ts; do
        [[ -z "${h}" ]] && continue
        (( _SSH_CACHE_TTL_DAYS > 0 && ts < cutoff )) && continue
        [[ -n "${profile}" && "${p}" != "${profile}" ]] && continue
        print -- "${h}"
    done < "${_SSH_CACHE_FILE}"
}

# ---------------------------------------------------------------------------
# List host+annotation pairs for tab completion — single file pass.
# Prints:  host TAB (ProfileName)
# Usage: _ssh_cache_hosts_annotated [profile_flag]
# ---------------------------------------------------------------------------
_ssh_cache_hosts_annotated() {
    local profile="${1:-}"
    _ssh_cache_init

    local now ttl_secs cutoff
    now="$(_ssh_epoch)"
    ttl_secs=$(( _SSH_CACHE_TTL_DAYS * 86400 ))
    cutoff=$(( now - ttl_secs ))

    while IFS=: read -r h p ts; do
        [[ -z "${h}" ]] && continue
        (( _SSH_CACHE_TTL_DAYS > 0 && ts < cutoff )) && continue
        [[ -n "${profile}" && "${p}" != "${profile}" ]] && continue
        local label="${_SSH_PROFILE_NAMES[$p]:-unknown}"
        printf '%s\t(%s)\n' "${h}" "${label}"
    done < "${_SSH_CACHE_FILE}"
}

# ---------------------------------------------------------------------------
# Get the most recently used profile flag for a given host.
# Usage: _ssh_cache_profile_for_host <host>
# ---------------------------------------------------------------------------
_ssh_cache_profile_for_host() {
    local host="${1}"
    _ssh_cache_init
    awk -F: -v h="${host}" '$1==h {print $2, $3}' "${_SSH_CACHE_FILE}" \
        | sort -k2 -rn \
        | awk 'NR==1 {print $1}'
}

# ---------------------------------------------------------------------------
# Remove stale entries from the cache file in-place.
# Usage: _ssh_cache_prune [--quiet]
# ---------------------------------------------------------------------------
_ssh_cache_prune() {
    local quiet=0
    [[ "${1}" == "--quiet" ]] && quiet=1

    _ssh_cache_init
    (( _SSH_CACHE_TTL_DAYS == 0 )) && return 0

    local now ttl_secs cutoff
    now="$(_ssh_epoch)"
    ttl_secs=$(( _SSH_CACHE_TTL_DAYS * 86400 ))
    cutoff=$(( now - ttl_secs ))

    local tmp
    tmp="$(mktemp)" || return 1
    local -i removed=0 kept=0

    while IFS=: read -r h p ts; do
        [[ -z "${h}" ]] && continue
        if (( ts >= cutoff )); then
            print -- "${h}:${p}:${ts}" >> "${tmp}"
            (( kept++ ))
        else
            (( removed++ ))
        fi
    done < "${_SSH_CACHE_FILE}"

    chmod 600 "${tmp}"
    command mv -f "${tmp}" "${_SSH_CACHE_FILE}" 2>/dev/null

    if (( ! quiet )); then
        local entry_word
        (( removed == 1 )) && entry_word="entry" || entry_word="entries"
        echo "[_ssh] Cache pruned: removed ${removed} expired ${entry_word}, ${kept} remaining."
    fi
}

# ---------------------------------------------------------------------------
# Wipe the entire cache.
# ---------------------------------------------------------------------------
_ssh_cache_clear() {
    _ssh_cache_init
    true > "${_SSH_CACHE_FILE}"
    echo "[_ssh] Cache cleared."
}

# ---------------------------------------------------------------------------
# Pretty-print the cache as a table.
# ---------------------------------------------------------------------------
_ssh_cache_show() {
    _ssh_cache_init
    local now
    now="$(_ssh_epoch)"

    local -i count=0
    printf '%-30s  %-8s  %-20s  %s\n' "HOST" "PROFILE" "PROFILE NAME" "LAST SEEN"
    printf '%-30s  %-8s  %-20s  %s\n' \
        "──────────────────────────────" \
        "────────" \
        "────────────────────" \
        "─────────────────"

    while IFS=: read -r h p ts; do
        [[ -z "${h}" ]] && continue
        local label="${_SSH_PROFILE_NAMES[$p]:-unknown}"
        local -i age=$(( now - ts ))
        local age_str
        if   (( age < 60 ));    then age_str="${age}s ago"
        elif (( age < 3600 ));  then age_str="$(( age / 60 ))m ago"
        elif (( age < 86400 )); then age_str="$(( age / 3600 ))h ago"
        else                         age_str="$(( age / 86400 ))d ago"
        fi
        printf '%-30s  %-8s  %-20s  %s\n' "${h}" "-${p}" "${label}" "${age_str}"
        (( count++ ))
    done < "${_SSH_CACHE_FILE}"

    echo ""
    local entry_word
    (( count == 1 )) && entry_word="entry" || entry_word="entries"
    local ttl_str
    (( _SSH_CACHE_TTL_DAYS == 0 )) && ttl_str="disabled" || ttl_str="${_SSH_CACHE_TTL_DAYS} days"
    echo "${count} ${entry_word} total  |  TTL: ${ttl_str}"
}
