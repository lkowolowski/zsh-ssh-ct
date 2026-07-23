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

@test "commands: [\"none\"] (documented inline sentinel) yields zero commands" {
    # NOTE: the YAML parser only understands block-style `commands:\n  - "x"`
    # lists. The inline flow-style `commands: ["none"]` syntax documented in
    # docs/init-commands.md as the sentinel is silently ignored by the
    # line-based parser (it never populates resolved_cmds with "none"), so
    # the dedicated sentinel-detection branch in _ssh_init_resolve
    # (`resolved_cmds == ("none")` -> return 1) is unreachable dead code for
    # any config written in the documented syntax. The end-user-visible
    # behavior is still correct only because _ssh_init_execute has its own
    # independent `(( ${#commands[@]} > 0 )) || return 0` safety net — so
    # zero commands are sent either way, but via return 0 + empty array
    # here, NOT via the documented return 1 sentinel path.
    cat > "${FIXTURE_DIR}/init.yml" <<'EOF'
hosts:
  quiet-host:
    commands: ["none"]
EOF
    export _SSH_REMOTE_CMDS="${FIXTURE_DIR}/init.yml"
    run zsh_ssh_ct_eval "$(resolve_script u quiet-host)"
    [ "$status" -eq 0 ]
    [[ "$output" == *"exit=0"* ]]
    [ "${lines[-1]}" = "commands=" ]
}

@test "commands: [\"none\"] via block-style DOES trigger the documented sentinel (return 1)" {
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

@test "missing config file returns 1 with hardcoded defaults" {
    export _SSH_REMOTE_CMDS="${FIXTURE_DIR}/does-not-exist.yml"
    run zsh_ssh_ct_eval "$(resolve_script j core-router)"
    [ "$status" -eq 0 ]
    [[ "$output" == *"exit=1"* ]]
    [[ "$output" == *'prompt=[>#$]'* ]]
    [[ "$output" == *"timeout=5"* ]]
}
