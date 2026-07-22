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
#
# Also forwards stdin → zpty on every iteration (non-blocking single char),
# so keystrokes typed while waiting (e.g. during a password prompt that
# arrives before any shell prompt) are captured immediately instead of
# sitting unread in the terminal's line buffer. The terminal is expected
# to already be in raw/-echo mode (owned by the caller, _ssh_init_execute)
# for the entire interactive session, so those keystrokes are never echoed
# in plaintext.
#
# If a password/passphrase prompt is detected in the accumulated output,
# the countdown is reset to its original value exactly once (one-shot),
# giving the user a full fresh window to type their password starting
# from when the prompt actually appeared, rather than counting against
# time already spent on the connection banner.
# ---------------------------------------------------------------------------
_ssh_init_zpty_wait() {
    setopt localoptions extendedglob

    local timeout="${1}" prompt_regex="${2}"
    local orig_timeout="${timeout}"
    local pw_regex='([Pp]assword|[Pp]assphrase)[[:space:]]*:[[:space:]]*$'
    local line="" output_clean="" char=""
    local -i rc=1 pw_extended=0 activity=0

    while (( timeout > 0 )); do
        activity=0

        if zpty -r -t _ssh_ct line 2>/dev/null; then
            activity=1
            print -n -- "${line}"

            local clean="${line//$'\r'/}"
            clean="${clean//$'\x1b'\[[0-9;?]##[[:alpha:]]/}"
            clean="${clean//$'\x1b'\[[0-9;?]##~/}"
            clean="${clean//$'\x1b[?2004h'/}"
            clean="${clean//$'\x1b[?2004l'/}"
            output_clean+="${clean}"

            # output_clean accumulates every chunk seen so far, so matching
            # against it alone covers both same-chunk and split-across-reads
            # prompt occurrences.
            if [[ "${output_clean}" =~ ${prompt_regex} ]]; then
                rc=0
                break
            fi

            if (( ! pw_extended )) && [[ "${output_clean}" =~ ${pw_regex} ]]; then
                timeout="${orig_timeout}"
                pw_extended=1
            fi
        fi

        # Forward stdin → zpty (non-blocking single char). Runs every
        # iteration — not just when there's no pty output — so a password
        # prompt arriving mid-banner doesn't miss early keystrokes.
        if read -t 0 -k 1 char 2>/dev/null; then
            activity=1
            zpty -w -n _ssh_ct "${char}"
        fi

        if (( ! activity )); then
            # No pty output and no stdin input — count down
            sleep 1
            (( timeout-- ))
        fi

        # Check if process died
        zpty -t _ssh_ct 2>/dev/null || return 1
    done

    return "${rc}"
}

# ---------------------------------------------------------------------------
# _ssh_init_strip_comment  — quote-aware '#' comment stripper
#
# A naive "${line%%#*}" truncates at the first '#' anywhere on the line,
# including one embedded inside a quoted scalar (e.g. a regex value like
# "\]#)"). YAML only treats '#' as a comment start when it is outside any
# quoted string, so we scan char-by-char tracking quote state.
# ---------------------------------------------------------------------------
_ssh_init_strip_comment() {
    local s="${1}"
    local -i i=0 len=${#s} in_squote=0 in_dquote=0
    local out="" c

    while (( i < len )); do
        c="${s[i+1]}"
        if (( in_squote )); then
            out+="${c}"
            [[ "${c}" == "'" ]] && in_squote=0
        elif (( in_dquote )); then
            out+="${c}"
            [[ "${c}" == '"' ]] && in_dquote=0
        else
            case "${c}" in
                "'") in_squote=1; out+="${c}" ;;
                '"') in_dquote=1; out+="${c}" ;;
                '#') break ;;
                *) out+="${c}" ;;
            esac
        fi
        (( i++ ))
    done

    print -r -- "${out}"
}

# ---------------------------------------------------------------------------
# _ssh_init_ltrim / _ssh_init_rtrim  — whitespace trim helpers
#
# Used throughout _ssh_init_resolve's line-by-line YAML parsing. Named
# helpers instead of repeating the glob idiom inline at every call site.
# ---------------------------------------------------------------------------
_ssh_init_ltrim() {
    local s="${1}"
    print -r -- "${s#"${s%%[^ ]*}"}"
}

_ssh_init_rtrim() {
    local s="${1}"
    print -r -- "${s%"${s##*[^ ]}"}"
}

# ---------------------------------------------------------------------------
# _ssh_init_unquote  — strip wrapping single or double quotes from a
# YAML scalar value (e.g. "command" or 'command' → command). Leaves the
# value unchanged if it isn't wrapped in a matching pair of quotes.
# ---------------------------------------------------------------------------
_ssh_init_unquote() {
    local s="${1}"
    if [[ "${s}" == \"*\" && "${s}" == *\" ]]; then
        s="${s#\"}"; s="${s%\"}"
    elif [[ "${s}" == "'"* && "${s}" == *"'" ]]; then
        s="${s#\'}"; s="${s%\'}"
    fi
    print -r -- "${s}"
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
    #
    # NOTE: noextendedglob prevents # from being treated as a glob quantifier
    #       in patterns like ${line%%\#*}. Using [^ ] instead of [! ] for
    #       bracket negation since [^ ] works without EXTENDED_GLOB.

    setopt localoptions noextendedglob

    local -i in_commands=0
    local -a default_cmds=()
    local active_platform="" active_host=""
    local current_section=""
    # Commands per platform/host are accumulated as newline-joined blobs and
    # split back out with the (@f) flag — the (@s:$var:) split flag does NOT
    # reliably parameter-expand a dynamic delimiter in zsh, so a literal
    # newline (always safe — command strings can't contain one) is used.
    local cmd_sep=$'\n'
    typeset -A platform_cmd_map
    typeset -A host_cmd_map

    # Associative accumulators
    typeset -A _ssh_init_data
    _ssh_init_data=()

    while IFS= read -r line; do
        # Strip comments — quote-aware so a '#' inside a quoted scalar
        # (e.g. a prompt regex like "\]#)") is not mistaken for a comment.
        # NOTE: must assign on the same line as `local` — a bare `local var`
        # re-declaration on an already-local var (2nd+ loop iteration)
        # causes zsh to print "var=value" as a side effect.
        local stripped=""
        stripped="$(_ssh_init_strip_comment "${line}")"
        stripped="$(_ssh_init_rtrim "${stripped}")"

        [[ -z "${stripped}" ]] && continue

        # Measure leading spaces
        local indent="${stripped%%[^ ]*}"
        local -i depth=$(( ${#indent} / 2 ))  # assuming 2-space indent
        local payload="${stripped#${indent}}"

        # Terminate command list on dedent or new section
        if (( depth <= 1 )) && (( in_commands )); then
            in_commands=0
        fi

        if (( in_commands )) && [[ "${payload}" == -* ]]; then
            local cmd_val="${payload#- }"
            [[ "${cmd_val}" == "${payload}" ]] && cmd_val="${payload#-}"
            cmd_val="$(_ssh_init_rtrim "${cmd_val}")"
            cmd_val="$(_ssh_init_unquote "${cmd_val}")"
            if [[ -n "${active_host}" ]]; then
                if [[ -n "${host_cmd_map[$active_host]}" ]]; then
                    host_cmd_map[$active_host]+="${cmd_sep}${cmd_val}"
                else
                    host_cmd_map[$active_host]="${cmd_val}"
                fi
            elif [[ -n "${active_platform}" ]]; then
                if [[ -n "${platform_cmd_map[$active_platform]}" ]]; then
                    platform_cmd_map[$active_platform]+="${cmd_sep}${cmd_val}"
                else
                    platform_cmd_map[$active_platform]="${cmd_val}"
                fi
            else
                default_cmds+=( "${cmd_val}" )
            fi
            continue
        fi

        # Top-level sections
        if (( depth == 0 )); then
            case "${payload}" in
                "defaults:")  current_section="defaults"; active_platform=""; active_host=""; continue ;;
                "platforms:") current_section="platforms"; active_platform=""; active_host=""; continue ;;
                "hosts:")     current_section="hosts";    active_platform=""; active_host=""; continue ;;
                *)             current_section="" ;;
            esac
            continue
        fi

        # ── defaults section: fields live directly at depth 1 (no name level) ──
        if [[ "${current_section}" == "defaults" ]] && (( depth == 1 )); then
            local def_key="${payload%%:*}"
            def_key="$(_ssh_init_rtrim "${def_key}")"
            local def_val="${payload#*:}"
            def_val="$(_ssh_init_ltrim "${def_val}")"
            def_val="$(_ssh_init_rtrim "${def_val}")"
            def_val="$(_ssh_init_unquote "${def_val}")"

            if [[ "${def_key}" == "commands" ]]; then
                in_commands=1
                continue
            fi

            case "${def_key}" in
                prompt)  _ssh_init_data[def_prompt]="${def_val}" ;;
                timeout) _ssh_init_data[def_timeout]="${def_val}" ;;
            esac
            continue
        fi

        # ── depth == 1: platform name or host name ──
        if (( depth == 1 )); then
            in_commands=0
            if [[ "${current_section}" == "platforms" ]]; then
                active_platform="${payload%%:*}"
                active_host=""
            elif [[ "${current_section}" == "hosts" ]]; then
                active_host="${payload%%:*}"
                active_platform=""
            fi
            continue
        fi

        # ── depth == 2: fields under platform/host, or list items ──
        if (( depth == 2 )); then
            # Key: value pair
            local key="${payload%%:*}"
            key="$(_ssh_init_rtrim "${key}")"
            local val="${payload#*:}"
            val="$(_ssh_init_ltrim "${val}")"
            val="$(_ssh_init_rtrim "${val}")"
            val="$(_ssh_init_unquote "${val}")"

            if [[ "${key}" == "commands" ]]; then
                in_commands=1
                continue
            fi

            if [[ -n "${active_host}" ]]; then
                case "${key}" in
                    prompt)   _ssh_init_data[host_${active_host}_prompt]="${val}" ;;
                    timeout)  _ssh_init_data[host_${active_host}_timeout]="${val}" ;;
                    platform) _ssh_init_data[host_${active_host}_platform]="${val}" ;;
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
    local host_platform="${_ssh_init_data[host_${host}_platform]}"
    if [[ -n "${host_platform}" ]]; then
        resolved_platform="${host_platform}"
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
    local -a platform_cmds=()
    local platform_cmd_blob="${platform_cmd_map[$resolved_platform]}"
    if [[ -n "${platform_cmd_blob}" ]]; then
        platform_cmds=( "${(@f)platform_cmd_blob}" )
    fi

    local -a host_cmds=()
    local host_cmd_blob="${host_cmd_map[$host]}"
    if [[ -n "${host_cmd_blob}" ]]; then
        host_cmds=( "${(@f)host_cmd_blob}" )
    fi

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
#
# NOTE: does NOT manage terminal raw/-echo state itself. The caller
# (_ssh_init_execute) owns stty raw/-echo for the entire interactive
# session lifetime (wait phase + bridge phase) and restores it via an
# `always` block on every exit path, so raw/-echo is assumed already
# active by the time this runs.
# ---------------------------------------------------------------------------
_ssh_init_zpty_bridge() {
    local char="" line=""

    # Cleanup handler
    local _ssh_bridge_cleanup
    _ssh_bridge_cleanup() {
        zpty -d _ssh_ct 2>/dev/null
    }

    while :; do
        # Check if zpty process is still running
        zpty -t _ssh_ct 2>/dev/null || break

        # Forward stdin → zpty (non-blocking single char)
        # -n is critical: without it, zpty -w appends a trailing newline to
        # EVERY forwarded keystroke, turning each character the user types
        # into its own submitted line (e.g. "exit" becomes four separate
        # one-character commands sent to the remote).
        if read -t 0 -k 1 char 2>/dev/null; then
            zpty -w -n _ssh_ct "${char}"
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
# shellcheck disable=SC1072,SC1073,SC1056,SC1141
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
    # remote_cmd is intentionally omitted here — init-commands only run
    # when _ssh_init_eligible confirmed no remote command was passed.
    _ssh_build_ssh_cmd "${ct_available}" "${ct_config}" "${verbose_flag}" "${ssh_target}"
    local -a ct_cmd=( "${_SSH_BUILT_CT_CMD[@]}" )
    local -a ssh_cmd=( "${_SSH_BUILT_SSH_CMD[@]}" )

    # ── Start zpty ────────────────────────────────────────────────
    if (( ${#ct_cmd[@]} > 0 )); then
        zpty -b _ssh_ct "${ct_cmd[@]}" "${ssh_cmd[@]}"
    else
        zpty -b _ssh_ct "${ssh_cmd[@]}"
    fi

    # ── Own terminal raw/-echo for the entire interactive session ──
    # Applied immediately after spawn — before the connection banner or
    # a password prompt can possibly arrive — and restored on every exit
    # path (normal return, timeout break, or interrupt) via the `always`
    # block below, mirroring the guaranteed-cleanup pattern used for
    # Ghostty background restore in core.zsh:_ssh() (`always { _ssh_ghostty_reset_bg }`).
    local old_tty
    old_tty="$(stty -g 2>/dev/null)"
    stty raw -echo 2>/dev/null

    {
        # Give the process a moment to establish the connection
        sleep 1

        # ── Wait for initial prompt ──────────────────────────────
        if ! _ssh_init_zpty_wait "${_SSH_INIT_TIMEOUT}" "${_SSH_INIT_PROMPT}"; then
            # Timeout on initial prompt — drain and bridge anyway
            if [[ -n "${verbose_flag}" ]]; then
                echo "[_ssh] init-commands: initial prompt timeout" >&2
            fi
            _ssh_init_zpty_bridge
            return $?
        fi

        # ── Send each command ─────────────────────────────────────
        local cmd
        for cmd in "${commands[@]}"; do
            # Variable expansion — no local echo here: the remote pty echoes
            # back what it receives (normal terminal behavior), and that echo
            # is already printed by _ssh_init_zpty_wait below. Printing our own
            # "> cmd" here would duplicate it.
            # shellcheck disable=SC2296
            local expanded="${(e)cmd}"

            # Send command — pass -n so zpty doesn't append its OWN trailing
            # newline on top of the one we're adding explicitly.
            zpty -w -n _ssh_ct "${expanded}"$'\n'

            # Wait for prompt
            if ! _ssh_init_zpty_wait "${_SSH_INIT_TIMEOUT}" "${_SSH_INIT_PROMPT}"; then
                if [[ -n "${verbose_flag}" ]]; then
                    echo "[_ssh] init-commands: command timed out — aborting remaining" >&2
                fi
                break
            fi
        done

        # ── Bridge to user ────────────────────────────────────────
        _ssh_init_zpty_bridge
        return $?
    } always {
        stty "${old_tty}" 2>/dev/null
    }
}
