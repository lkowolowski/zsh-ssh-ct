# tests/test_helper.bash — shared setup for bats tests
#
# Bypasses zsh-ssh-ct.plugin.zsh (which resolves its own path via ${0:A:h},
# fragile when invoked through `zsh -c`) and instead sources the lib/*.zsh
# files directly with the same defaults the loader would set.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PROJECT_ROOT

# zsh_ssh_ct_eval <script>
#
# Runs <script> in a fresh, non-interactive zsh (-f: no rcfiles) after
# sourcing the plugin's lib files with safe, isolated defaults. Any
# already-exported env vars (e.g. _SSH_CT_CONFIG_DIR, _SSH_REMOTE_CMDS) set
# by the calling test are preserved, since `: "${VAR:=default}"` only
# assigns when the variable is unset or empty.
zsh_ssh_ct_eval() {
	zsh -f -c '
        typeset -g _SSH_PLUGIN_NAME="zsh-ssh-ct"
        typeset -g _SSH_PLUGIN_VERSION="test"

        : "${_SSH_CT_CONFIG_DIR:=/tmp/zsh-ssh-ct-test-nonexistent}"
        : "${_SSH_MAX_RETRIES:=60}"
        : "${_SSH_RETRY_SLEEP:=30}"
        : "${_SSH_REMOTE_CMDS:=/tmp/zsh-ssh-ct-test-nonexistent.yml}"
        : "${_SSH_INIT_CMD_SKIP_PROFILES:=u}"
        : "${_SSH_GHOSTTY_BG_ENABLE:=0}"

        typeset -gA _SSH_PROFILE_MAP=(
            j juniper.yml
            c cisco.yml
            p panos.yml
            u unix.yml
        )
        typeset -gA _SSH_PROFILE_NAMES=(
            j Juniper
            c Cisco
            p "PAN-OS/Palo Alto"
            u Unix/Linux
        )

        source "${PROJECT_ROOT}/lib/ghostty.zsh"
        source "${PROJECT_ROOT}/lib/core.zsh"
        source "${PROJECT_ROOT}/lib/complete.zsh"
        source "${PROJECT_ROOT}/lib/init.zsh"
    '"$1"
}
