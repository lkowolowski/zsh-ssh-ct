# zsh-ssh-ct.plugin.zsh
# Smart SSH wrapper with ChromaTerm (ct), retry logic, and tab completion.
#
# zgenom:  zgenom load <user>/zsh-ssh-ct
# Manual:  source /path/to/zsh-ssh-ct.plugin.zsh
#
# shellcheck shell=bash
# ─────────────────────────────────────────────────────────────────────────────

# ── Guard against double-sourcing ────────────────────────────────────────────
[[ -n "${_SSH_PLUGIN_LOADED}" ]] && return 0
typeset -g _SSH_PLUGIN_LOADED=1
typeset -g _SSH_PLUGIN_NAME="zsh-ssh-ct"
typeset -g _SSH_PLUGIN_VERSION="2.1.0"

# ── Resolve plugin directory (works with zgenom, zinit, manual source) ───────
typeset -g _SSH_PLUGIN_DIR="${0:A:h}"

# ── User-configurable defaults ───────────────────────────────────────────────
# Set any of these in your .zshrc BEFORE sourcing / loading the plugin.
#
#   Variable               Default                              Purpose
#   ──────────────────────────────────────────────────────────────────────────
#   _SSH_CT_CONFIG_DIR     $XDG_CONFIG_HOME/chromaterm          ct YAML config dir
#                          (~/.config/chromaterm if XDG unset)
#   _SSH_MAX_RETRIES       60                                   max ping retries
#   _SSH_RETRY_SLEEP       30                                   seconds between retries
#   _SSH_REMOTE_CMDS       $XDG_CONFIG_HOME/zsh-ssh-ct/init-com  init-commands YAML path
#                          mands.yml
#   _SSH_INIT_CMD_SKIP_    "u"                                   profiles to skip (j/c/p/u)
#   PROFILES
#   _SSH_GHOSTTY_BG_ENABLE 0                                    enable Ghostty bg switching
#   _SSH_GHOSTTY_BG_CONFIG $XDG_CONFIG_HOME/zsh-ssh-ct/ghostty-bg.yml  config path
#   _SSH_GHOSTTY_BG_J      "#1A3A2A"                             Juniper bg color (fallback)
#   _SSH_GHOSTTY_BG_C      "#1A2A3A"                             Cisco bg color (fallback)
#   _SSH_GHOSTTY_BG_P      "#3A1A1A"                             PAN-OS bg color (fallback)
#   _SSH_GHOSTTY_BG_U      ""                                    Unix bg color (empty=no change)
#
# Resolve XDG_CONFIG_HOME with the spec-compliant fallback of ~/.config
: "${XDG_CONFIG_HOME:=${HOME}/.config}"
: "${_SSH_CT_CONFIG_DIR:=${XDG_CONFIG_HOME}/chromaterm}"
: "${_SSH_MAX_RETRIES:=60}"
: "${_SSH_RETRY_SLEEP:=30}"
: "${_SSH_REMOTE_CMDS:=${XDG_CONFIG_HOME}/zsh-ssh-ct/init-commands.yml}"
: "${_SSH_INIT_CMD_SKIP_PROFILES:=u}"
: "${_SSH_GHOSTTY_BG_ENABLE:=0}"
: "${_SSH_GHOSTTY_BG_CONFIG:=${XDG_CONFIG_HOME}/zsh-ssh-ct/ghostty-bg.yml}"
: "${_SSH_GHOSTTY_BG_J:=#1A3A2A}"
: "${_SSH_GHOSTTY_BG_C:=#1A2A3A}"
: "${_SSH_GHOSTTY_BG_P:=#3A1A1A}"
: "${_SSH_GHOSTTY_BG_U:=}"

# ── Profile → ct YAML mapping ────────────────────────────────────────────────
typeset -gA _SSH_PROFILE_MAP=(
    j  "juniper.yml"
    c  "cisco.yml"
    p  "panos.yml"
    u  "unix.yml"
)

# Human-readable profile names (used in completion descriptions and messages)
typeset -gA _SSH_PROFILE_NAMES=(
    j  "Juniper"
    c  "Cisco"
    p  "PAN-OS/Palo Alto"
    u  "Unix/Linux"
)

# ── Source sub-modules ───────────────────────────────────────────────────────
source "${_SSH_PLUGIN_DIR}/lib/ghostty.zsh"
# shellcheck disable=SC1094
source "${_SSH_PLUGIN_DIR}/lib/core.zsh"
source "${_SSH_PLUGIN_DIR}/lib/complete.zsh"
source "${_SSH_PLUGIN_DIR}/lib/init.zsh"

# ── Convenience aliases (uncomment to enable) ─────────────────────────────────
# alias ssj='_ssh -j'
# alias ssc='_ssh -c'
# alias ssp='_ssh -p'
# alias ssu='_ssh -u'
