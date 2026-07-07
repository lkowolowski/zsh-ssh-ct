# Cache Management

The plugin maintains a host/profile cache that stores successful SSH connections.
Entries are persisted to disk and survive shell restarts.

## Commands

| Command | Description |
| ------- | ----------- |
| `_ssh_cache_show` | Pretty-print the cache table with last-seen timestamps |
| `_ssh_cache_clear` | Wipe the entire cache |
| `_ssh_cache_prune` | Remove entries older than `_SSH_CACHE_TTL_DAYS` |
| `_ssh_cache_delete <host>` | Remove all entries for a specific host |
| `_ssh_cache_delete <host> <profile>` | Remove a specific host:profile pair |

### Show

```text
$ _ssh_cache_show
HOST                             PROFILE   PROFILE NAME         LAST SEEN
──────────────────────────────   ────────  ────────────────────  ─────────────────
core-rtr-01                      -j        Juniper              2h ago
core-switch                      -c        Cisco                5d ago
fw-01                            -p        PAN-OS/Palo Alto     1m ago
web-01                           -u        Unix/Linux           30s ago

4 entries total  |  TTL: 30 days
```

### Delete

```zsh
_ssh_cache_delete core-rtr-01          # remove all entries for host
_ssh_cache_delete core-rtr-01 j        # remove only Juniper entry
```

## Auto-prune

The cache is pruned automatically in the background at most **once per day**.
A `.pruned` stamp file tracks the last prune time.

The auto-prune runs silently — no output is printed during normal shell use.
Manual `_ssh_cache_prune` reports the number of entries removed.

## TTL configuration

Set `_SSH_CACHE_TTL_DAYS` in `.zshrc`:

| Value | Behavior |
| ----- | -------- |
| `30` (default) | Entries expire after 30 days |
| `0` | Entries never expire (manual prune only) |
| `7` | Entries expire after 7 days |

## Secure permissions

The cache directory is created with `700` permissions and the cache file with
`600`, ensuring other users on the system cannot read connection history.

## Race conditions

The auto-prune writes a temporary file and replaces the cache atomically via
`mv -f`. On a slow filesystem, a rapid `_ssh` invocation immediately after
shell startup could theoretically overlap with the prune. If you ever see an
empty or truncated cache, run `_ssh_cache_clear` to reset it.
