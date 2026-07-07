# Ghostty Background Color Integration

When you connect to a device via `_ssh`, the plugin can dynamically change
your [Ghostty](https://ghostty.org) terminal background color to provide a
visual cue of which device type you're connected to. The background restores
to its original color when the SSH session ends.

## How it works

1. Ghostty supports [OSC 10–19][osc-dynamic] for querying and changing
   dynamic colors at runtime — no config reload or file I/O required
2. On SSH connect: the plugin resolves a color for the profile (Juniper,
   Cisco, PAN-OS, Unix), saves the current background, and sends OSC 11
3. On SSH disconnect: the plugin restores the saved background via OSC 11,
   or falls back to OSC 111 (reset to config default) if no save exists

[osc-dynamic]: https://ghostty.org/docs/vt/osc/1x

## Prerequisites

- **Ghostty** — detected via `TERM_PROGRAM=ghostty`
- **Feature enabled** — set `_SSH_GHOSTTY_BG_ENABLE=1`

No external tools are required. The save/restore mechanism uses only
Zsh builtins and `stty`/`dd` for the terminal query fallback.

## Config file

Default path: `~/.config/zsh-ssh-ct/ghostty-bg.yml` (override via
`_SSH_GHOSTTY_BG_CONFIG`)

```yaml
# Colors MUST be quoted (YAML treats bare # as comment).
# null = no background change for that profile.

j: "#1A3A2A" # Juniper
c: "#1A2A3A" # Cisco
p: "#3A1A1A" # PAN-OS
u: null # Unix — no change
```

## Save / restore

On the first SSH connection of each session, the plugin attempts to capture
the current background color using this cascade:

| Priority | Method                                   | Captures                          |
| -------- | ---------------------------------------- | --------------------------------- |
| 1        | OSC 11 query (`\e]11;?\a`)               | Theme, runtime-set colors, config |
| 2        | Read Ghostty config (`background = ...`) | Config-file colors only           |
| 3        | Fall back to empty                       | OSC 111 (reset to config default) |

On disconnect, the saved color is restored. If no color was saved (all
queries failed), OSC 111 is sent to reset to the Ghostty config default.

## Configuration reference

| Variable                 | Default                               | Purpose                                   |
| ------------------------ | ------------------------------------- | ----------------------------------------- |
| `_SSH_GHOSTTY_BG_ENABLE` | `0`                                   | Set to `1` to enable background switching |
| `_SSH_GHOSTTY_BG_CONFIG` | `~/.config/zsh-ssh-ct/ghostty-bg.yml` | YAML config path                          |
| `_SSH_GHOSTTY_BG_J`      | `#1A3A2A`                             | Juniper background color (fallback)       |
| `_SSH_GHOSTTY_BG_C`      | `#1A2A3A`                             | Cisco background color (fallback)         |
| `_SSH_GHOSTTY_BG_P`      | `#3A1A1A`                             | PAN-OS background color (fallback)        |
| `_SSH_GHOSTTY_BG_U`      | _(empty)_                             | Unix background color (empty = no change) |

## Color resolution order

The final color for a profile is resolved with this layering
(highest priority first):

1. **Config file** — `_SSH_GHOSTTY_BG_CONFIG` YAML
2. **Environment variable** — `_SSH_GHOSTTY_BG_J/C/P/U`
3. **Built-in default** — hardcoded in the plugin
4. **Empty string** — no background change

## Example `.zshrc`

```zsh
# Enable Ghostty background switching
export _SSH_GHOSTTY_BG_ENABLE=1

# Optional: override colors
export _SSH_GHOSTTY_BG_J="#004422"
export _SSH_GHOSTTY_BG_C="#002244"

# Optional: custom config path
export _SSH_GHOSTTY_BG_CONFIG="${XDG_CONFIG_HOME}/zsh-ssh-ct/ghostty-bg.yml"

# Plugin load (must come after config overrides)
source ~/.zsh/zsh-ssh-ct/zsh-ssh-ct.plugin.zsh
```

## Notes

- OSC 11 only changes the background color. The existing theme's palette
  (foreground, selection, cursor, ANSI colors) remains unchanged.
- Non-Ghostty terminals are safely ignored — the feature is a no-op unless
  `TERM_PROGRAM=ghostty`.
- The saved background is cached in memory for the lifetime of the shell
  session. Opening a new shell will query Ghostty again.
