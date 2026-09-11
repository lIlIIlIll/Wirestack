#!/usr/bin/env python3
"""Regression tests for the hosted-CI STS resolver."""

from __future__ import annotations

import contextlib
import importlib.util
import io
import pathlib
import unittest


SCRIPT = pathlib.Path(__file__).with_name("validate_cangjie_sts.py")
WORKFLOW = SCRIPT.parents[1] / ".github" / "workflows" / "ci.yml"
SPEC = importlib.util.spec_from_file_location("validate_cangjie_sts", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
STS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(STS)

VERSION = "1.1.3"


class StsResolverTests(unittest.TestCase):
    def test_exact_pinned_version_validation(self) -> None:
        self.assertEqual(STS.pinned_sts_version(), VERSION)
        self.assertEqual(STS.validate_version(VERSION), VERSION)
        for invalid in (
            "",
            "sts",
            "1.1",
            "1.1.3 ",
            "1.1.0",
            "1.1.3-alpha.20260831010012",
            "1.1.3-beta.1",
            "1.1.3.1",
            "1.1.2",
            "1.1.4",
        ):
            with self.subTest(version=invalid):
                with self.assertRaises(ValueError):
                    STS.validate_version(invalid)

    def test_validate_version_cli_is_network_free(self) -> None:
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            status = STS.main(["--validate-version", VERSION])
        self.assertEqual(status, 0)
        self.assertEqual(stdout.getvalue(), VERSION + "\n")


class HostedWorkflowWiringTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.workflow = WORKFLOW.read_text(encoding="utf-8")

    def test_sts_channel_and_pinned_version_are_explicit(self) -> None:
        self.assertIn("name: Cangjie STS (pinned)", self.workflow)
        self.assertIn("channel: sts", self.workflow)
        self.assertIn("value=1.1.3", self.workflow)
        self.assertNotIn("latest_cangjie_nightly", self.workflow)
        self.assertNotIn("channel: nightly", self.workflow)

    def test_all_cangjie_jobs_consume_shared_sts_resolution(self) -> None:
        setup_count = self.workflow.count("uses: Zxilly/setup-cangjie@")
        self.assertGreater(setup_count, 0)
        self.assertEqual(
            self.workflow.count("version: ${{ needs.sts.outputs.version }}"),
            setup_count,
        )
        self.assertEqual(self.workflow.count("needs: sts"), setup_count)
        self.assertEqual(self.workflow.count("archive-path:"), setup_count)
        self.assertEqual(
            self.workflow.count(
                "resolved_cangjie_version=${{ needs.sts.outputs.version }}"
            ),
            setup_count,
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
