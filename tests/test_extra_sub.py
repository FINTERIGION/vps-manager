#!/usr/bin/env python3
"""Dependency-light tests for external Clash/Mihomo subscription parsing."""

import sys
import tempfile
import unittest
from pathlib import Path

import yaml

PROJECT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROJECT))

from src.extra_sub import SubscriptionError, check_names, normalize, write_normalized  # noqa: E402


class ExternalSubscriptionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix=".test-parser-", dir=PROJECT)
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def fixture(self, name):
        return PROJECT / "tests" / "fixtures" / name

    def test_valid_proxies_are_normalized(self):
        proxies = normalize(self.fixture("valid.yaml"), "provider")
        self.assertEqual(2, len(proxies))
        self.assertEqual("provider: Tokyo", proxies[0]["name"])
        self.assertEqual('provider: Quote: "Node"', proxies[1]["name"])
        self.assertEqual(8388, proxies[0]["port"])

    def test_rendered_files_are_valid_yaml(self):
        proxies_out = self.root / "proxies.yaml"
        names_out = self.root / "names.yaml"
        write_normalized(self.fixture("valid.yaml"), "provider", proxies_out, names_out)
        proxies = yaml.safe_load(proxies_out.read_text(encoding="utf-8"))
        names = yaml.safe_load(names_out.read_text(encoding="utf-8"))
        self.assertEqual(2, len(proxies))
        self.assertEqual(["provider: Tokyo", 'provider: Quote: "Node"'], names)
        check_names(names_out, "local-node")

    def test_malformed_yaml_is_rejected(self):
        with self.assertRaises(SubscriptionError):
            normalize(self.fixture("invalid.yaml"), "bad")

    def test_duplicate_names_are_rejected(self):
        with self.assertRaises(SubscriptionError):
            normalize(self.fixture("duplicate.yaml"), "bad")

    def test_local_name_conflict_is_rejected(self):
        names = self.root / "names.yaml"
        names.write_text("      - local-node\n", encoding="utf-8")
        with self.assertRaises(SubscriptionError):
            check_names(names, "local-node")


if __name__ == "__main__":
    unittest.main()
