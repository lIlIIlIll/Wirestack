from __future__ import annotations

import copy
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from tools import m3_031_desktop_tls_adoption as adoption


ROOT = Path(__file__).resolve().parents[2]


def provider_result(platform: str, revision: str) -> dict:
    spec = json.loads((ROOT / "tools/tls_provider_poc/providers.json").read_text())
    return {
        "schema_version": 2,
        "task_id": "M0-016",
        "provider": "aws-lc",
        "platform": platform,
        "status": "PASS",
        "execution": {
            "repository_revision": revision,
            "runner_os": "Windows" if platform == "windows-x86_64" else "macOS",
            "runner_arch": "X64" if platform == "windows-x86_64" else "ARM64",
            "image_os": "test-image",
            "image_version": "1",
        },
        "source": {
            "commit": adoption.PINNED_COMMIT,
            "tree": "a" * 40,
            "content_sha256": "b" * 64,
            "kind": "git",
        },
        "capabilities": {name: "PASS" for name in spec["required_capabilities"]},
        "build": {
            "static_archives": [{"name": "provider", "sha256": "c" * 64}],
            "system_tls_dependencies": [],
            "runtime_loader_library_strings": [],
        },
        "metrics": {"repeated_cleanup_cycles": 10000, "external_signer_calls": 2},
    }


class M3031DesktopTlsAdoptionTests(unittest.TestCase):
    revision = "d" * 40

    def assert_code(self, code: str, callback) -> None:
        with self.assertRaises(adoption.AdoptionError) as caught:
            callback()
        self.assertEqual(code, caught.exception.code)

    def test_repository_core_and_task_graph_audit_passes(self) -> None:
        result = adoption.audit_core(ROOT)
        self.assertEqual("PASS", result["status"])
        self.assertEqual(set(adoption.CORE_REQUIREMENTS), set(result["prerequisites"]))
        self.assertFalse(result["historical_task_status_changed"])
        self.assertTrue(all(item["disposition"] == "NOT_EVALUATED" for item in result["excluded_global_conditions"]))
        self.assertEqual("PASS", result["task_graph"]["status"])

    def test_missing_core_declaration_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            relative, _ = adoption.CORE_REQUIREMENTS["M3-001"][0]
            path = root / relative
            path.parent.mkdir(parents=True)
            path.write_text("missing", encoding="utf-8")
            self.assert_code("CORE_REQUIREMENT", lambda: adoption.audit_core(root))

    def test_exact_native_desktop_results_pass(self) -> None:
        for platform in ("windows-x86_64", "macos-arm64"):
            result = adoption.validate_provider_result(
                provider_result(platform, self.revision),
                expected_platform=platform,
                expected_revision=self.revision,
            )
            self.assertEqual("PASS", result["status"])
            self.assertEqual(2, result["external_signer_calls"])

    def test_stale_revision_is_rejected(self) -> None:
        raw = provider_result("windows-x86_64", "e" * 40)
        self.assert_code(
            "STALE_REVISION",
            lambda: adoption.validate_provider_result(
                raw,
                expected_platform="windows-x86_64",
                expected_revision=self.revision,
            ),
        )

    def test_partial_skipped_and_unknown_schema_never_pass(self) -> None:
        for mutation, expected in (
            (lambda value: value.update({"status": "PARTIAL"}), "INCOMPLETE_RESULT"),
            (lambda value: value.update({"status": "SKIPPED"}), "RAW_RESULT"),
            (lambda value: value.update({"schema_version": 99}), "RAW_RESULT"),
        ):
            raw = provider_result("macos-arm64", self.revision)
            mutation(raw)
            self.assert_code(
                expected,
                lambda raw=raw: adoption.validate_provider_result(
                    raw,
                    expected_platform="macos-arm64",
                    expected_revision=self.revision,
                ),
            )

    def test_wrong_platform_and_provider_are_rejected(self) -> None:
        raw = provider_result("macos-arm64", self.revision)
        self.assert_code(
            "PLATFORM",
            lambda: adoption.validate_provider_result(
                raw,
                expected_platform="windows-x86_64",
                expected_revision=self.revision,
            ),
        )
        raw = provider_result("windows-x86_64", self.revision)
        raw["provider"] = "openssl"
        self.assert_code(
            "PROVIDER",
            lambda: adoption.validate_provider_result(
                raw,
                expected_platform="windows-x86_64",
                expected_revision=self.revision,
            ),
        )

    def test_atomic_report_replacement_preserves_old_file_on_failure(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "report.json"
            output.write_text('{"old":true}\n', encoding="utf-8")
            with mock.patch.object(adoption.os, "replace", side_effect=OSError("injected")):
                with self.assertRaises(OSError):
                    adoption.atomic_json(output, {"new": True})
            self.assertEqual({"old": True}, json.loads(output.read_text()))
            self.assertEqual([], list(output.parent.glob(f".{output.name}.*.tmp")))


if __name__ == "__main__":
    unittest.main()
