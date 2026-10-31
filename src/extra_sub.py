#!/usr/bin/env python3
"""Validate and render untrusted Clash/Mihomo subscription proxies."""

import ipaddress
import math
import re
import socket
import sys
import urllib.parse
from collections import Counter
from pathlib import Path

import yaml

MAX_PROXIES = 500
MAX_FILTER_LENGTH = 200
DISALLOWED_PROXY_KEYS = {"plugin", "plugin-opts", "dialer-proxy"}
DANGEROUS_REGEX_PATTERNS = [
    re.compile(r"(\+|\*|\{[0-9,]+\})\s*(\+|\*|\{[0-9,]+\})"),
    re.compile(r"\([^)]*(\+|\*|\{[0-9,]+\})[^)]*\)\s*(\+|\*|\{[0-9,]+\})"),
]
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


def is_forbidden_ip(ip_str):
    try:
        ip = ipaddress.ip_address(ip_str)
        return (
            ip.is_loopback
            or ip.is_private
            or ip.is_link_local
            or ip.is_reserved
            or ip.is_unspecified
            or ip.is_multicast
        )
    except ValueError:
        return False


def check_url(url):
    try:
        parsed = urllib.parse.urlsplit(url)
    except Exception as exc:
        fail(f"malformed URL: {exc}")
    if parsed.scheme.lower() not in ("http", "https"):
        fail("only HTTP and HTTPS URLs are supported")
    host = parsed.hostname
    if not host:
        fail("subscription URL missing host")
    host_lower = host.lower()
    if host_lower in ("localhost", "0.0.0.0", "::") or host_lower.endswith(
        (".localhost", ".local", ".internal")
    ):
        fail("subscription URL cannot point to localhost or local network")
    if is_forbidden_ip(host_lower):
        fail("subscription URL cannot point to private, loopback, or cloud metadata IP addresses")
    try:
        infos = socket.getaddrinfo(host, None)
        for info in infos:
            ip_str = info[4][0]
            if is_forbidden_ip(ip_str):
                fail(f"subscription URL resolves to forbidden address: {ip_str}")
    except (socket.gaierror, OSError):
        pass


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


def compile_filter(pattern):
    """Compile the user-supplied node filter; an empty pattern keeps every node."""
    if not pattern:
        return None
    if len(pattern) > MAX_FILTER_LENGTH:
        fail(f"the filter is longer than {MAX_FILTER_LENGTH} characters")
    if any(ord(char) < 32 or ord(char) == 127 for char in pattern):
        fail("the filter contains control characters")
    if any(p.search(pattern) for p in DANGEROUS_REGEX_PATTERNS):
        fail("the filter contains potential catastrophic backtracking regular expression")
    try:
        return re.compile(pattern)
    except re.error as exc:
        fail(f"invalid filter regular expression: {exc}")


def normalize(source, pattern=""):
    proxies = load_document(source)
    matcher = compile_filter(pattern)
    normalized = []
    names = set()
    for index, proxy in enumerate(proxies):
        if not isinstance(proxy, dict):
            fail(f"proxy {index + 1} is not a mapping")
        name = proxy.get("name")
        if not isinstance(name, str) or not name.strip() or len(name) > 128:
            fail(f"proxy {index + 1} has an invalid name")
        if any(ord(char) < 32 or ord(char) == 127 for char in name):
            fail(f"proxy {index + 1} has control characters in its name")
        name = name.strip()
        if matcher is not None and not matcher.search(name):
            continue
        validate_value(proxy, f"proxy {index + 1}")
        for key in proxy:
            if key.lower() in DISALLOWED_PROXY_KEYS:
                fail(f"proxy {name!r} contains disallowed option: {key}")
        proxy_type = proxy.get("type")
        server = proxy.get("server")
        port = proxy.get("port")
        if not isinstance(proxy_type, str) or proxy_type.lower() not in ALLOWED_TYPES:
            fail(f"proxy {name!r} has an unsupported type")
        if not isinstance(server, str) or not server.strip():
            fail(f"proxy {name!r} has an invalid server")
        if isinstance(port, bool) or not isinstance(port, int) or not 1 <= port <= 65535:
            fail(f"proxy {name!r} has an invalid port")
        if name in names or name in RESERVED_NAMES:
            fail(f"duplicate or reserved proxy name: {name}")
        names.add(name)
        item = dict(proxy)
        item["name"] = name
        item["type"] = proxy_type.lower()
        normalized.append(item)
    if matcher is not None and not normalized:
        fail("the filter matched no proxies")
    return normalized


def write_normalized(source, pattern, proxies_output, names_output):
    proxies = normalize(source, pattern)
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


def load_names(path):
    try:
        with Path(path).open("r", encoding="utf-8") as handle:
            names = yaml.safe_load(handle) or []
    except (OSError, UnicodeError, yaml.YAMLError) as exc:
        fail(f"cannot read normalized proxy names: {exc}")
    if not isinstance(names, list) or any(not isinstance(name, str) for name in names):
        fail("normalized proxy names are invalid")
    return names


def check_names(path, local_name):
    names = load_names(path)
    duplicates = [name for name, count in Counter(names).items() if count > 1]
    if duplicates:
        fail(f"duplicate proxy names across subscriptions: {duplicates[0]!r}")
    if local_name in names:
        fail(f"the local node name conflicts with an external proxy: {local_name}")
    if any(name in RESERVED_NAMES for name in names):
        fail("external subscriptions contain a reserved proxy name")


def main():
    try:
        if len(sys.argv) == 6 and sys.argv[1] == "normalize":
            write_normalized(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5])
        elif len(sys.argv) == 4 and sys.argv[1] == "check-names":
            check_names(sys.argv[2], sys.argv[3])
        elif len(sys.argv) == 3 and sys.argv[1] == "check-filter":
            compile_filter(sys.argv[2])
        elif len(sys.argv) == 3 and sys.argv[1] == "check-url":
            check_url(sys.argv[2])
        else:
            fail(
                "usage: extra_sub.py normalize <input> <filter> <proxies> <names>"
                " | check-names <names> <local> | check-filter <regex> | check-url <url>"
            )
    except SubscriptionError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
