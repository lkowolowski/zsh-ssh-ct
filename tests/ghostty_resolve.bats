#!/usr/bin/env bats
# tests/ghostty_resolve.bats — _ssh_ghostty_resolve() precedence:
#   config file > env var > hardcoded default > empty

load test_helper.bash

@test "config-file color wins over env var" {
    run zsh_ssh_ct_eval '
        typeset -gA _SSH_GHOSTTY_CFG=( j "#111111" )
        export _SSH_GHOSTTY_BG_J="#222222"
        _ssh_ghostty_resolve j
    '
    [ "$status" -eq 0 ]
    [ "$output" = "#111111" ]
}

@test "env var wins when no config-file color set" {
    run zsh_ssh_ct_eval '
        typeset -gA _SSH_GHOSTTY_CFG=()
        export _SSH_GHOSTTY_BG_J="#ABCDEF"
        _ssh_ghostty_resolve j
    '
    [ "$status" -eq 0 ]
    [ "$output" = "#ABCDEF" ]
}

@test "hardcoded default wins when nothing else set" {
    run zsh_ssh_ct_eval '
        typeset -gA _SSH_GHOSTTY_CFG=()
        unset _SSH_GHOSTTY_BG_J
        _ssh_ghostty_resolve j
    '
    [ "$status" -eq 0 ]
    [ "$output" = "#1A3A2A" ]
}

@test "unix profile with nothing set resolves to empty" {
    run zsh_ssh_ct_eval '
        typeset -gA _SSH_GHOSTTY_CFG=()
        unset _SSH_GHOSTTY_BG_U
        _ssh_ghostty_resolve u
    '
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}
