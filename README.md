# vps-manager

A lightweight Bash script for running a multi-user **VLESS + Reality + Vision** node on a VPS, powered by [Xray](https://github.com/XTLS/Xray-core) and [Caddy](https://github.com/caddyserver/caddy).

## Installation

Requirements: a Linux VPS with systemd, root access, and a domain resolving to the server.

```bash
git clone https://github.com/FINTERIGION/vps-manager.git && cd vps-manager
bash install.sh
```

Or install online:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/FINTERIGION/vps-manager/main/install.sh)
```

Then run `vpsm` for the interactive menu, or `vpsm help` for all commands.

## Disclaimer

This project is intended for learning and research purposes only. Users are solely responsible for complying with the laws and regulations of their country or region, as well as the terms of service of their VPS provider. The authors accept no liability for any misuse or for any consequences arising from the use of this software.
