#!/usr/bin/env bats
# tests/host_splitting.bats — user@host / user:port@host target resolution

load test_helper.bash

@test "plain hostname is passed through unchanged" {
    run zsh_ssh_ct_eval '_ssh -j core-router -n'
    [ "$status" -eq 0 ]
    [[ "$output" == *"ssh core-router"* ]]
}

@test "user@host is preserved in full for ssh" {
    run zsh_ssh_ct_eval '_ssh -j admin@core-router -n'
    [ "$status" -eq 0 ]
    [[ "$output" == *"ssh admin@core-router"* ]]
}

@test "user:port@host is preserved in full for ssh" {
    run zsh_ssh_ct_eval '_ssh -j admin:2222@core-router -n'
    [ "$status" -eq 0 ]
    [[ "$output" == *"ssh admin:2222@core-router"* ]]
}
