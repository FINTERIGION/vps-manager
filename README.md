# vps-manager

A lightweight Bash CLI for securing a VPS and running a multi-user **VLESS + Reality + Vision** service with [Xray](https://github.com/XTLS/Xray-core) and [Caddy](https://github.com/caddyserver/caddy).

It provides an interactive menu and direct subcommands for:
- SSH port changes with validation and firewall coordination
- A dedicated iptables inbound whitelist and swap file management
- One-command VLESS + Reality + Vision deployment
- Per-user quotas, usage counters, and subscription links
- Per-user external subscriptions with validated caching
- Xray, Caddy, script, and distribution repository updates

## Installation

Requirements: a systemd-based Linux VPS with root access and a domain whose A record points to the VPS.

```bash
sudo bash <(curl -fsSL https://raw.githubusercontent.com/FINTERIGION/vps-manager/main/install.sh)
```

After installation, run `sudo vpsm` to open the menu.

## Disclaimer

This project is intended for learning and research purposes only. Users are solely responsible for complying with the laws and regulations of their country or region, as well as the terms of service of their VPS provider. The authors accept no liability for any misuse or for any consequences arising from the use of this software.
