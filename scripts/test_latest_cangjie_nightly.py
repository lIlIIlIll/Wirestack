#!/usr/bin/env python3
"""Regression tests for the hosted-CI nightly resolver."""

from __future__ import annotations

import contextlib
import importlib.util
import io
import pathlib
import unittest
from unittest import mock


SCRIPT = pathlib.Path(__file__).with_name("latest_cangjie_nightly.py")
WORKFLOW = SCRIPT.parents[1] / ".github" / "workflows" / "ci.yml"
SPEC = importlib.util.spec_from_file_location("latest_cangjie_nightly", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
NIGHTLY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(NIGHTLY)

VERSION = "1.3.0-alpha.20260831010012"


def complete_release() -> dict[str, object]:
    return {
        "name": f"Nightly Build {VERSION}",
        "tag_name": VERSION,
        "assets": [
            {"name": template.format(version=VERSION)}
            for template in NIGHTLY.REQUIRED_ASSET_TEMPLATES
        ],
    }


class NightlyResolverTests(unittest.TestCase):
    def test_complete_cross_platform_release_resolves(self) -> None:
        self.assertEqual(NIGHTLY.resolve_release(complete_release()), VERSION)

    def test_every_required_host_asset_is_blocking(self) -> None:
        release = complete_release()
        assets = release["assets"]
        assert isinstance(assets, list)
        for missing_index, template in enumerate(NIGHTLY.REQUIRED_ASSET_TEMPLATES):
            with self.subTest(asset=template):
                candidate = dict(release)
                candidate["assets"] = [
                    asset for index, asset in enumerate(assets) if index != missing_index
                ]
                with self.assertRaisesRegex(ValueError, "incomplete"):
                    NIGHTLY.resolve_release(candidate)

    def test_release_name_and_tag_must_match(self) -> None:
        for key, value in (
            ("name", f"Nightly Build {VERSION}x"),
            ("tag_name", "1.3.0-alpha.20260831010013"),
        ):
            with self.subTest(key=key):
                release = complete_release()
                release[key] = value
                with self.assertRaisesRegex(ValueError, "name and tag"):
                    NIGHTLY.resolve_release(release)

    def test_malformed_payload_fails_closed(self) -> None:
        for release in (None, [], {}, {"name": f"Nightly Build {VERSION}", "tag_name": VERSION}):
            with self.subTest(release=release):
                with self.assertRaises(ValueError):
                    NIGHTLY.resolve_release(release)

    def test_exact_version_validation(self) -> None:
        self.assertEqual(NIGHTLY.validate_version(VERSION), VERSION)
        for invalid in (
            "",
            "nightly",
            "1.3.0-alpha.20260831",
            "1.3.0-alpha.20260831010012 ",
            "1.3.0-beta.20260831010012",
        ):
            with self.subTest(version=invalid):
                with self.assertRaises(ValueError):
                    NIGHTLY.validate_version(invalid)

    def test_validate_version_cli_is_network_free(self) -> None:
        stdout = io.StringIO()
        with mock.patch.object(NIGHTLY.urllib.request, "urlopen") as urlopen:
            with contextlib.redirect_stdout(stdout):
                status = NIGHTLY.main(["--validate-version", VERSION])
        self.assertEqual(status, 0)
        self.assertEqual(stdout.getvalue(), VERSION + "\n")
        urlopen.assert_not_called()


class HostedWorkflowWiringTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.workflow = WORKFLOW.read_text(encoding="utf-8")

    def test_required_context_and_seven_day_cache_are_preserved(self) -> None:
        self.assertIn("name: Cangjie nightly (7-day window)", self.workflow)
        self.assertIn("/ 604800", self.workflow)
        self.assertIn(
            "key: cangjie-nightly-complete-v2-${{ steps.window.outputs.value }}",
            self.workflow,
        )
        self.assertNotIn("CANGJIE_VERSION:", self.workflow)

    def test_all_cangjie_jobs_consume_the_shared_resolution(self) -> None:
        setup_count = self.workflow.count("uses: Zxilly/setup-cangjie@")
        self.assertGreater(setup_count, 0)
        self.assertEqual(
            self.workflow.count("version: ${{ needs.nightly.outputs.version }}"),
            setup_count,
        )
        self.assertEqual(self.workflow.count("needs: nightly"), setup_count)
        self.assertEqual(self.workflow.count("archive-path:"), setup_count)
        self.assertEqual(
            self.workflow.count(
                "resolved_cangjie_version=${{ needs.nightly.outputs.version }}"
            ),
            setup_count,
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
