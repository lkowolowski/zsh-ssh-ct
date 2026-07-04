# ct highlight configs

This plugin bundles the [ct-highlight](https://github.com/lkowolowski/ct-highlight)
ChromaTerm highlight rules in the `profiles/` directory.

## Setup

Copy the bundled profiles to your ChromaTerm config directory:

```zsh
cp -r profiles/* "${XDG_CONFIG_HOME:-${HOME}/.config}/chromaterm/"

# In your .zshrc (before loading the plugin):
export _SSH_CT_CONFIG_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/chromaterm"
```

## Profile files

The plugin expects these files in `_SSH_CT_CONFIG_DIR`:

| File            | Profile flag | Device type                           |
|-----------------|--------------|---------------------------------------|
| `generic.yml`   | —            | Catch-all fallback                    |
| `juniper.yml`   | `-j`         | Juniper JunOS (SRX, EX, QFX, MX)      |
| `cisco.yml`     | `-c`         | Cisco IOS / IOS-XE / NX-OS            |
| `panos.yml`     | `-p`         | Palo Alto PAN-OS                      |
| `unix.yml`      | `-u`         | Linux / Unix / macOS / FreeBSD        |

## Profile details

- **generic.yml** — universal patterns: IPv4/IPv6/MAC addresses, URLs, timestamps
- **juniper.yml** — JunOS: config keywords, show interfaces, show route, show bgp, LLDP, STP, chassis alarms, syslog, ARP
- **cisco.yml** — IOS/IOS-XE/NX-OS: switchport, VLANs, CDP/LLDP, STP, BGP, OSPF, interface errors, ACLs, VRF
- **panos.yml** — PAN-OS: config mode, security rules, NAT, HA states, sessions, routing, system info, log severity
- **unix.yml** — Linux/BSD/macOS: ip addr, ip route, ip neigh, ifconfig (cross-platform), ARP, interface names (predictable, legacy, virtual, Docker, etc.)

## Customizing

Edit any profile YAML to adjust colors or add regex rules:

```yaml
palette:
  red: "#e06c75"

rules:
  - description: My custom rule
    regex: '\bmy-pattern\b'
    color: f.red bold
```

Restart any running `ct` processes after modifying profiles.

## Additional resources

- [ChromaTerm highlight rules](https://github.com/hSaria/ChromaTerm#highlight-rules)
- [regex101](https://regex101.com) for testing expressions
