# ADR-001: Init-Commands via zsh/zpty

## Status

Accepted

## Context

The init-commands feature needs to send commands to a remote SSH session and wait for
prompt responses before handing control to the user. Several approaches exist:

1. **expect** — requires external install, not always available on macOS/Linux
2. **empty** (expect-like for ssh) — external dep, niche
3. **Named pipes / process substitution** — fragile, race-prone
4. **zsh/zpty** — built-in zsh module, zero external dependencies

## Decision

Use `zsh/zpty` as the terminal bridge.

`zmodload zsh/zpty` creates a pseudo-terminal that wraps the SSH process. The plugin:

1. Starts `ct ssh user@host` inside a zpty (`zpty -b`)
2. Waits for the prompt regex using `zpty -r -t` with timeout
3. Sends each init-command via `zpty -w`
4. After all commands, bridges terminal I/O bidirectionally

## Consequences

- Zero external dependencies — works on any system with zsh
- Reliable prompt detection via timeout + regex
- Variable expansion via `${(e)}` on command strings
- zpty module must be available (zsh 4.0+, always present in modern zsh)
- `zpty -b` runs the process in the background, requiring explicit terminal bridge
