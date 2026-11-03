#!/usr/bin/env python3
"""Probe-facing health checks for the Reality fallback site.

openssl is not a hard dependency of vpsm, so certificate verification is done
with the stdlib ssl module. It validates the chain and the hostname exactly the
way an active prober's TLS stack would, which is what makes the result useful:
a plain TLS handshake against the Xray port is the prober's own code path.

Findings are reported as JSON on stdout with exit code 0, so the shell side can
parse them uniformly and decide the severity itself. Only a usage error exits 1.
"""

import datetime
import json
import socket
import ssl
import sys

CONNECT_TIMEOUT = 8
# Mimic a browser ClientHello: Caddy is configured with "protocols h1 h2", so a
# prober would normally negotiate h2. Advertising it also proves h2 still works.
ALPN_PROTOCOLS = ["h2", "http/1.1"]


class CheckError(Exception):
    """A usage or argument problem, as opposed to a probe finding."""


def fail(message):
    raise CheckError(message)


def _name_field(entries, keys):
    """Flatten a getpeercert() name tuple list, preferring the earlier keys."""
    for key in keys:
        found = [str(value) for rdn in entries or () for attr, value in rdn if attr == key]
        if found:
            return ", ".join(found)
    return ""


def check_cert(host, port, sni):
    """Report what a prober sees when it completes a plain TLS handshake."""
    result = {
        "ok": False,
        "host": host,
        "port": port,
        "sni": sni,
        # True once TCP is up, so the caller can tell "nothing is serving TLS"
        # apart from "a site answered, but its certificate is broken".
        "reachable": False,
        "not_after": "",
        "days_left": None,
        "issuer": "",
        "subject": "",
        "protocol": "",
        "alpn": "",
        "error": "",
    }
    try:
        port_no = int(port)
    except ValueError:
        result["error"] = f"invalid port: {port}"
        return result
    if not 1 <= port_no <= 65535:
        result["error"] = f"port out of range: {port_no}"
        return result

    context = ssl.create_default_context()
    context.set_alpn_protocols(ALPN_PROTOCOLS)
    try:
        with socket.create_connection((host, port_no), timeout=CONNECT_TIMEOUT) as sock:
            result["reachable"] = True
            with context.wrap_socket(sock, server_hostname=sni) as tls:
                cert = tls.getpeercert()
                result["protocol"] = tls.version() or ""
                result["alpn"] = tls.selected_alpn_protocol() or ""
    except ssl.SSLCertVerificationError as exc:
        detail = getattr(exc, "verify_message", "") or str(exc)
        result["error"] = f"certificate verification failed: {detail}"
        return result
    except ssl.SSLError as exc:
        result["error"] = f"TLS handshake failed: {exc}"
        return result
    except (TimeoutError, socket.timeout):
        result["error"] = f"connection to {host}:{port_no} timed out"
        return result
    except OSError as exc:
        result["error"] = f"cannot reach {host}:{port_no}: {exc.strerror or exc}"
        return result

    if not cert:
        result["error"] = "the peer returned no certificate"
        return result

    result["issuer"] = _name_field(cert.get("issuer"), ("organizationName", "commonName"))
    result["subject"] = _name_field(cert.get("subject"), ("commonName", "organizationName"))
    not_after = cert.get("notAfter") or ""
    result["not_after"] = not_after
    if not_after:
        try:
            expiry = ssl.cert_time_to_seconds(not_after)
        except ValueError:
            result["error"] = f"unparsable certificate expiry: {not_after}"
            return result
        now = datetime.datetime.now(datetime.timezone.utc).timestamp()
        result["days_left"] = int((expiry - now) // 86400)
    result["ok"] = True
    return result


def main():
    try:
        if len(sys.argv) == 5 and sys.argv[1] == "cert":
            print(json.dumps(check_cert(sys.argv[2], sys.argv[3], sys.argv[4])))
        else:
            fail("usage: check.py cert <host> <port> <sni>")
    except CheckError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
