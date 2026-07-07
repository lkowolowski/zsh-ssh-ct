# Usage

## Profile flags

```zsh
_ssh -j <host>   # Juniper  — ct -c juniper.yml
_ssh -c <host>   # Cisco    — ct -c cisco.yml
_ssh -p <host>   # PAN-OS   — ct -c panos.yml
_ssh -u <host>   # Unix     — ct -c unix.yml
```

A profile flag is **required** — the plugin uses it to select the ChromaTerm
highlight config and (optionally) the Ghostty background color.

## Host specification

```zsh
_ssh -j core-router        # plain hostname
_ssh -j admin@core-router  # user@host
_ssh -j -H core-rtr-01     # -H bypasses fuzzy matching entirely
```

Hostnames can include a `user@` prefix — it is preserved and passed to SSH.

### Bare IP addresses

If you pass a raw IPv4 or IPv6 address instead of a hostname, the plugin
automatically treats it as an **exact host** (same as `-H`) and skips fuzzy
matching. No configuration needed.

```zsh
_ssh -j 192.168.1.1          # IPv4 — treated as exact
_ssh -c 2001:db8::1          # IPv6 — treated as exact
```

## Flags

| Flag | Description |
| ---- | ----------- |
| `-H <host>` | Exact hostname — skip DNS/ping/fuzzy, use verbatim |
| `-v` | Verbose — forwarded to `ssh` as `-v` |
| `-n` | Dry run — print the resolved command without executing |
| `-f` | Force — skip ping/DNS checks, try SSH immediately |

### Remote command passthrough

Pass a command after the hostname to execute it remotely and exit:

```zsh
_ssh -j core-router "show interfaces descriptions"
_ssh -u web-server "uname -a"
_ssh -p fw-01 "show session all"
```

When a remote command is provided, the plugin skips init-commands (no boilerplate
commands are sent before the command runs).

### Verbose mode

```zsh
_ssh -j core-router -v             # SSH -v + connection details
_ssh -j core-router "show ver" -v  # verbose with command passthrough
```

The `-v` flag is forwarded to SSH and also enables the init-commands banner.

### Dry run

```zsh
_ssh -j rtr -n
# Output: [_ssh] Dry run — resolved command:
#   ct -c /path/to/juniper.yml ssh rtr
```

Use `-n` to see exactly which ct config and SSH target would be used.

### Force mode

```zsh
_ssh -u web-server -f
```

Skips DNS resolution and ping checks. Useful when:

- ICMP is blocked by a firewall
- The host is reachable via SSH but not ping
- You're on a slow or unreliable network

## ct config fallback

The plugin looks for a profile-specific YAML in `_SSH_CT_CONFIG_DIR` (e.g.
`juniper.yml` for `-j`). If that file doesn't exist, it falls back to
`generic.yml`. If neither exists, `ct` runs with its default config (no
device-specific highlighting).

## Fuzzy host matching

When you type a partial hostname, the plugin scores candidates from four sources:

| Priority | Source | Example match |
| -------- | ------ | ------------- |
| 1 | Host cache (profile-filtered) | Previous `-j` connections |
| 2 | Host cache (all profiles) | Previous connections to any profile |
| 3 | `~/.ssh/config` | `Host` entries |
| 4 | `~/.ssh/known_hosts` | Parsed (hashed entries skipped) |

`_ssh -j core` might resolve to `core-rtr-01` if that's the highest-scoring
candidate.

### Fuzzy confirmation prompt

Set `_SSH_FUZZY_CONFIRM=1` to be prompted before connecting to a fuzzy-matched
host:

```text
[_ssh] Fuzzy matched 'core' → 'core-rtr-01'
[_ssh] Connect to core-rtr-01? [Y/n]
```

## Retry loop

When a host doesn't respond to ping, the plugin enters a retry loop:

```text
[_ssh] core-router (Juniper) ✗ ✗ ✗
```

Each failed attempt appends a red ✗ to the status line. On success the line
is replaced with a green ✓. The loop exits after `_SSH_MAX_RETRIES` (default:
60) attempts with `_SSH_RETRY_SLEEP` (default: 30s) between each.

### DNS vs ICMP distinction

DNS resolution is checked **before** the ping loop. If the hostname doesn't
resolve at all, the plugin reports a DNS error immediately rather than retrying
pings against a nonexistent name.

### Smart exit codes

- SSH exit code **255** (connection failure) is reported explicitly
- Application-level non-zero exit codes (1, 2, etc.) pass through silently
- Ctrl+C / `SIGINT` exits cleanly with no error message

## Tab completion

### Host completion

After typing a profile flag, press `<Tab>` to see matching hosts annotated
with their source:

```text
_ssh -j <Tab>
core-rtr-01       (Juniper)
core-switch       (Juniper)
backup-router     (ssh/config)
```

Completion candidates come from four tiers in this order:

1. Host cache — matching profile first, then all profiles
2. `~/.ssh/config` — `Host` entries
3. `~/.ssh/known_hosts` — non-hashed entries (parsed once, cached by mtime)

### Profile-aware remote commands

After typing a hostname, press `<Tab>` again to see device-specific command
suggestions:

- **Juniper:** `show interfaces descriptions`, `show version`, `show bgp summary`, ...
- **Cisco:** `show running-config`, `show ip interface brief`, `show spanning-tree`, ...
- **PAN-OS:** `show system info`, `show security policies`, `show log system`, ...
- **Unix/Linux:** `uname -a`, `df -h`, `ps aux`, `ip addr show`, ...

### Source order independence

The plugin registers completions via `compdef`. If `compinit` hasn't run yet
at source time, a `precmd` hook fires on the first prompt to register them,
then removes itself. This means you can source the plugin **before or after**
`compinit`.

### Cache management completion

`_ssh_cache_delete <Tab>` completes hostnames from the cache with annotations.
