# lib/complete.zsh — Tab completion for _ssh and cache management commands
#
# shellcheck shell=bash
# ─────────────────────────────────────────────────────────────────────────────

# ---------------------------------------------------------------------------
# known_hosts cache — parsed once per session, invalidated on mtime change
# ---------------------------------------------------------------------------
typeset -g  _SSH_KNOWN_HOSTS_MTIME=""
typeset -ga _SSH_KNOWN_HOSTS_CACHE=()

_ssh_complete_known_hosts() {
    local kh="${HOME}/.ssh/known_hosts"
    [[ -r "${kh}" ]] || return

    # Get current mtime (portable: stat -c on Linux, stat -f on macOS)
    local mtime
    if [[ "${_SSH_OS}" == "Darwin" ]]; then
        mtime="$(stat -f '%m' "${kh}" 2>/dev/null)"
    else
        mtime="$(stat -c '%Y' "${kh}" 2>/dev/null)"
    fi

    # Rebuild cache only when file has changed
    if [[ "${mtime}" != "${_SSH_KNOWN_HOSTS_MTIME}" ]]; then
        _SSH_KNOWN_HOSTS_CACHE=()
        while IFS= read -r line; do
            [[ "${line}" == \|* ]] && continue     # skip hashed entries
            local hf="${line%% *}"
            # known_hosts allows comma-separated name,ip pairs — split them
            local -a hf_parts=( ${(s:,:)hf} )
            for hf in "${hf_parts[@]}"; do
                hf="${hf#\[}"; hf="${hf%%\]*}"; hf="${hf%%:*}"
                [[ -n "${hf}" ]] && _SSH_KNOWN_HOSTS_CACHE+=("${hf}")
            done
        done < "${kh}"
        _SSH_KNOWN_HOSTS_MTIME="${mtime}"
    fi
}

# ---------------------------------------------------------------------------
# Context-aware remote command suggestions per profile
# Format: associative array of  "display label" -> "actual command"
# Each profile key holds a newline-separated list of  label:command  pairs.
# ---------------------------------------------------------------------------
typeset -gA _SSH_PROFILE_COMMANDS
_SSH_PROFILE_COMMANDS=(
    j $'show interfaces descriptions:show interfaces descriptions\nshow interfaces terse:show interfaces terse\nshow route summary:show route summary\nshow bgp summary:show bgp summary\nshow version:show version\nshow chassis hardware:show chassis hardware\nshow log messages:show log messages'
    c $'show version:show version\nshow interfaces status:show interfaces status\nshow ip interface brief:show ip interface brief\nshow ip route:show ip route\nshow running-config:show running-config\nshow cdp neighbors:show cdp neighbors\nshow spanning-tree:show spanning-tree'
    p $'show system info:show system info\nshow interface all:show interface all\nshow routing route:show routing route\nshow security policies:show security policies\nshow log system:show log system'
    u $'uname -a:uname -a\nuptime:uptime\ndf -h:df -h\nfree -h:free -h\nwho:who\nlast:last\nps aux:ps aux\nip addr show:ip addr show'
)

# ---------------------------------------------------------------------------
# Completion for _ssh
# ---------------------------------------------------------------------------
_ssh_complete() {

    # ── Build list of flags not yet used (prevents re-offering used flags) ──
    local -a used_flags=()
    local profile_flag_given="" host_given=""
    local -i i

    for (( i = 1; i < CURRENT; i++ )); do
        local w="${words[i]}"
        case "${w}" in
            -j|-c|-p|-u)
                profile_flag_given="${w#-}"
                used_flags+=("${w}")
                ;;
            -v|-n|-H) used_flags+=("${w}") ;;
        esac
        # Capture host: first non-flag word after the profile flag
        if [[ -n "${profile_flag_given}" && -z "${host_given}" \
              && "${w}" != -* && "${w}" != "${words[1]}" ]]; then
            [[ -n "${w}" ]] && host_given="${w}"
        fi
    done

    local cur="${words[CURRENT]}"

    # ── Dynamically build available profile opts, excluding used flags ──────
    local -a profile_opts=()
    local -A all_profile_opts=(
        -j '-j[Juniper profile (juniper.yml)]'
        -c '-c[Cisco profile (cisco.yml)]'
        -p '-p[PAN-OS profile (panos.yml)]'
        -u '-u[Unix / Linux profile (unix.yml)]'
        -v '-v[Verbose SSH output]'
        -n '-n[Dry run — print command without executing]'
        -H '-H[Exact hostname — bypass fuzzy matching]:host:_hosts'
    )
    local flag
    for flag in -j -c -p -u -v -n -H; do
        # Only offer if not already present in the command line
        if (( ! ${used_flags[(Ie)${flag}]} )); then
            profile_opts+=("${all_profile_opts[$flag]}")
        fi
    done

    # ── State 1: no profile yet, or current word is a flag ──────────────────
    if [[ -z "${profile_flag_given}" ]] || [[ "${cur}" == -* && -z "${host_given}" ]]; then
        _arguments -s "${profile_opts[@]}"
        return 0
    fi

    # ── State 2: profile given, completing hostname ──────────────────────────
    if [[ -n "${profile_flag_given}" && -z "${host_given}" ]]; then
        local -a all_hosts all_descs
        local -A seen_hosts=()

        # 1. Cache — profile-filtered first (highest priority + annotation)
        while IFS=$'\t' read -r h desc; do
            [[ -z "${h}" || -n "${seen_hosts[$h]}" ]] && continue
            seen_hosts[$h]=1; all_hosts+=("${h}"); all_descs+=("${desc}")
        done < <(_ssh_cache_hosts_annotated "${profile_flag_given}")

        # 2. Cache — all other profiles
        while IFS=$'\t' read -r h desc; do
            [[ -z "${h}" || -n "${seen_hosts[$h]}" ]] && continue
            seen_hosts[$h]=1; all_hosts+=("${h}"); all_descs+=("${desc}")
        done < <(_ssh_cache_hosts_annotated)

        # 3. ~/.ssh/config
        if [[ -r "${HOME}/.ssh/config" ]]; then
            while IFS= read -r line; do
                if [[ "${line}" =~ ^[[:space:]]*[Hh]ost[[:space:]] ]]; then
                    local hval="${line#*[Hh]ost }"
                    for h in ${=hval}; do
                        [[ "${h}" == *\** || "${h}" == *\?* ]] && continue
                        [[ -n "${seen_hosts[$h]}" ]] && continue
                        seen_hosts[$h]=1; all_hosts+=("${h}"); all_descs+=("(ssh/config)")
                    done
                fi
            done < "${HOME}/.ssh/config"
        fi

        # 4. ~/.ssh/known_hosts (mtime-cached)
        _ssh_complete_known_hosts
        for h in "${_SSH_KNOWN_HOSTS_CACHE[@]}"; do
            [[ -n "${seen_hosts[$h]}" ]] && continue
            seen_hosts[$h]=1; all_hosts+=("${h}"); all_descs+=("(known_hosts)")
        done

        if (( ${#all_hosts[@]} > 0 )); then
            # Build display strings as "hostname  (source)" so the hostname is
            # always visible in the completion menu, not just the annotation.
            local -a display_strs=()
            local -i idx
            for (( idx = 1; idx <= ${#all_hosts[@]}; idx++ )); do
                display_strs+=("${all_hosts[idx]}  ${all_descs[idx]}")
            done
            compadd -M 'l:|=* r:|=*' -d display_strs -a all_hosts
        else
            _hosts
        fi
        return 0
    fi

    # ── State 3: host given — flags or context-aware remote commands ─────────
    if [[ -n "${host_given}" ]]; then
        if [[ "${cur}" == -* ]]; then
            _arguments -s "${profile_opts[@]}"
            return 0
        fi

        # Profile-aware remote command completions
        local cmd_list="${_SSH_PROFILE_COMMANDS[$profile_flag_given]}"
        if [[ -n "${cmd_list}" ]]; then
            local -a cmds descs
            while IFS=: read -r label cmd; do
                [[ -z "${label}" ]] && continue
                cmds+=("${cmd}")
                descs+=("${label}")
            done <<< "${cmd_list}"
            compadd -d descs -a cmds
        fi
        return 0
    fi
}


# ---------------------------------------------------------------------------
# Completion for cache management commands
# ---------------------------------------------------------------------------
_ssh_cache_delete_complete() {
    local -a hosts descs
    local -A seen=()
    while IFS=$'\t' read -r h desc; do
        [[ -z "${h}" || -n "${seen[$h]}" ]] && continue
        seen[$h]=1; hosts+=("${h}"); descs+=("${desc}")
    done < <(_ssh_cache_hosts_annotated)
    if (( ${#hosts[@]} > 0 )); then
        local -a display_strs=()
        local -i idx
        for (( idx = 1; idx <= ${#hosts[@]}; idx++ )); do
            display_strs+=("${hosts[idx]}  ${descs[idx]}")
        done
        compadd -d display_strs -a hosts
    fi
}

# ---------------------------------------------------------------------------
# compdef registration — deferred if compinit hasn't run yet.
#
# zgenom / zinit call compinit before sourcing plugins, so compdef is always
# available there.  For manual installs where the plugin is sourced before
# compinit, we register a precmd hook that fires on the first prompt, calls
# compdef, then immediately removes itself.
# ---------------------------------------------------------------------------
_ssh_register_completions() {
    compdef _ssh_complete _ssh
    compdef _ssh_cache_delete_complete _ssh_cache_delete
}

if (( ${+functions[compdef]} )); then
    # compinit has already run — register immediately
    _ssh_register_completions
else
    # compinit hasn't run yet — defer until the first prompt
    autoload -Uz add-zsh-hook
    _ssh_deferred_compdef() {
        if (( ${+functions[compdef]} )); then
            _ssh_register_completions
            add-zsh-hook -d precmd _ssh_deferred_compdef
            unfunction _ssh_deferred_compdef
        fi
    }
    add-zsh-hook precmd _ssh_deferred_compdef
fi
