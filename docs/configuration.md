# Configuration

Set any of these in your `.zshrc` **before** the `source` / `zgenom load` line.

## Core variables

| Variable | Default | Description |
| -------- | ------- | ----------- |
| `_SSH_CT_CONFIG_DIR` | `$XDG_CONFIG_HOME/chromaterm` (~/.config/chromaterm) | Directory with ct YAML highlight configs |
| `_SSH_MAX_RETRIES` | `60` | Maximum ping retry iterations |
| `_SSH_RETRY_SLEEP` | `30` | Seconds between retry attempts |

## Init-commands variables

| Variable | Default | Description |
| -------- | ------- | ----------- |
| `_SSH_REMOTE_CMDS` | `$XDG_CONFIG_HOME/zsh-ssh-ct/init-commands.yml` | Init-commands YAML config path |
| `_SSH_INIT_CMD_SKIP_PROFILES` | `u` | Profiles to skip for init-commands (e.g. `"u"`, `"uc"`) |

See [docs/init-commands.md](init-commands.md) for the config schema.

## Ghostty background variables

| Variable | Default | Description |
| -------- | ------- | ----------- |
| `_SSH_GHOSTTY_BG_ENABLE` | `0` | Set to `1` to enable background switching |
| `_SSH_GHOSTTY_BG_CONFIG` | `$XDG_CONFIG_HOME/zsh-ssh-ct/ghostty-bg.yml` | YAML config path for profile→color mapping |
| `_SSH_GHOSTTY_BG_J` | `#1A3A2A` | Juniper background color (fallback) |
| `_SSH_GHOSTTY_BG_C` | `#1A2A3A` | Cisco background color (fallback) |
| `_SSH_GHOSTTY_BG_P` | `#3A1A1A` | PAN-OS background color (fallback) |
| `_SSH_GHOSTTY_BG_U` | _(empty)_ | Unix background color (empty = no change) |

See [docs/ghostty-bg.md](ghostty-bg.md) for color resolution order and save/restore details.

## Example `.zshrc`

```zsh
# Overrides — must precede the source/load line
export _SSH_CT_CONFIG_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/chromaterm"
export _SSH_MAX_RETRIES=10
export _SSH_RETRY_SLEEP=15

# Ghostty background switching
export _SSH_GHOSTTY_BG_ENABLE=1
export _SSH_GHOSTTY_BG_J="#004422"

# Plugin load (choose one)
source ~/.zsh/zsh-ssh-ct/zsh-ssh-ct.plugin.zsh   # manual
# zgenom load lkowolowski/zsh-ssh-ct         # zgenom
```
