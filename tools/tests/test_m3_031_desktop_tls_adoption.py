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
        "schema_version": 3,
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
        "metrics": {"repeated_cleanup_cycles": 10000, "external_signer_calls": 2,
                    "session_resumption_handshakes": 2},
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
        self.assertIn("docs/planning/implementation-backlog.md", result["source_sha256"])
        self.assertEqual("PASS", result["task_graph"]["status"])
        self.assertEqual("PASS", result["retained_evidence_validation"]["status"])
        self.assertEqual("PASS", result["dependency_evidence_validation"]["status"])

    def test_dependency_evidence_rejects_source_and_native_report_drift(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source.txt"
            source.write_text("source", encoding="utf-8")
            report_relative = "docs/evidence/M2-004/windows-x86_64/report.json"
            validation_relative = "docs/evidence/M2-004/windows-x86_64/validation.json"
            report = root / report_relative
            validation = root / validation_relative
            report.parent.mkdir(parents=True)
            report.write_bytes((json.dumps({
                "schema_version": 1, "task_id": "M2-004", "revision": "a" * 40,
                "decision": "PASS",
            }, indent=2) + "\n").replace("\n", "\r\n").encode("utf-8"))
            validation.write_bytes((json.dumps({
                "schema_version": 1, "task_id": "M2-004",
                "expected_revision": "a" * 40, "failures": [], "status": "PASS",
                "report_sha256": adoption.sha256_path(report),
            }, indent=2) + "\n").replace("\n", "\r\n").encode("utf-8"))
            evidence_path = root / "docs/evidence/M2-004/evidence.json"
            evidence_path.parent.mkdir(parents=True, exist_ok=True)
            evidence_path.write_text(json.dumps({
                "schema_version": 1, "source_task": "M2-004",
                "platform": {}, "toolchain": {}, "acceptance_status": "PASS",
                "generated_at_utc": "2026-08-31T00:00:00Z", "revision": "a" * 40,
                "reports": [{
                    "path": validation_relative,
                    "sha256": adoption.repository_text_sha256(validation),
                    "source_task": "M2-004", "acceptance_status": "PASS",
                }],
                "source_sha256": {"source.txt": adoption.sha256_path(source)},
            }), encoding="utf-8")
            task = {
                "task_id": "M2-004", "source_paths": ["source.txt"],
                "required_evidence": [
                    "docs/evidence/M2-004/evidence.json", validation_relative,
                ],
            }
            bindings = {"M2-004": ((validation_relative, report_relative, None),)}
            with mock.patch.object(
                adoption.repository_tooling, "load_task", return_value=task
            ):
                self.assertEqual(
                    "PASS", adoption.validate_dependency_evidence(root, bindings)["status"]
                )
                source.write_text("drift", encoding="utf-8")
                self.assert_code(
                    "STALE_SOURCE",
                    lambda: adoption.validate_dependency_evidence(root, bindings),
                )
                structural = adoption.validate_dependency_evidence(
                    root, bindings, verify_current_sources=False
                )
                self.assertEqual("PASS", structural["status"])
                self.assertEqual(
                    "SEALED_INVENTORY",
                    structural["tasks"]["M2-004"]["source_verification"],
                )
                source.write_text("source", encoding="utf-8")
                report.write_text(json.dumps({
                    "schema_version": 1, "task_id": "M2-004",
                    "revision": "a" * 40, "decision": "FAIL",
                }), encoding="utf-8")
                self.assert_code(
                    "DEPENDENCY_EVIDENCE",
                    lambda: adoption.validate_dependency_evidence(
                        root, bindings, verify_current_sources=False
                    ),
                )

    def test_retained_report_and_tls_source_drift_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            evidence_path = root / "docs/evidence/M3-030/evidence.json"
            evidence_path.parent.mkdir(parents=True)
            report_paths = adoption.RETAINED_EVIDENCE
            reports = []
            for relative in report_paths:
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(json.dumps({
                    "source_task": "M3-030", "status": "PASS"
                }), encoding="utf-8")
                reports.append({"path": relative, "source_task": "M3-030",
                                "acceptance_status": "PASS",
                                "sha256": adoption.sha256_path(path)})
            source = root / "src/internal/tls_engine/package.cj"
            source.parent.mkdir(parents=True)
            source.write_text("current", encoding="utf-8")
            evidence = {"schema_version": 1, "source_task": "M3-030",
                        "acceptance_status": "PASS", "reports": reports,
                        "source_sha256": {
                            "src/internal/tls_engine/package.cj": adoption.sha256_path(source)
                        }}
            evidence_path.write_text(json.dumps(evidence), encoding="utf-8")
            self.assertEqual("PASS", adoption.validate_retained_evidence(root)["status"])
            source.write_text("drift", encoding="utf-8")
            self.assert_code("STALE_SOURCE", lambda: adoption.validate_retained_evidence(root))

    def test_hosted_run_is_bound_to_current_provider_inputs(self) -> None:
        revision = "a" * 40
        raw = {
            "schema_version": 2, "task_id": "M3-031", "status": "PASS",
            "conclusion": "success", "revision": revision,
            "source_sha256": adoption.hosted_input_sha256(ROOT),
            "artifacts": [
                {"name": f"m3-031-windows-x86_64-{revision}"},
                {"name": f"m3-031-macos-arm64-{revision}"},
            ],
        }
        self.assertEqual("PASS", adoption.validate_hosted_run(ROOT, raw)["status"])
        raw["source_sha256"][adoption.HOSTED_INPUT_PATHS[0]] = "0" * 64
        self.assert_code("STALE_SOURCE", lambda: adoption.validate_hosted_run(ROOT, raw))

    def test_repository_text_digest_is_checkout_line_ending_stable(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "report.json"
            path.write_bytes(b'{\r\n  "status": "PASS"\r\n}\r\n')
            windows_digest = adoption.repository_text_sha256(path)
            path.write_bytes(b'{\n  "status": "PASS"\n}\n')
            self.assertEqual(windows_digest, adoption.repository_text_sha256(path))

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
