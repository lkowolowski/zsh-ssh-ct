# Init-Commands

When you connect without a remote command (`_ssh -j core-router`), the plugin
can automatically send a sequence of platform/host-specific commands after the
SSH session establishes — useful for disabling pagers, setting terminal length,
or other init boilerplate.

## How it works

1. A config-driven YAML file defines commands per platform and per host
2. Commands are sent via zsh/zpty (zero external dependencies)
3. Layer precedence: **host > platform > defaults**
4. Platform commands go first, host commands append (deduped first-match-wins)
5. Variable expansion (`${COLUMNS}`, `$(uname)`, arithmetic) is supported via `${(e)}`
6. Silent skip when: no config file, no match, or `commands: ["none"]`

## Config file

Default path: `~/.config/zsh-ssh-ct/init-commands.yml` (override via `_SSH_REMOTE_CMDS`)

```yaml
defaults:
  timeout: 5
  prompt: '[>#$]'
  commands: []

platforms:
  juniper:
    prompt: '> $'
    timeout: 10
    commands:
      - "set cli screen-length 0"
      - "set cli timestamp"
  cisco:
    prompt: '[#>]'
    commands:
      - "term length 0"
      - "term width 0"
  panos:
    prompt: '[>#$]'
    commands:
      - "set cli pager off"
      - "set session timeout 0"
  unix:
    prompt: '[#$]'

hosts:
  core-router:
    platform: juniper
    prompt: 'custom>$'
    timeout: 15
    commands:
      - "show configuration | display set"
  backup-router:
    platform: juniper
    commands: ["none"]            # explicit opt-out
  legacy-switch:
    platform: cisco               # inherits all platform commands
```

The `configs/init-commands.yml` file in this repo is a starter template — copy it
to `~/.config/zsh-ssh-ct/init-commands.yml` and customize.

## Schema

|Field|Level|Type|Description|
|-----|-----|----|-----------|
|`timeout`|defaults / platform / host|integer|Seconds to wait for prompt before timeout (default: 5)|
|`prompt`|defaults / platform / host|string|Regex pattern to detect prompt (default: `[>#$]`)|
|`commands`|defaults / platform / host|list of strings|Commands to send after prompt match|
|`platform`|host|string|Platform name to inherit commands from (juniper, cisco, panos, unix)|

Cascade precedence: **host > platform > defaults**. A value set at any level
overrides the level below.

## Command layering

1. Default commands (from `defaults.commands`)
2. Platform commands (from `platforms.<name>.commands`) — appended
3. Host commands (from `hosts.<name>.commands`) — appended

Deduplication is **first-match-wins**: if a command appears in multiple levels,
only the first occurrence (from the lowest-precedence level) is kept.

## Sentinel skip

Set `commands: ["none"]` on a host to skip init-commands entirely:

```yaml
hosts:
  backup-router:
    platform: juniper
    commands: ["none"]
```

## Profile gating

By default init-commands are skipped for the `unix` profile (`u`). Override with:

```zsh
export _SSH_INIT_CMD_SKIP_PROFILES=""     # run on all profiles
export _SSH_INIT_CMD_SKIP_PROFILES="uc"   # skip unix and cisco
```

## Variable expansion

Commands support zsh `${(e)}` expansion, enabling dynamic values:

```yaml
platforms:
  unix:
    commands:
      - "echo 'Terminal columns: ${COLUMNS}'"
      - "export MY_VAR=$(hostname -s)"
```

## Verbose mode

Pass `-v` to see the "sending init-commands..." banner:

```zsh
_ssh -j core-router -v
```
