# zsh-ssh-ct

A zsh plugin that wraps SSH with [ChromaTerm (`ct`)](https://github.com/hSaria/ChromaTerm) for syntax-highlighted output, fuzzy host matching, automatic retry with a single-line status display, host/profile caching with TTL, and rich tab completion.

---

## Features

- **Profile-based ct configs** — `-j` Juniper, `-c` Cisco, `-p` PAN-OS, `-u` Unix
- **Ping-before-connect retry loop** — waits up to 60 × 30s for a host to come up; each failed attempt appends a red ✗ to a single status line, replaced with a green ✓ on success
- **Fuzzy host matching** — resolves partial names against `/etc/hosts`, `~/.ssh/known_hosts`, `~/.ssh/config`, and the local cache
- **Exact hostname override** — `-H <host>` bypasses fuzzy matching entirely
- **Fuzzy confirmation prompt** — opt-in prompt before connecting to a fuzzy-matched host
- **Host/profile cache with TTL** — remembers recent connections; entries expire after 30 days by default; auto-pruned once per day in the background
- **Secure cache** — cache directory `700`, cache file `600`
- **Portable ping** — correct flags detected for macOS and Linux at source time
- **DNS vs ICMP distinction** — reports DNS failures separately from ping failures
- **Dry run mode** — `-n` prints the fully resolved command without executing
- **Remote command passthrough** — pass a quoted command after the hostname
- **Verbose SSH** — `-v` is forwarded to `ssh`
- **Smart exit codes** — SSH-level failures (255) are reported; application-level non-zero codes pass through silently
- **Context-aware tab completion** — hostnames annotated with profile; post-hostname completions offer device-specific commands (`show version`, `uname -a`, etc.)
- **Completion works regardless of source order** — deferred `compdef` registration means the plugin can be sourced before or after `compinit`
- **Bundled starter ct YAML configs** for all four device types

---

## Prerequisite

```sh
pip3 install chromaterm
```

---

## Installation

### zgenom

```zsh
# In your .zshrc zgenom save block:
zgenom load <yourgithubuser>/zsh-ssh-ct
```

### zinit

```zsh
zinit light <yourgithubuser>/zsh-ssh-ct
```

### Oh My Zsh

```zsh
# Clone into OMZ custom plugins directory
git clone https://github.com/<yourgithubuser>/zsh-ssh-ct \
    "${ZSH_CUSTOM:-${HOME}/.oh-my-zsh/custom}/plugins/zsh-ssh-ct"

# Add to plugins list in ~/.zshrc
plugins=(... zsh-ssh-ct)
```

### Manual

```zsh
# 1. Clone the repo
git clone https://github.com/<yourgithubuser>/zsh-ssh-ct ~/.zsh/zsh-ssh-ct

# 2. Add to ~/.zshrc — config overrides MUST come before the source line
#    (see Configuration section below)
source ~/.zsh/zsh-ssh-ct/zsh-ssh-ct.plugin.zsh
```

#### Note on `compinit` order (manual installs only)

The plugin handles this automatically. You can source it **before or after** `compinit` and tab completion will work either way:

```zsh
# This works:
source ~/.zsh/zsh-ssh-ct/zsh-ssh-ct.plugin.zsh
autoload -Uz compinit && compinit

# This also works:
autoload -Uz compinit && compinit
source ~/.zsh/zsh-ssh-ct/zsh-ssh-ct.plugin.zsh
```

If `compdef` isn't available at source time, a `precmd` hook fires on the first prompt to register completions, then removes itself.

---

## Usage

```zsh
_ssh -j <host>                        # Juniper  — ct -c juniper.yml
_ssh -c <host>                        # Cisco    — ct -c cisco.yml
_ssh -p <host>                        # PAN-OS   — ct -c panos.yml
_ssh -u <host>                        # Unix     — ct -c unix.yml

_ssh -j core-router "show interfaces descriptions"
_ssh -u web-server  "uname -a"
_ssh -p fw-01 -v                      # verbose ssh
_ssh -j rtr -n                        # dry run — print command only
_ssh -j -H core-rtr-01               # exact hostname, skip fuzzy matching
```

Fuzzy matching: `_ssh -j core` resolves to e.g. `core-rtr-01` if that's the
best scoring candidate from your known hosts / cache.

---

## Configuration

Set any of these in your `.zshrc` **before** the `source` / `zgenom load` line:

| Variable              | Default                       | Description                                                                               |
| --------------------- | ----------------------------- | ----------------------------------------------------------------------------------------- |
| `_SSH_CT_CONFIG_DIR`  | `$XDG_CONFIG_HOME/chromaterm` | Directory containing ct YAML files (`~/.config/chromaterm` if `XDG_CONFIG_HOME` is unset) |
| `_SSH_CACHE_FILE`     | `~/.cache/zsh-ssh-ct/hosts`   | Host cache file path                                                                      |
| `_SSH_MAX_RETRIES`    | `60`                          | Maximum ping retry iterations                                                             |
| `_SSH_RETRY_SLEEP`    | `30`                          | Seconds between retries                                                                   |
| `_SSH_CACHE_TTL_DAYS` | `30`                          | Days before cache entries expire (`0` = forever)                                          |
| `_SSH_FUZZY_CONFIRM`  | `0`                           | Set to `1` to prompt before connecting to fuzzy-matched hosts                             |

### Example `.zshrc`

```zsh
# Overrides — must precede the source/load line
export _SSH_CT_CONFIG_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/chromaterm"
export _SSH_CACHE_TTL_DAYS=7
export _SSH_FUZZY_CONFIRM=1
export _SSH_MAX_RETRIES=10
export _SSH_RETRY_SLEEP=15

# Plugin load (choose one)
source ~/.zsh/zsh-ssh-ct/zsh-ssh-ct.plugin.zsh   # manual
# zgenom load <yourgithubuser>/zsh-ssh-ct         # zgenom
```

---

## Cache management

| Command                              | Description                                            |
| ------------------------------------ | ------------------------------------------------------ |
| `_ssh_cache_show`                    | Pretty-print the cache table with last-seen timestamps |
| `_ssh_cache_clear`                   | Wipe the entire cache                                  |
| `_ssh_cache_prune`                   | Remove only entries older than `_SSH_CACHE_TTL_DAYS`   |
| `_ssh_cache_delete <host>`           | Remove all entries for a specific host                 |
| `_ssh_cache_delete <host> <profile>` | Remove a specific host:profile pair                    |

The cache is also auto-pruned silently in the background at most once per day.

---

## Bundled ct configs

The `ct/` directory contains starter highlight rules for each profile. By
default the plugin looks in `~/.local/chromaterm/` for your YAML files. The
bundled configs in `ct/` are provided as a starting point — copy or symlink
them there and customise as needed:

```zsh
mkdir -p "${XDG_CONFIG_HOME:-${HOME}/.config}/chromaterm"
cp ~/.zsh/zsh-ssh-ct/ct/*.yml "${XDG_CONFIG_HOME:-${HOME}/.config}/chromaterm/"
```

| File          | Device type                                               |
| ------------- | --------------------------------------------------------- |
| `generic.yml` | Catch-all — used when no profile-specific config is found |
| `juniper.yml` | Juniper JunOS                                             |
| `cisco.yml`   | Cisco IOS / IOS-XE / NX-OS                                |
| `panos.yml`   | Palo Alto PAN-OS                                          |
| `unix.yml`    | Linux / Unix                                              |

---

## Known limitations

**Completion cache is per-session** — `~/.ssh/known_hosts` is parsed once per shell session and cached in memory, invalidated only when the file's mtime changes. If you SSH to a new host in one terminal and want it to appear in completions in another, open a new shell or run `_ssh_cache_clear` to force a refresh.

**Auto-prune races are unlikely but possible** — the daily prune runs in a background subshell. On a slow filesystem, a rapid `_ssh` invocation immediately after shell startup could theoretically overlap with the prune writing the cache file. The `mv -f` atomic replace makes actual corruption very unlikely, but if you ever see an empty or truncated cache, run `_ssh_cache_clear` to reset it.

**`ct` must be on `$PATH` at call time** — the plugin checks for `ct` when you run `_ssh`, not at shell startup. If `ct` is installed inside a virtualenv or added to `$PATH` by a lazy loader, it will work as long as it's available by the time you invoke `_ssh`. If it isn't found, you'll get a clear error with install instructions.

---

## File layout

```text
├── zsh-ssh-ct.plugin.zsh   ← loader: sets defaults, sources lib/, triggers auto-prune
├── lib/
│   ├── cache.zsh           ← cache read/write/TTL/prune/display
│   ├── core.zsh            ← _ssh(), fuzzy match, ping, retry loop, usage
│   └── complete.zsh        ← tab completion with deferred compdef registration
├── ct/
│   ├── juniper.yml         ← starter ChromaTerm rules
│   ├── cisco.yml
│   ├── panos.yml
│   └── unix.yml
└── README.md
```
