# ADR-002: Single-File YAML Config for Init-Commands

## Status

Accepted

## Context

The init-commands feature needs a config location for platform/host command
definitions. Options considered:

1. **Directory-based (`_SSH_REMOTE_CMDS_DIR`)** — one file per host/platform, scanned
   at runtime
2. **Inline in plugin defaults** — commands hardcoded in lib/init.zsh
3. **Single YAML file** — all platforms and hosts in one file

## Decision

Use a single YAML file, path defined by `_SSH_REMOTE_CMDS` env var (default
`~/.config/zsh-ssh-ct/init-commands.yml`).

Rationale:

- Single file is simpler to maintain, copy, and version-control
- YAML is readable and supports nested structure (defaults → platforms → hosts)
- Users can `cp configs/init-commands.yml ~/.config/zsh-ssh-ct/` and customize
- Directory-based would require file-system traversal and merging logic
- Hardcoded commands would require plugin edits to customize

## Consequences

- Config is parsed from a single file using pure-zsh line-by-line parsing
- No external YAML parser needed (avoided to keep zero-dep promise)
- Host-specific commands append to platform commands with dedup
- Silent skip when no config file exists
- `commands: ["none"]` sentinel allows explicit opt-out per host
