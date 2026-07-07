# zsh-ssh-ct

A zsh plugin that wraps SSH with [ChromaTerm
(`ct`)](https://github.com/hSaria/ChromaTerm) for syntax-highlighted output, fuzzy
host matching, automatic retry with status display, host/profile caching with TTL,
and rich tab completion.

## Features

- **Profile-based ct configs** — `-j` Juniper, `-c` Cisco, `-p` PAN-OS, `-u` Unix
- **Ping retry loop** — waits up to `_SSH_MAX_RETRIES` × `_SSH_RETRY_SLEEP` with
  single-line status; replaces ✗ on success with ✓
- **Fuzzy host matching** — scores candidates from cache, `~/.ssh/config`,
  and `~/.ssh/known_hosts`
- **Host/profile cache** — remembers connections with TTL; secure permissions;
  background auto-prune
- **Init-commands** — sends platform boilerplate after SSH connects via zsh/zpty
  ([docs](docs/init-commands.md))
- **Tab completion** — profile-aware host names, remote command suggestions,
  works before or after `compinit`
- **Ghostty background colors** — changes terminal background per device type
  ([docs](docs/ghostty-bg.md))
- **ct is optional** — falls back to plain `ssh` with no highlighting
- **ct highlight configs** — bundled YAMLs for all four device types
  ([docs](docs/ct-highlight.md))

## Quick start

```sh
# Prerequisite (optional): ChromaTerm
brew install uv && uv tool install chromaterm

# Copy profiles and create configs
mise run install

# Add to ~/.zshrc (config overrides before source):
source /path/to/zsh-ssh-ct.plugin.zsh
```

## Usage at a glance

```zsh
_ssh -j core-router                           # connect with Juniper profile
_ssh -c switch "show interfaces status"       # passthrough remote command
_ssh -p fw-01 -v                              # verbose SSH
_ssh -u web-01 -n                             # dry run
_ssh -j -H core-rtr-01                        # exact host, skip fuzzy
```

See [docs/usage.md](docs/usage.md) for full usage, flags, fuzzy matching,
retry behavior, and tab completion details.

## Further reading

- [Usage](docs/usage.md) — profiles, flags, fuzzy matching, completion
- [Configuration](docs/configuration.md) — all environment variables
- [Cache management](docs/cache.md) — show, prune, delete, TTL
- [Init-commands](docs/init-commands.md) — auto-send platform commands
- [ct highlight configs](docs/ct-highlight.md) — bundled YAML profiles
- [Ghostty background colors](docs/ghostty-bg.md) — dynamic terminal bg

## File layout

```text
├── zsh-ssh-ct.plugin.zsh    ← loader: defaults, sources lib/, auto-prune
├── lib/
│   ├── cache.zsh            ← cache read/write/TTL/prune/display
│   ├── core.zsh             ← _ssh(), fuzzy match, ping, retry, usage
│   ├── complete.zsh         ← tab completion, deferred compdef
│   ├── init.zsh             ← init-commands via zsh/zpty
│   └── ghostty.zsh          ← OSC 11 save/restore for Ghostty bg
├── profiles/                ← ct-highlight YAMLs (5 device types)
├── configs/
│   ├── init-commands.yml    ← starter init-commands config
│   └── ghostty-bg.yml       ← starter Ghostty bg config
├── docs/
│   ├── usage.md             ← full usage reference
│   ├── configuration.md     ← all config vars
│   ├── cache.md             ← cache commands
│   ├── init-commands.md     ← init-commands schema
│   ├── ct-highlight.md      ← ct highlight reference
│   ├── ghostty-bg.md        ← Ghostty bg color reference
│   └── ADR/                 ← architecture decision records
├── mise.toml                ← task runner (lint, install)
└── README.md
```
