# zsh-ssh-ct.plugin.zsh
# Smart SSH wrapper with ChromaTerm (ct), fuzzy host matching, retry logic,
# host/profile caching, and tab completion.
#
# zgenom:  zgenom load <user>/zsh-ssh-ct
# Manual:  source /path/to/zsh-ssh-ct.plugin.zsh
#
# shellcheck shell=bash
# shellcheck disable=SC2034  # typeset -g globals are used across sourced files
# shellcheck disable=SC2190  # zsh associative arrays use key value syntax, not [key]=value
# shellcheck disable=SC2296  # ${0:A:h} is zsh parameter expansion syntax
# ─────────────────────────────────────────────────────────────────────────────

# ── Guard against double-sourcing ────────────────────────────────────────────
[[ -n "${_SSH_PLUGIN_LOADED}" ]] && return 0
typeset -g _SSH_PLUGIN_LOADED=1
typeset -g _SSH_PLUGIN_NAME="zsh-ssh-ct"
typeset -g _SSH_PLUGIN_VERSION="2.1.0"

# ── Resolve plugin directory (works with zgenom, zinit, manual source) ───────
# shellcheck disable=SC2296  # ${0:A:h} is zsh parameter expansion syntax
typeset -g _SSH_PLUGIN_DIR="${0:A:h}"

# ── User-configurable defaults ───────────────────────────────────────────────
# Set any of these in your .zshrc BEFORE sourcing / loading the plugin.
#
#   Variable               Default                         Purpose
#   ─────────────────────────────────────────────────────────────────────────
#   _SSH_CT_CONFIG_DIR     <plugin_dir>/ct                 ct YAML config dir
#   _SSH_CACHE_FILE        ~/.cache/zsh-ssh-ct/hosts       host cache path
#   _SSH_MAX_RETRIES       60                              max ping retries
#   _SSH_RETRY_SLEEP       30                              seconds between retries
#   _SSH_CACHE_TTL_DAYS    30                              cache entry TTL (0=forever)
#   _SSH_FUZZY_CONFIRM     0                               prompt before fuzzy connect
#
: "${_SSH_CT_CONFIG_DIR:=${HOME}/.local/chromaterm}"
: "${_SSH_CACHE_FILE:=${HOME}/.cache/zsh-ssh-ct/hosts}"
: "${_SSH_MAX_RETRIES:=60}"
: "${_SSH_RETRY_SLEEP:=30}"
: "${_SSH_CACHE_TTL_DAYS:=30}"
: "${_SSH_FUZZY_CONFIRM:=0}"

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
    p  "PAN-OS / Palo Alto"
    u  "Unix / Linux"
)

# ── Source sub-modules ───────────────────────────────────────────────────────
source "${_SSH_PLUGIN_DIR}/lib/cache.zsh"
source "${_SSH_PLUGIN_DIR}/lib/core.zsh"
source "${_SSH_PLUGIN_DIR}/lib/complete.zsh"

# ── Auto-prune stale cache entries (at most once per day, runs in background) ─
_ssh_cache_maybe_prune

# ── Convenience aliases (uncomment to enable) ─────────────────────────────────
# alias ssj='_ssh -j'
# alias ssc='_ssh -c'
# alias ssp='_ssh -p'
# alias ssu='_ssh -u'
