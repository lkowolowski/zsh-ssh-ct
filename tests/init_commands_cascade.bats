#!/usr/bin/env bats
# tests/init_commands_cascade.bats — _ssh_init_resolve() YAML cascade logic
#
# Calls _ssh_init_resolve directly (bypassing zpty/ssh) and prints the
# resulting globals in a parseable form:
#   exit=<code>
#   prompt=<_SSH_INIT_PROMPT>
#   timeout=<_SSH_INIT_TIMEOUT>
#   commands=<pipe-joined _SSH_INIT_COMMANDS>

load test_helper.bash

setup() {
    FIXTURE_DIR="$(mktemp -d)"
}

teardown() {
    rm -rf "${FIXTURE_DIR}"
}

resolve_script() {
    local profile="$1" host="$2"
    printf '_ssh_init_resolve %s %s; ec=$?; echo "exit=${ec}"; echo "prompt=${_SSH_INIT_PROMPT}"; echo "timeout=${_SSH_INIT_TIMEOUT}"; echo "commands=${(j:|:)_SSH_INIT_COMMANDS}"' "${profile}" "${host}"
}

@test "defaults-only config resolves default commands" {
    cat > "${FIXTURE_DIR}/init.yml" <<'EOF'
defaults:
  timeout: 5
  prompt: '[>#$]'
  commands:
    - "term length 0"
EOF
    export _SSH_REMOTE_CMDS="${FIXTURE_DIR}/init.yml"
    run zsh_ssh_ct_eval "$(resolve_script j core-router)"
    [ "$status" -eq 0 ]
    [[ "$output" == *"exit=0"* ]]
    [[ "$output" == *"commands=term length 0"* ]]
}

@test "platform commands merge with defaults, timeout overridden" {
    cat > "${FIXTURE_DIR}/init.yml" <<'EOF'
defaults:
  timeout: 5
  prompt: '[>#$]'
  commands:
    - "default-cmd"

platforms:
  juniper:
    timeout: 10
    commands:
      - "set cli screen-length 0"
EOF
    export _SSH_REMOTE_CMDS="${FIXTURE_DIR}/init.yml"
    run zsh_ssh_ct_eval "$(resolve_script j core-router)"
    [ "$status" -eq 0 ]
    [[ "$output" == *"timeout=10"* ]]
    [[ "$output" == *"commands=default-cmd|set cli screen-length 0"* ]]
}

@test "host commands merge and dedup against defaults+platform, prompt overridden" {
    cat > "${FIXTURE_DIR}/init.yml" <<'EOF'
defaults:
  commands:
    - "cmd-a"

platforms:
  juniper:
    commands:
      - "cmd-a"
      - "cmd-b"

hosts:
  core-router:
    platform: juniper
    prompt: 'custom>$'
    commands:
      - "cmd-b"
      - "cmd-c"
EOF
    export _SSH_REMOTE_CMDS="${FIXTURE_DIR}/init.yml"
    run zsh_ssh_ct_eval "$(resolve_script j core-router)"
    [ "$status" -eq 0 ]
    [[ "$output" == *"prompt=custom>\$"* ]]
    [[ "$output" == *"commands=cmd-a|cmd-b|cmd-c"* ]]
}

@test "commands: [\"none\"] inline flow-style triggers the sentinel (return 1)" {
    # The YAML parser recognizes both inline flow-style commands: ["none"]
    # (the syntax documented in docs/init-commands.md) and block-style
    # commands:\n  - "none" — both populate resolved_cmds with exactly
    # ("none"), which _ssh_init_resolve's sentinel check detects to skip
    # init-commands entirely.
    cat > "${FIXTURE_DIR}/init.yml" <<'EOF'
hosts:
  quiet-host:
    commands: ["none"]
EOF
    export _SSH_REMOTE_CMDS="${FIXTURE_DIR}/init.yml"
    run zsh_ssh_ct_eval "$(resolve_script u quiet-host)"
    [ "$status" -eq 0 ]
    [[ "$output" == *"exit=1"* ]]
    [ "${lines[-1]}" = "commands=" ]
}

@test "commands: [\"none\"] block-style also triggers the sentinel (return 1)" {
    cat > "${FIXTURE_DIR}/init.yml" <<'EOF'
hosts:
  quiet-host:
    commands:
      - "none"
EOF
    export _SSH_REMOTE_CMDS="${FIXTURE_DIR}/init.yml"
    run zsh_ssh_ct_eval "$(resolve_script u quiet-host)"
    [ "$status" -eq 0 ]
    [[ "$output" == *"exit=1"* ]]
    [ "${lines[-1]}" = "commands=" ]
}

@test "commands: [\"cmd-a\", \"cmd-b\"] inline flow-style resolves both commands" {
    cat > "${FIXTURE_DIR}/init.yml" <<'EOF'
defaults:
  commands: ["cmd-a", "cmd-b"]
EOF
    export _SSH_REMOTE_CMDS="${FIXTURE_DIR}/init.yml"
    run zsh_ssh_ct_eval "$(resolve_script j core-router)"
    [ "$status" -eq 0 ]
    [[ "$output" == *"exit=0"* ]]
    [[ "$output" == *"commands=cmd-a|cmd-b"* ]]
}

@test "missing config file returns 1 with hardcoded defaults" {
    export _SSH_REMOTE_CMDS="${FIXTURE_DIR}/does-not-exist.yml"
    run zsh_ssh_ct_eval "$(resolve_script j core-router)"
    [ "$status" -eq 0 ]
    [[ "$output" == *"exit=1"* ]]
    [[ "$output" == *'prompt=[>#$]'* ]]
    [[ "$output" == *"timeout=5"* ]]
}
