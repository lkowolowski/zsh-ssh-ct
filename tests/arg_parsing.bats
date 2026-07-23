#!/usr/bin/env bats
# tests/arg_parsing.bats — _ssh() argument parsing and validation

load test_helper.bash

@test "missing profile flag errors" {
    run zsh_ssh_ct_eval '_ssh core-router'
    [ "$status" -eq 1 ]
    [[ "$output" == *"a profile flag (-j, -c, -p, -u) is required."* ]]
}

@test "multiple profile flags are rejected" {
    run zsh_ssh_ct_eval '_ssh -j -c core-router'
    [ "$status" -eq 1 ]
    [[ "$output" == *"multiple profile flags specified."* ]]
}

@test "missing host errors" {
    run zsh_ssh_ct_eval '_ssh -j'
    [ "$status" -eq 1 ]
    [[ "$output" == *"no host specified."* ]]
}

@test "unknown option errors" {
    run zsh_ssh_ct_eval '_ssh -j -z core-router'
    [ "$status" -eq 1 ]
    [[ "$output" == *"Unknown option: -z"* ]]
}

@test "-h prints usage and exits 0" {
    run zsh_ssh_ct_eval '_ssh -h'
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage: _ssh"* ]]
}

@test "--help prints usage and exits 0" {
    run zsh_ssh_ct_eval '_ssh --help'
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage: _ssh"* ]]
}

@test "-n dry run prints resolved command and exits 0" {
    run zsh_ssh_ct_eval '_ssh -j core-router -n'
    [ "$status" -eq 0 ]
    [[ "$output" == *"Dry run — resolved command:"* ]]
}
