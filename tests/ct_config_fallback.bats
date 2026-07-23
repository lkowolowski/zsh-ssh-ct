#!/usr/bin/env bats
# tests/ct_config_fallback.bats — ct config resolution / fallback logic

load test_helper.bash

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    FAKE_BIN_DIR="$(mktemp -d)"

    # Dummy `ct` executable so ct_available=1 without requiring real ChromaTerm.
    cat > "${FAKE_BIN_DIR}/ct" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "${FAKE_BIN_DIR}/ct"

    export _SSH_CT_CONFIG_DIR="${TEST_TMPDIR}"
    export PATH="${FAKE_BIN_DIR}:${PATH}"
}

teardown() {
    rm -rf "${TEST_TMPDIR}" "${FAKE_BIN_DIR}"
}

@test "profile-specific yaml is used when present" {
    touch "${TEST_TMPDIR}/juniper.yml"
    run zsh_ssh_ct_eval '_ssh -j core-router -n'
    [ "$status" -eq 0 ]
    [[ "$output" == *"ct config: juniper.yml"* ]]
    [[ "$output" != *"falling back"* ]]
}

@test "falls back to generic.yml when profile yaml missing" {
    touch "${TEST_TMPDIR}/generic.yml"
    run zsh_ssh_ct_eval '_ssh -j core-router -n'
    [ "$status" -eq 0 ]
    [[ "$output" == *"falling back to generic.yml"* ]]
    [[ "$output" == *"ct config: generic.yml"* ]]
}

@test "falls back to ct default when no config files exist" {
    run zsh_ssh_ct_eval '_ssh -j core-router -n'
    [ "$status" -eq 0 ]
    [[ "$output" == *"no ct config found. Using ct default."* ]]
    [[ "$output" == *"ct config: (ct default)"* ]]
}

@test "reports (no ct) when ct is not installed" {
    export PATH="/usr/bin:/bin"
    run zsh_ssh_ct_eval '_ssh -j core-router -n'
    [ "$status" -eq 0 ]
    [[ "$output" == *"ct config: (no ct)"* ]]
}
