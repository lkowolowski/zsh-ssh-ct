# zsh-ssh-ct

A zsh plugin that wraps SSH with [ChromaTerm
(`ct`)](https://github.com/hSaria/ChromaTerm) for syntax-highlighted output,
automatic retry with status display, and rich tab completion.

## Features

- **Profile-based ct configs** — `-j` Juniper, `-c` Cisco, `-p` PAN-OS, `-u` Unix
- **Ping retry loop** — waits up to `_SSH_MAX_RETRIES` × `_SSH_RETRY_SLEEP` with
  single-line status; replaces ✗ on success with ✓

- **Init-commands** — sends platform boilerplate after SSH connects via zsh/zpty
  ([docs](docs/init-commands.md))
- **Bundled ct highlight configs** — full ct-highlight YAMLs for all four device
  types in `profiles/` ([docs](docs/ct-highlight.md))
- **Ghostty background integration** — optional OSC 11 switching per profile with
  automatic restore ([docs](docs/ghostty-bg.md))

---

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
```

See [docs/usage.md](docs/usage.md) for full usage, flags,
retry behavior, and tab completion details.

## Further reading

- **Init-commands** — [docs/init-commands.md](docs/init-commands.md) — full schema,
  layering, gating
- **ct highlight configs** — [docs/ct-highlight.md](docs/ct-highlight.md) — setup,
  profiles, customization
- **Ghostty background integration** — [docs/ghostty-bg.md](docs/ghostty-bg.md) —
  enablement, config layering, save/restore behavior

## File layout

```text
├── zsh-ssh-ct.plugin.zsh    ← loader: defaults, sources lib/
├── lib/
│   ├── core.zsh             ← _ssh(), ping, retry, usage
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
│   ├── init-commands.md     ← init-commands schema
│   ├── ct-highlight.md      ← ct highlight reference
│   ├── ghostty-bg.md        ← Ghostty bg color reference
│   └── ADR/                 ← architecture decision records
├── mise.toml                ← task runner (lint, install)
└── README.md
```
