#!/usr/bin/env python3
"""Dependency-light tests for external Clash/Mihomo subscription parsing."""

import sys
import tempfile
import unittest
from pathlib import Path

import yaml

PROJECT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROJECT))

from src.extra_sub import (  # noqa: E402
    SubscriptionError,
    check_names,
    check_url,
    compile_filter,
    normalize,
    write_normalized,
)


class ExternalSubscriptionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix=".test-parser-", dir=PROJECT)
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def fixture(self, name):
        return PROJECT / "tests" / "fixtures" / name

    def test_valid_proxies_are_normalized(self):
        proxies = normalize(self.fixture("valid.yaml"))
        self.assertEqual(2, len(proxies))
        self.assertEqual("Tokyo", proxies[0]["name"])
        self.assertEqual('Quote: "Node"', proxies[1]["name"])
        self.assertEqual(8388, proxies[0]["port"])

    def test_rendered_files_are_valid_yaml(self):
        proxies_out = self.root / "proxies.yaml"
        names_out = self.root / "names.yaml"
        write_normalized(self.fixture("valid.yaml"), "", proxies_out, names_out)
        proxies = yaml.safe_load(proxies_out.read_text(encoding="utf-8"))
        names = yaml.safe_load(names_out.read_text(encoding="utf-8"))
        self.assertEqual(2, len(proxies))
        self.assertEqual(["Tokyo", 'Quote: "Node"'], names)
        check_names(names_out, "local-node")

    def test_filter_keeps_matching_proxies_only(self):
        proxies = normalize(self.fixture("mixed.yaml"), "^Osaka$")
        self.assertEqual(["Osaka"], [proxy["name"] for proxy in proxies])

    def test_filter_matches_partial_names(self):
        proxies = normalize(self.fixture("valid.yaml"), "(?i)quote")
        self.assertEqual(['Quote: "Node"'], [proxy["name"] for proxy in proxies])

    def test_filter_without_match_is_rejected(self):
        with self.assertRaises(SubscriptionError):
            normalize(self.fixture("mixed.yaml"), "^Nope$")

    def test_invalid_filter_is_rejected(self):
        with self.assertRaises(SubscriptionError):
            normalize(self.fixture("valid.yaml"), "(")
        with self.assertRaises(SubscriptionError):
            compile_filter("(")

    def test_empty_filter_keeps_every_proxy(self):
        self.assertIsNone(compile_filter(""))
        self.assertEqual(2, len(normalize(self.fixture("valid.yaml"), "")))

    def test_malformed_yaml_is_rejected(self):
        with self.assertRaises(SubscriptionError):
            normalize(self.fixture("invalid.yaml"))

    def test_duplicate_names_are_rejected(self):
        with self.assertRaises(SubscriptionError):
            normalize(self.fixture("duplicate.yaml"))

    def test_local_name_conflict_is_rejected(self):
        names = self.root / "names.yaml"
        names.write_text("      - local-node\n", encoding="utf-8")
        with self.assertRaises(SubscriptionError):
            check_names(names, "local-node")

    def test_duplicate_names_across_subscriptions_are_rejected(self):
        names = self.root / "names.yaml"
        names.write_text("      - Osaka\n      - Osaka\n", encoding="utf-8")
        with self.assertRaises(SubscriptionError):
            check_names(names, "local-node")

    def test_catastrophic_backtracking_filter_is_rejected(self):
        with self.assertRaises(SubscriptionError):
            compile_filter("^(a+)+$")
        with self.assertRaises(SubscriptionError):
            compile_filter("^(a|aa)+$")

    def test_forbidden_urls_are_rejected(self):
        for bad_url in (
            "http://127.0.0.1:10085/sub",
            "http://169.254.169.254/latest/meta-data/",
            "http://100.100.100.200/latest/meta-data/",
            "http://100.64.0.1/sub",
            "http://[::ffff:127.0.0.1]:10085/sub",
            "http://192.0.0.192/sub",
            "http://localhost:8080/sub",
        ):
            with self.subTest(url=bad_url):
                with self.assertRaises(SubscriptionError):
                    check_url(bad_url)

    def test_yaml_anchors_and_aliases_are_rejected(self):
        alias_yaml = self.root / "alias.yaml"
        alias_yaml.write_text(
            "proxies:\n"
            "  - &base\n"
            "    name: Node1\n"
            "    type: ss\n"
            "    server: 1.2.3.4\n"
            "    port: 8388\n"
            "  - <<: *base\n"
            "    name: Node2\n",
            encoding="utf-8",
        )
        with self.assertRaises(SubscriptionError):
            normalize(alias_yaml)

    def test_excessive_nesting_depth_is_rejected(self):
        deep_yaml = self.root / "deep.yaml"
        nested = "a"
        for _ in range(25):
            nested = [nested]
        doc = {
            "proxies": [
                {
                    "name": "Deep",
                    "type": "ss",
                    "server": "1.2.3.4",
                    "port": 8388,
                    "ws-opts": nested,
                }
            ]
        }
        deep_yaml.write_text(yaml.safe_dump(doc), encoding="utf-8")
        with self.assertRaises(SubscriptionError):
            normalize(deep_yaml)

    def test_proxy_with_disallowed_plugin_is_rejected(self):
        bad_yaml = self.root / "plugin.yaml"
        bad_yaml.write_text(
            "proxies:\n"
            "  - name: Evil\n"
            "    type: ss\n"
            "    server: 1.2.3.4\n"
            "    port: 8388\n"
            "    plugin: obfs-local\n",
            encoding="utf-8",
        )
        with self.assertRaises(SubscriptionError):
            normalize(bad_yaml)


if __name__ == "__main__":
    unittest.main()
