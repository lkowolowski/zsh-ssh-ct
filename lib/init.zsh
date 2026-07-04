# lib/init.zsh — Init-commands execution via zsh/zpty
# Sends platform/host-specific commands after SSH connects,
# before handing the terminal to the user.
#
# Depends on: zsh/zpty (built-in, no external deps)
#
# shellcheck shell=bash
# ─────────────────────────────────────────────────────────────────────────────

# Guard
[[ -n "${_SSH_INIT_LOADED}" ]] && return 0
typeset -g _SSH_INIT_LOADED=1

# Flag: set to 1 by _ssh_init_execute when it actually runs commands
typeset -g _SSH_INIT_DID_RUN=0

# ---------------------------------------------------------------------------
# _ssh_init_did_run  — query the run flag
# Returns 0 if init-commands executed in the most recent _ssh_init_execute
# ---------------------------------------------------------------------------
_ssh_init_did_run() {
    (( _SSH_INIT_DID_RUN == 1 ))
}

# ---------------------------------------------------------------------------
# _ssh_init_eligible  — gate check
# Returns 0 if init-commands should run, 1 if skip.
#
# Conditions for skip:
#   1. A remote command was provided (CLI passthrough)
#   2. Profile is in _SSH_INIT_CMD_SKIP_PROFILES
# ---------------------------------------------------------------------------
_ssh_init_eligible() {
    local profile_flag="${1}"; shift
    local -a remote_cmd=( "${@}" )

    # Skip if remote command passed on CLI
    (( ${#remote_cmd[@]} > 0 )) && return 1

    # Skip if profile is in the skip list
    if [[ -n "${_SSH_INIT_CMD_SKIP_PROFILES}" ]]; then
        local skip_profile
        # shellcheck disable=SC2066
        for skip_profile in "${(s::)_SSH_INIT_CMD_SKIP_PROFILES}"; do
            [[ "${skip_profile}" == "${profile_flag}" ]] && return 1
        done
    fi

    return 0
}

# ---------------------------------------------------------------------------
# _ssh_init_zpty_wait  — wait for prompt match with timeout
#
# Reads from zpty _ssh_ct until the prompt regex matches or timeout fires.
# Returns 0 on prompt match, 1 on timeout.
# All output up to (and including) the matching line is printed to stdout.
# ---------------------------------------------------------------------------
_ssh_init_zpty_wait() {
    local timeout="${1}" prompt_regex="${2}"
    local line="" output=""
    local -i rc=1

    while (( timeout > 0 )); do
        if zpty -r -t _ssh_ct line 2>/dev/null; then
            print -n -- "${line}"
            output+="${line}"
            # Check if the last chunk matches the prompt
            if [[ "${output}" =~ ${prompt_regex} ]]; then
                rc=0
                break
            fi
        else
            # No data available — count down
            sleep 1
            (( timeout-- ))
        fi

        # Check if process died
        zpty -t _ssh_ct 2>/dev/null || return 1
    done

    return "${rc}"
}

# ---------------------------------------------------------------------------
# _ssh_init_resolve  — parse config and resolve commands for a profile+host
#
# Sets global vars:
#   _SSH_INIT_PROMPT    — resolved prompt regex
#   _SSH_INIT_TIMEOUT   — resolved timeout in seconds
#   _SSH_INIT_COMMANDS  — resolved command array
#
# Returns 0 if commands resolved (may be empty), 1 if skip.
# ---------------------------------------------------------------------------
_ssh_init_resolve() {
    local profile="${1}" host="${2}"

    _SSH_INIT_PROMPT='[>#$]'
    _SSH_INIT_TIMEOUT=5
    _SSH_INIT_COMMANDS=()

    local config_file="${_SSH_REMOTE_CMDS}"
    [[ -f "${config_file}" ]] || return 1

    # --- Parse YAML in pure zsh (no external deps) ---
    #
    # Structure parsed:
    #   defaults: { prompt, timeout, commands }
    #   platforms: { <name>: { prompt, timeout, commands } }
    #   hosts: { <name>: { platform, prompt, timeout, commands } }
    #
    # Approach: read line-by-line, track indentation depth with a stack.

    local -a stack=()
    local -i in_commands=0
    local -a platform_cmds=() host_cmds=() default_cmds=()
    local active_platform="" active_host=""
    local host_platform_val=""

    # Associative accumulators
    typeset -gA _ssh_init_data
    _ssh_init_data=()

    while IFS= read -r line; do
        # Strip full-line and trailing comments (naive — not inside strings)
        local stripped="${line%%#*}"
        stripped="${stripped%"${stripped##*[! ]}"}"  # rtrim

        [[ -z "${stripped}" ]] && continue

        # Measure leading spaces
        local indent="${stripped//[^ ]/}"
        local -i depth=$(( ${#indent} / 2 ))  # assuming 2-space indent

        local payload="${stripped## #}"
        local payload="${payload#"${payload%%[! ]*}"}"  # ltrim

        # Terminate command list on dedent or new section
        if (( depth <= 1 )) && (( in_commands )); then
            in_commands=0
        fi

        # Top-level sections
        if (( depth == 0 )); then
            case "${payload}" in
                "defaults:")  stack=( "defaults" ); active_platform=""; active_host=""; continue ;;
                "platforms:") stack=( "platforms" ); active_platform=""; active_host=""; continue ;;
                "hosts:")     stack=( "hosts" );    active_platform=""; active_host=""; continue ;;
            esac
            continue
        fi

        # ── depth == 1: platform name or host name ──
        if (( depth == 1 )); then
            in_commands=0
            if [[ "${stack[1]}" == "platforms" ]]; then
                active_platform="${payload%%:*}"
                active_host=""
            elif [[ "${stack[1]}" == "hosts" ]]; then
                active_host="${payload%%:*}"
                active_platform=""
            fi
            continue
        fi

        # ── depth == 2: fields under platform/host, or list items ──
        if (( depth == 2 )); then
            if [[ "${payload}" == -* ]]; then
                # List item
                local cmd_val="${payload#- }"
                cmd_val="${cmd_val%"${cmd_val##*[! ]}"}"
                if [[ -n "${active_host}" ]]; then
                    host_cmds+=( "${cmd_val}" )
                elif [[ -n "${active_platform}" ]]; then
                    platform_cmds+=( "${cmd_val}" )
                else
                    default_cmds+=( "${cmd_val}" )
                fi
                continue
            fi

            # Key: value pair
            local key="${payload%%:*}"
            key="${key%"${key##*[! ]}"}"
            local val="${payload#*: }"

            if [[ "${key}" == "commands" ]]; then
                in_commands=1
                continue
            fi

            if [[ -n "${active_host}" ]]; then
                case "${key}" in
                    prompt)   _ssh_init_data[host_${active_host}_prompt]="${val}" ;;
                    timeout)  _ssh_init_data[host_${active_host}_timeout]="${val}" ;;
                    platform) host_platform_val="${val}" ;;
                esac
            elif [[ -n "${active_platform}" ]]; then
                case "${key}" in
                    prompt)  _ssh_init_data[plat_${active_platform}_prompt]="${val}" ;;
                    timeout) _ssh_init_data[plat_${active_platform}_timeout]="${val}" ;;
                esac
            else
                case "${key}" in
                    prompt)  _ssh_init_data[def_prompt]="${val}" ;;
                    timeout) _ssh_init_data[def_timeout]="${val}" ;;
                esac
            fi
        fi
    done < "${config_file}"

    # --- Resolve layering cascade ---
    # Determine which platform name applies to this host
    local resolved_platform="${profile}"

    # Map profile flags to platform names
    case "${profile}" in
        j) resolved_platform="juniper" ;;
        c) resolved_platform="cisco"   ;;
        p) resolved_platform="panos"   ;;
        u) resolved_platform="unix"    ;;
    esac

    # Check if host has a explicit platform override
    if [[ -n "${host_platform_val}" ]]; then
        resolved_platform="${host_platform_val}"
    fi

    # Cascade: defaults → platform → host

    # 1. Defaults
    local def_timeout="${_ssh_init_data[def_timeout]}"
    local def_prompt="${_ssh_init_data[def_prompt]}"

    [[ -n "${def_prompt}"  ]] && _SSH_INIT_PROMPT="${def_prompt}"
    [[ -n "${def_timeout}" ]] && _SSH_INIT_TIMEOUT="${def_timeout}"

    # 2. Platform
    local plat_timeout="${_ssh_init_data[plat_${resolved_platform}_timeout]}"
    local plat_prompt="${_ssh_init_data[plat_${resolved_platform}_prompt]}"

    [[ -n "${plat_prompt}"  ]] && _SSH_INIT_PROMPT="${plat_prompt}"
    [[ -n "${plat_timeout}" ]] && _SSH_INIT_TIMEOUT="${plat_timeout}"

    # 3. Host
    local host_timeout="${_ssh_init_data[host_${host}_timeout]}"
    local host_prompt="${_ssh_init_data[host_${host}_prompt]}"

    [[ -n "${host_prompt}"  ]] && _SSH_INIT_PROMPT="${host_prompt}"
    [[ -n "${host_timeout}" ]] && _SSH_INIT_TIMEOUT="${host_timeout}"

    # --- Resolve commands (platform + host, deduped first-match-wins) ---
    local -a resolved_cmds=()
    local -A seen_cmds=()

    local cmd
    for cmd in "${default_cmds[@]}" "${platform_cmds[@]}"; do
        if [[ -z "${seen_cmds[$cmd]}" ]]; then
            seen_cmds[$cmd]=1
            resolved_cmds+=( "${cmd}" )
        fi
    done
    for cmd in "${host_cmds[@]}"; do
        if [[ -z "${seen_cmds[$cmd]}" ]]; then
            seen_cmds[$cmd]=1
            resolved_cmds+=( "${cmd}" )
        fi
    done

    # Check sentinel: commands: ["none"]
    if (( ${#resolved_cmds[@]} == 1 )) && [[ "${resolved_cmds[1]}" == "none" ]]; then
        _SSH_INIT_COMMANDS=()
        return 1
    fi

    _SSH_INIT_COMMANDS=( "${resolved_cmds[@]}" )

    return 0
}

# ---------------------------------------------------------------------------
# _ssh_init_zpty_bridge  — forward terminal I/O to/from zpty
#
# Called after init-commands complete. Bridges the zpty session to the
# user's terminal until the remote process exits.
# ---------------------------------------------------------------------------
_ssh_init_zpty_bridge() {
    local old_tty
    local char="" line=""

    # Save and set raw terminal
    old_tty="$(stty -g 2>/dev/null)"
    stty raw -echo 2>/dev/null

    # Cleanup handler
    local _ssh_bridge_cleanup
    _ssh_bridge_cleanup() {
        stty "${old_tty}" 2>/dev/null
        zpty -d _ssh_ct 2>/dev/null
    }

    while :; do
        # Check if zpty process is still running
        zpty -t _ssh_ct 2>/dev/null || break

        # Forward stdin → zpty (non-blocking single char)
        if read -t 0 -k 1 char 2>/dev/null; then
            zpty -w _ssh_ct "${char}"
        fi

        # Forward zpty → stdout (available data)
        if zpty -r _ssh_ct line 2>/dev/null; then
            print -n -- "${line}"
        fi

        # Brief pause to prevent busy-wait
        sleep 0.005 2>/dev/null || true
    done

    # Drain remaining zpty output
    while zpty -r _ssh_ct line 2>/dev/null; do
        print -n -- "${line}"
    done

    # Restore terminal
    _ssh_bridge_cleanup

    return 0
}

# ---------------------------------------------------------------------------
# _ssh_init_execute  — master orchestrator
#
# Called from core.zsh after DNS/ping succeeds, before SSH execution.
# Handles the full init-commands lifecycle:
#   1. Eligibility check (remote_cmd, skip_profiles)
#   2. Config resolution (YAML parse + cascade)
#   3. zpty creation
#   4. Prompt wait + command send loop
#   5. zpty bridge (hands terminal to user)
# ---------------------------------------------------------------------------
_ssh_init_execute() {
    local profile_flag="${1}" resolved_host="${2}" ssh_target="${3}" ct_config="${4}"
    local verbose_flag="${5}" ct_available="${6}"
    shift 6
    local -a remote_cmd=( "${@}" )

    # ── Gate: eligibility ─────────────────────────────────────────
    _ssh_init_eligible "${profile_flag}" "${remote_cmd[@]}" || return 0

    # ── Resolve config ────────────────────────────────────────────
    _ssh_init_resolve "${profile_flag}" "${resolved_host}" || return 0

    local -a commands=( "${_SSH_INIT_COMMANDS[@]}" )
    (( ${#commands[@]} > 0 )) || return 0

    _SSH_INIT_DID_RUN=1

    # ── Verbose banner ────────────────────────────────────────────
    if [[ -n "${verbose_flag}" ]]; then
        echo "[_ssh] sending init-commands..." >&2
    fi

    # ── Load zpty module ──────────────────────────────────────────
    zmodload zsh/zpty 2>/dev/null || return 0

    # ── Build command ─────────────────────────────────────────────
    local -a ssh_cmd ssh_extra_flags
    local -a ct_cmd

    [[ -n "${verbose_flag}" ]] && ssh_extra_flags+=( "${verbose_flag}" )

    if (( ct_available )) && [[ -n "${ct_config}" ]]; then
        ct_cmd=( ct -c "${ct_config}" )
    elif (( ct_available )); then
        ct_cmd=( ct )
    else
        ct_cmd=()
    fi

    ssh_cmd=( ssh "${ssh_extra_flags[@]}" "${ssh_target}" )

    # ── Start zpty ────────────────────────────────────────────────
    if (( ${#ct_cmd[@]} > 0 )); then
        zpty -b _ssh_ct "${ct_cmd[@]}" "${ssh_cmd[@]}"
    else
        zpty -b _ssh_ct "${ssh_cmd[@]}"
    fi

    # Give the process a moment to establish the connection
    sleep 1

    # ── Wait for initial prompt ──────────────────────────────────
    if ! _ssh_init_zpty_wait "${_SSH_INIT_TIMEOUT}" "${_SSH_INIT_PROMPT}"; then
        # Timeout on initial prompt — drain and bridge anyway
        if [[ -n "${verbose_flag}" ]]; then
            echo "[_ssh] init-commands: initial prompt timeout" >&2
        fi
        _ssh_init_zpty_bridge
        return $?
    fi

    # ── Send each command ─────────────────────────────────────────
    local cmd
    for cmd in "${commands[@]}"; do
        # Echo with variable expansion
        # shellcheck disable=SC2296
        local expanded="${(e)cmd}"
        echo "> ${expanded}"

        # Send command
        zpty -w _ssh_ct "${expanded}"$'\n'

        # Wait for prompt
        if ! _ssh_init_zpty_wait "${_SSH_INIT_TIMEOUT}" "${_SSH_INIT_PROMPT}"; then
            if [[ -n "${verbose_flag}" ]]; then
                echo "[_ssh] init-commands: command timed out — aborting remaining" >&2
            fi
            break
        fi
    done

    # ── Bridge to user ────────────────────────────────────────────
    _ssh_init_zpty_bridge
    return $?
}
