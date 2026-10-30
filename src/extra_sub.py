#!/usr/bin/env python3
"""Validate and render untrusted Clash/Mihomo subscription proxies."""

import math
import sys
from pathlib import Path

import yaml

MAX_PROXIES = 500
ALLOWED_TYPES = {
    "anytls",
    "http",
    "hysteria",
    "hysteria2",
    "hy2",
    "mieru",
    "snell",
    "socks5",
    "ss",
    "ssr",
    "trojan",
    "tuic",
    "vless",
    "vmess",
    "wireguard",
}
RESERVED_NAMES = {
    "AI",
    "COMPATIBLE",
    "DIRECT",
    "Final",
    "GLOBAL",
    "Google",
    "PASS",
    "Proxy",
    "Proxy-DNS",
    "REJECT",
    "REJECT-DROP",
    "Steam",
}


class SubscriptionError(ValueError):
    """An invalid external subscription."""


def fail(message):
    raise SubscriptionError(message)


def validate_value(value, path="proxy"):
    if value is None or isinstance(value, (str, bool, int)):
        return
    if isinstance(value, float):
        if not math.isfinite(value):
            fail(f"{path} contains a non-finite number")
        return
    if isinstance(value, list):
        for index, item in enumerate(value):
            validate_value(item, f"{path}[{index}]")
        return
    if isinstance(value, dict):
        for key, item in value.items():
            if not isinstance(key, str):
                fail(f"{path} contains a non-string key")
            validate_value(item, f"{path}.{key}")
        return
    fail(f"{path} contains unsupported YAML data")


def load_document(path):
    try:
        with Path(path).open("r", encoding="utf-8") as handle:
            document = yaml.safe_load(handle)
    except (OSError, UnicodeError, yaml.YAMLError) as exc:
        fail(f"cannot parse Clash/Mihomo YAML: {exc}")
    if not isinstance(document, dict) or not isinstance(document.get("proxies"), list):
        fail("the YAML document must contain a proxies list")
    if not document["proxies"]:
        fail("the proxies list is empty")
    if len(document["proxies"]) > MAX_PROXIES:
        fail(f"the subscription exceeds {MAX_PROXIES} proxies")
    return document["proxies"]


def normalize(source, alias):
    proxies = load_document(source)
    normalized = []
    names = set()
    for index, proxy in enumerate(proxies):
        if not isinstance(proxy, dict):
            fail(f"proxy {index + 1} is not a mapping")
        validate_value(proxy, f"proxy {index + 1}")
        name = proxy.get("name")
        proxy_type = proxy.get("type")
        server = proxy.get("server")
        port = proxy.get("port")
        if not isinstance(name, str) or not name.strip() or len(name) > 128:
            fail(f"proxy {index + 1} has an invalid name")
        if any(ord(char) < 32 or ord(char) == 127 for char in name):
            fail(f"proxy {index + 1} has control characters in its name")
        if not isinstance(proxy_type, str) or proxy_type.lower() not in ALLOWED_TYPES:
            fail(f"proxy {name!r} has an unsupported type")
        if not isinstance(server, str) or not server.strip():
            fail(f"proxy {name!r} has an invalid server")
        if isinstance(port, bool) or not isinstance(port, int) or not 1 <= port <= 65535:
            fail(f"proxy {name!r} has an invalid port")
        display_name = f"{alias}: {name.strip()}"
        if display_name in names or display_name in RESERVED_NAMES:
            fail(f"duplicate or reserved proxy name: {display_name}")
        names.add(display_name)
        item = dict(proxy)
        item["name"] = display_name
        item["type"] = proxy_type.lower()
        normalized.append(item)
    return normalized


def write_normalized(source, alias, proxies_output, names_output):
    proxies = normalize(source, alias)
    proxy_text = yaml.safe_dump(
        proxies,
        allow_unicode=True,
        default_flow_style=False,
        sort_keys=False,
        width=4096,
    )
    proxy_text = "\n".join("  " + line if line else line for line in proxy_text.splitlines()) + "\n"
    name_lines = []
    for proxy in proxies:
        scalar = yaml.safe_dump(
            proxy["name"],
            allow_unicode=True,
            default_flow_style=True,
            width=4096,
        ).strip()
        if scalar.endswith("\n..."):
            scalar = scalar[:-4].rstrip()
        name_lines.append(f"      - {scalar}")
    Path(proxies_output).write_text(proxy_text, encoding="utf-8")
    Path(names_output).write_text("\n".join(name_lines) + "\n", encoding="utf-8")


def check_names(path, local_name):
    try:
        with Path(path).open("r", encoding="utf-8") as handle:
            names = yaml.safe_load(handle) or []
    except (OSError, UnicodeError, yaml.YAMLError) as exc:
        fail(f"cannot read normalized proxy names: {exc}")
    if not isinstance(names, list) or any(not isinstance(name, str) for name in names):
        fail("normalized proxy names are invalid")
    if len(names) != len(set(names)):
        fail("external subscriptions contain duplicate proxy names")
    if local_name in names:
        fail(f"the local node name conflicts with an external proxy: {local_name}")
    if any(name in RESERVED_NAMES for name in names):
        fail("external subscriptions contain a reserved proxy name")


def main():
    try:
        if len(sys.argv) == 6 and sys.argv[1] == "normalize":
            write_normalized(*sys.argv[2:6])
        elif len(sys.argv) == 4 and sys.argv[1] == "check-names":
            check_names(sys.argv[2], sys.argv[3])
        else:
            fail("usage: extra_sub.py normalize <input> <alias> <proxies> <names> | check-names <names> <local>")
    except SubscriptionError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
