from __future__ import annotations

from tools import evidence_digest

import copy
import json
import shutil
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from tools import m3_031_desktop_tls_adoption as adoption


ROOT = Path(__file__).resolve().parents[2]


def tool_identity(name: str) -> dict:
    output = f"{name} 1.0"
    return {
        "argv": [name, "--version"],
        "exit_code": 0,
        "output": output,
        "output_sha256": evidence_digest.text_evidence_bytes_sha256(output.encode()),
    }


def build_provenance(platform: str, *, diagnostic: bool = False) -> dict:
    return {
        "target_triple": {
            "windows-x86_64": "x86_64-pc-windows-msvc",
            "macos-arm64": "arm64-apple-darwin",
        }[platform],
        "compiler": tool_identity("cc"),
        "cxx_compiler": tool_identity("c++"),
        "cmake": tool_identity("cmake"),
        "build_tool": tool_identity("build-tool"),
        "assembler": (
            tool_identity("nasm")
            if platform == "windows-x86_64" and not diagnostic else None
        ),
        "configure_argv": [
            "cmake", "-DBUILD_SHARED_LIBS=OFF", "-DBUILD_TESTING=OFF",
            "-DDISABLE_GO=ON", "<SOURCE>", "<BUILD>", "<PREFIX>",
        ],
        "build_argv": [
            ["build-tool", "<BUILD>"],
            ["build-tool", "<PREFIX>"],
        ],
        "environment": {
            key: ("/usr/bin:/bin" if key == "PATH" else "")
            for key in adoption.poc_validate.BUILD_ENVIRONMENT_KEYS
        },
        "patches": [],
        "patch_set_sha256": evidence_digest.text_evidence_bytes_sha256(b"[]\n"),
        "instrumentation": (
            "address+undefined-sanitizer" if diagnostic else "none"
        ),
        "provider_instrumented": diagnostic,
    }


def provider_result(platform: str, revision: str) -> dict:
    spec = json.loads((ROOT / "tools/tls_provider_poc/providers.json").read_text())
    provider = next(
        item for item in spec["providers"] if item["id"] == "aws-lc"
    )
    metrics = {
        "repeated_cleanup_cycles": 10000,
        "external_signer_calls": 2,
        "external_trust_calls": 4,
        "alpn_no_overlap_handshakes": 2,
        "alpn_malformed_inputs_rejected": 2,
        "certificate_negative_cases_rejected": 2,
        "session_resumption_handshakes": 4,
        "session_resumption_tls12_handshakes": 2,
        "session_resumption_tls13_handshakes": 2,
        "mtls_required_handshakes": 1,
        "mtls_optional_handshakes": 2,
        "local_close_operations": 2,
        "memory_profile_peak_resident_bytes": 64 * 1024 * 1024,
        "memory_profile_bound_bytes": adoption.poc_validate.MEMORY_PROFILE_BOUND_BYTES,
        "provider_allocation_calls": 200,
        "provider_allocation_call_bound": adoption.poc_validate.PROVIDER_ALLOCATION_CALL_BOUND,
        "provider_allocation_bytes": 1024 * 1024,
        "provider_allocation_bound_bytes": adoption.poc_validate.PROVIDER_ALLOCATION_PROFILE_BOUND_BYTES,
        "provider_allocation_peak_live_bytes": 512 * 1024,
        "provider_allocation_live_before_cleanup_bytes": 64 * 1024,
        "provider_allocation_live_after_cleanup_bytes": 64 * 1024,
        "cancellation_wakeups": 1,
        "cancellation_latency_us": 1000,
        "cancellation_bound_us": adoption.poc_validate.CANCELLATION_WAKE_BOUND_US,
    }
    diagnostic_supported = platform == "macos-arm64"
    return {
        "schema_version": adoption.poc_validate.RESULT_SCHEMA_VERSION,
        "task_id": "M0-016",
        "provider": "aws-lc",
        "platform": platform,
        "status": "PASS",
        "execution": {
            "repository_revision": revision,
            "runner_os": "Windows" if platform == "windows-x86_64" else "macOS",
            "runner_arch": "X64" if platform == "windows-x86_64" else "ARM64",
            "image_os": adoption.EXPECTED_RUNNER_IMAGES[platform],
            "image_version": "1",
        },
        "source": {
            "kind": provider["source_kind"],
            "commit": provider["commit"],
            "tree": provider["tree"],
            "content_sha256": provider["content_sha256"],
            "security_update": copy.deepcopy(provider["security_update"]),
        },
        "poc_exit_code": 0,
        "capabilities": {name: "PASS" for name in spec["required_capabilities"]},
        "build": {
            "binary_bytes": 1,
            "binary_sha256": "8" * 64,
            "static_archives": [
                {"name": "libssl.a", "bytes": 1, "sha256": "6" * 64}
            ],
            "exported_symbol_inventory": {
                "scope": "final-artifact-exports",
                "tool": "fixture-tool",
                "count": 0,
                "sha256": evidence_digest.text_evidence_bytes_sha256(b""),
                "symbols": [],
            },
            "system_tls_dependencies": [],
            "runtime_loader_library_strings": [],
            "license_bundle": {
                "path": "license-bundle/manifest.json",
                "sha256": {
                    "windows-x86_64": "8b9587ca33ad3f6023cf56c3f744e7e2e65191ace8eb6ff54d1b23435aaad176",
                    "macos-arm64": "a42cbc822fa76edd34cbd276ccb1d1eb2e915864610a76f33bc341f5edffc94f",
                }[platform],
                "file_count": 11,
                "total_bytes": {
                    "windows-x86_64": 80451,
                    "macos-arm64": 79058,
                }[platform],
            },
            "provenance": build_provenance(platform),
        },
        "metrics": metrics,
        "operational_evidence": {
            "native_memory_diagnostic": {
                "status": "PASS" if diagnostic_supported else "UNSUPPORTED",
                "tool": "address+undefined-sanitizer",
                "cleanup_cycles": 10,
                "output_sha256": "7" * 64,
                "leak_detection": {"status": "UNSUPPORTED"},
                **({
                    "provider_instrumented": True,
                    "provider_static_archives": [{
                        "name": "libprovider.a", "bytes": 1,
                        "sha256": "5" * 64,
                    }],
                    "provider_build_provenance": build_provenance(
                        platform, diagnostic=True
                    ),
                } if diagnostic_supported else {}),
            },
            "memory_profile": {
                "method": "native-process-peak-resident-and-provider-allocation-hooks",
                "peak_resident_bytes": metrics["memory_profile_peak_resident_bytes"],
                "resident_bound_bytes": metrics["memory_profile_bound_bytes"],
                "provider_allocation_calls": metrics["provider_allocation_calls"],
                "provider_allocation_call_bound": metrics["provider_allocation_call_bound"],
                "provider_allocation_bytes": metrics["provider_allocation_bytes"],
                "provider_allocation_bound_bytes": metrics["provider_allocation_bound_bytes"],
                "provider_allocation_peak_live_bytes": metrics["provider_allocation_peak_live_bytes"],
                "provider_allocation_live_before_cleanup_bytes": metrics["provider_allocation_live_before_cleanup_bytes"],
                "provider_allocation_live_after_cleanup_bytes": metrics["provider_allocation_live_after_cleanup_bytes"],
                "payload_bytes_per_transfer": 32768,
            },
            "cancellation": {
                "method": "caller-owned-wait-thread-explicit-cancel-and-bounded-join",
                "wakeups": metrics["cancellation_wakeups"],
                "latency_us": metrics["cancellation_latency_us"],
                "bound_us": metrics["cancellation_bound_us"],
            },
        },
    }


class M3031DesktopTlsAdoptionTests(unittest.TestCase):
    revision = "d" * 40

    def assert_code(self, code: str, callback) -> None:
        with self.assertRaises(adoption.AdoptionError) as caught:
            callback()
        self.assertEqual(code, caught.exception.code)

    def test_repository_core_audit_rejects_legacy_dependency_evidence(self) -> None:
        self.assert_code("DEPENDENCY_EVIDENCE", lambda: adoption.audit_core(ROOT))

    def test_dependency_evidence_rejects_source_and_native_report_drift(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "native/resolver/windows/wirestack_resolver.c"
            source.parent.mkdir(parents=True)
            source.write_text("source", encoding="utf-8")
            header = root / "native/resolver/windows/wirestack_resolver.h"
            header.write_text("header", encoding="utf-8")
            report_relative = "docs/evidence/M2-004/windows-x86_64/report.json"
            validation_relative = "docs/evidence/M2-004/windows-x86_64/validation.json"
            report = root / report_relative
            validation = root / validation_relative
            report.parent.mkdir(parents=True)
            report.write_bytes((json.dumps({
                "schema_version": 1, "task_id": "M2-004", "revision": "a" * 40,
                "decision": "PASS", "failures": [],
                "platform": {"system": "Windows"},
                "resolver_test": {
                    "timed_out": False, "exit_code": 0,
                    "output": "[ PASSED ] CASE:\n" * 6 + "FAILED: 0\nERROR: 0\n",
                },
                "resolver_manifest": {
                    "platform": "windows-x86_64", "private_runtime_abi": False,
                    "test_fixture": True,
                    "inputs": {
                        "source_sha256": evidence_digest.text_evidence_sha256(source),
                        "header_sha256": evidence_digest.text_evidence_sha256(header),
                    },
                },
                "test_link_stub": {"test_only": True},
            }, indent=2) + "\n").replace("\n", "\r\n").encode("utf-8"))
            validation.write_bytes((json.dumps({
                "schema_version": 1, "task_id": "M2-004",
                "expected_revision": "a" * 40, "failures": [], "status": "PASS",
                "report_sha256": evidence_digest.text_evidence_sha256(report),
            }, indent=2) + "\n").replace("\n", "\r\n").encode("utf-8"))
            evidence_path = root / "docs/evidence/M2-004/evidence.json"
            evidence_path.parent.mkdir(parents=True, exist_ok=True)
            evidence_path.write_text(json.dumps({
                "schema_version": adoption.repository_tooling.EVIDENCE_SCHEMA_VERSION,
                "source_task": "M2-004",
                "platform": {}, "toolchain": {}, "acceptance_status": "PASS",
                "generated_at_utc": "2026-08-31T00:00:00Z", "revision": "a" * 40,
                "reports": [{
                    "path": validation_relative,
                    "sha256": evidence_digest.text_evidence_digest(validation).to_json(),
                    "source_task": "M2-004", "acceptance_status": "PASS",
                }],
                "source_sha256": {
                    "native/resolver/windows/wirestack_resolver.c": evidence_digest.text_evidence_digest(source).to_json(),
                    "native/resolver/windows/wirestack_resolver.h": evidence_digest.text_evidence_digest(header).to_json(),
                },
            }), encoding="utf-8")
            task = {
                "task_id": "M2-004", "source_paths": [
                    "native/resolver/windows/wirestack_resolver.c",
                    "native/resolver/windows/wirestack_resolver.h",
                ],
                "required_evidence": [
                    "docs/evidence/M2-004/evidence.json", validation_relative,
                ],
            }
            status_path = root / "docs/planning/status.md"
            status_path.parent.mkdir(parents=True, exist_ok=True)
            status_path.write_text(
                "| M2-004 | COMPLETE | evidence | test |\n", encoding="utf-8"
            )
            bindings = {"M2-004": ((validation_relative, report_relative, None),)}
            with mock.patch.object(
                adoption.repository_tooling, "load_task", return_value=task
            ):
                self.assertEqual(
                    "PASS", adoption.validate_dependency_evidence(root, bindings)["status"]
                )
                status_path.write_text(
                    "| M2-004 | BLOCKED | — | test |\n", encoding="utf-8"
                )
                self.assert_code(
                    "DEPENDENCY_EVIDENCE",
                    lambda: adoption.validate_dependency_evidence(root, bindings),
                )
                status_path.write_text(
                    "| M2-004 | COMPLETE | evidence | test |\n", encoding="utf-8"
                )
                source.write_text("drift", encoding="utf-8")
                self.assert_code(
                    "STALE_SOURCE",
                    lambda: adoption.validate_dependency_evidence(root, bindings),
                )
                self.assert_code(
                    "STALE_SOURCE",
                    lambda: adoption.validate_dependency_evidence(
                        root, bindings, verify_current_sources=False
                    ),
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
            task = json.loads((ROOT / "tools/tasks/M3-030.json").read_text(encoding="utf-8"))
            for relative in task["source_paths"]:
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(ROOT / relative, path)
            for relative in (
                "docs/evidence/M7-021/linux_x86_64/qualification.json",
                "docs/evidence/M7-025/linux_x86_64/bundle.json",
            ):
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(ROOT / relative, path)
            status_path = root / "docs/planning/status.md"
            status_path.write_text(
                "| M3-030 | COMPLETE | evidence | rationale |\n", encoding="utf-8"
            )
            evidence_path = root / "docs/evidence/M3-030/evidence.json"
            evidence_path.parent.mkdir(parents=True, exist_ok=True)
            report_paths = adoption.RETAINED_EVIDENCE
            reports = []
            for relative in report_paths:
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(ROOT / relative, path)
                reports.append({"path": relative, "source_task": "M3-030",
                                "acceptance_status": "PASS",
                                "sha256": evidence_digest.text_evidence_sha256(path)})
            evidence = {"schema_version": 1, "source_task": "M3-030",
                        "acceptance_status": "PASS", "reports": reports,
                        "source_sha256": {
                            relative: evidence_digest.text_evidence_sha256(root / relative)
                            for relative in task["source_paths"]
                        }}
            evidence_path.write_text(json.dumps(evidence), encoding="utf-8")
            retained = adoption.validate_retained_evidence(root)
            self.assertEqual("PASS", retained["status"])
            self.assertEqual([], retained["changed_since_m3_030"])
            status_path.write_text(
                "| M3-030 | BLOCKED | evidence | rationale |\n", encoding="utf-8"
            )
            self.assert_code(
                "RETAINED_EVIDENCE", lambda: adoption.validate_retained_evidence(root)
            )
            status_path.write_text(
                "| M3-030 | COMPLETE | evidence | rationale |\n", encoding="utf-8"
            )
            release_path = root / "docs/evidence/M3-030/release-validation.json"
            release_path.write_text(
                json.dumps({"source_task": "M3-030", "status": "FAIL"}),
                encoding="utf-8",
            )
            release_entry = next(
                item for item in reports
                if item["path"] == "docs/evidence/M3-030/release-validation.json"
            )
            release_entry["sha256"] = evidence_digest.text_evidence_sha256(release_path)
            evidence_path.write_text(json.dumps(evidence), encoding="utf-8")
            self.assert_code(
                "RETAINED_EVIDENCE", lambda: adoption.validate_retained_evidence(root)
            )
            shutil.copy2(ROOT / "docs/evidence/M3-030/release-validation.json", release_path)
            release_entry["sha256"] = evidence_digest.text_evidence_sha256(release_path)
            evidence_path.write_text(json.dumps(evidence), encoding="utf-8")
            abi_path = root / "docs/evidence/M3-030/native-abi-report.json"
            abi = json.loads(abi_path.read_text(encoding="utf-8"))
            abi["missingFunctions"].append("wirestack_tls_provider_create")
            abi_path.write_text(json.dumps(abi), encoding="utf-8")
            abi_entry = next(
                item for item in reports
                if item["path"] == "docs/evidence/M3-030/native-abi-report.json"
            )
            abi_entry["sha256"] = evidence_digest.text_evidence_sha256(abi_path)
            evidence_path.write_text(json.dumps(evidence), encoding="utf-8")
            self.assert_code(
                "RETAINED_EVIDENCE", lambda: adoption.validate_retained_evidence(root)
            )
            shutil.copy2(ROOT / "docs/evidence/M3-030/native-abi-report.json", abi_path)
            abi_entry["sha256"] = evidence_digest.text_evidence_sha256(abi_path)
            task_check_path = root / "docs/evidence/M3-030/task-check.json"
            task_check = json.loads(task_check_path.read_text(encoding="utf-8"))
            task_check["commands"][0]["status"] = "SKIPPED"
            task_check_path.write_text(json.dumps(task_check), encoding="utf-8")
            task_check_entry = next(
                item for item in reports
                if item["path"] == "docs/evidence/M3-030/task-check.json"
            )
            task_check_entry["sha256"] = evidence_digest.text_evidence_sha256(task_check_path)
            evidence_path.write_text(json.dumps(evidence), encoding="utf-8")
            self.assert_code(
                "RETAINED_EVIDENCE", lambda: adoption.validate_retained_evidence(root)
            )
            shutil.copy2(ROOT / "docs/evidence/M3-030/task-check.json", task_check_path)
            task_check_entry["sha256"] = evidence_digest.text_evidence_sha256(task_check_path)
            evidence_path.write_text(json.dumps(evidence), encoding="utf-8")
            evidence["source_sha256"].pop("build.cj")
            evidence_path.write_text(json.dumps(evidence), encoding="utf-8")
            self.assert_code(
                "RETAINED_EVIDENCE", lambda: adoption.validate_retained_evidence(root)
            )
            evidence["source_sha256"]["build.cj"] = evidence_digest.text_evidence_sha256(
                root / "build.cj"
            )
            evidence_path.write_text(json.dumps(evidence), encoding="utf-8")
            source = root / "build.cj"
            source.write_text("drift", encoding="utf-8")
            retained = adoption.validate_retained_evidence(root)
            self.assertEqual(["build.cj"], retained["changed_since_m3_030"])
            self.assertNotEqual(
                retained["recorded_source_sha256"]["build.cj"],
                retained["source_sha256"]["build.cj"],
            )

    def test_hosted_run_is_bound_to_current_provider_inputs(self) -> None:
        revision = "a" * 40
        windows_result = "docs/evidence/M3-031/windows-x86_64/provider-result.json"
        windows_validation = "docs/evidence/M3-031/windows-x86_64/validation.json"
        macos_result = "docs/evidence/M3-031/macos-arm64/provider-result.json"
        macos_validation = "docs/evidence/M3-031/macos-arm64/validation.json"
        raw = {
            "schema_version": 2, "task_id": "M3-031", "status": "PASS",
            "conclusion": "success", "revision": revision,
            "source_sha256": adoption.hosted_input_sha256(ROOT),
            "artifacts": [
                {
                    "name": f"m3-031-windows-x86_64-{revision}",
                    "provider_result_sha256": evidence_digest.text_evidence_sha256(ROOT / windows_result),
                    "validation_sha256": evidence_digest.text_evidence_sha256(ROOT / windows_validation),
                },
                {
                    "name": f"m3-031-macos-arm64-{revision}",
                    "provider_result_sha256": evidence_digest.text_evidence_sha256(ROOT / macos_result),
                    "validation_sha256": evidence_digest.text_evidence_sha256(ROOT / macos_validation),
                },
            ],
        }
        self.assertEqual("PASS", adoption.validate_hosted_run(ROOT, raw)["status"])
        raw["source_sha256"][adoption.HOSTED_INPUT_PATHS[0]] = "0" * 64
        self.assert_code("STALE_SOURCE", lambda: adoption.validate_hosted_run(ROOT, raw))
        raw["source_sha256"] = adoption.hosted_input_sha256(ROOT)
        raw["artifacts"][0]["provider_result_sha256"] = "0" * 64
        self.assert_code("STALE_SOURCE", lambda: adoption.validate_hosted_run(ROOT, raw))

    def test_repository_text_digest_is_checkout_line_ending_stable(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "report.json"
            path.write_bytes(b'{\r\n  "status": "PASS"\r\n}\r\n')
            windows_digest = evidence_digest.text_evidence_sha256(path)
            path.write_bytes(b'{\n  "status": "PASS"\n}\n')
            self.assertEqual(windows_digest, evidence_digest.text_evidence_sha256(path))

    def test_desktop_acceptance_column_cannot_be_weakened(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            backlog = (ROOT / "docs/planning/implementation-backlog.md").read_text(
                encoding="utf-8"
            )
            acceptance = adoption.EXPECTED_DESKTOP_ACCEPTANCE["M3-014"]
            backlog = backlog.replace(acceptance, "使用系统证书链与策略")
            path = root / "docs/planning/implementation-backlog.md"
            path.parent.mkdir(parents=True)
            path.write_text(backlog, encoding="utf-8")
            self.assert_code("TASK_GRAPH", lambda: adoption.audit_task_graph(root))

    def test_dependency_evidence_json_preserves_exact_artifact_bytes(self) -> None:
        attributes = (ROOT / ".gitattributes").read_text(encoding="utf-8")
        for task_id in ("M2-004", "M2-006"):
            self.assertIn(f"docs/evidence/{task_id}/*.json -text", attributes)
            self.assertIn(f"docs/evidence/{task_id}/**/*.json -text", attributes)

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

    def test_provider_license_bundle_is_retained_and_digest_bound(self) -> None:
        raw = provider_result("windows-x86_64", self.revision)
        raw["build"]["license_bundle"]["sha256"] = "0" * 64
        self.assert_code(
            "LICENSE_BUNDLE",
            lambda: adoption.validate_provider_result(
                raw,
                expected_platform="windows-x86_64",
                expected_revision=self.revision,
            ),
        )
        raw = provider_result("macos-arm64", self.revision)
        raw["build"]["license_bundle"]["path"] = "../../outside/manifest.json"
        self.assert_code(
            "RAW_RESULT",
            lambda: adoption.validate_provider_result(
                raw,
                expected_platform="macos-arm64",
                expected_revision=self.revision,
            ),
        )
        with tempfile.TemporaryDirectory() as directory:
            result_path = Path(directory) / "provider-result.json"
            self.assert_code(
                "LICENSE_BUNDLE",
                lambda: adoption.validate_provider_result(
                    provider_result("windows-x86_64", self.revision),
                    expected_platform="windows-x86_64",
                    expected_revision=self.revision,
                    result_path=result_path,
                ),
            )

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

    def test_failed_poc_wrong_runner_and_source_identity_are_rejected(self) -> None:
        raw = provider_result("windows-x86_64", self.revision)
        raw["poc_exit_code"] = 1
        self.assert_code(
            "INCOMPLETE_RESULT",
            lambda: adoption.validate_provider_result(
                raw, expected_platform="windows-x86_64",
                expected_revision=self.revision,
            ),
        )
        raw = provider_result("windows-x86_64", self.revision)
        raw["execution"]["image_os"] = "windows-2022"
        self.assert_code(
            "PLATFORM",
            lambda: adoption.validate_provider_result(
                raw, expected_platform="windows-x86_64",
                expected_revision=self.revision,
            ),
        )
        raw = provider_result("macos-arm64", self.revision)
        raw["source"]["tree"] = "0" * 40
        self.assert_code(
            "PROVIDER",
            lambda: adoption.validate_provider_result(
                raw, expected_platform="macos-arm64",
                expected_revision=self.revision,
            ),
        )

    def test_provider_manifest_cannot_move_the_approved_pin(self) -> None:
        raw = provider_result("macos-arm64", self.revision)
        original_load = adoption.load_json

        def moved_manifest(path: Path) -> dict:
            value = original_load(path)
            if path == ROOT / "native/tls/aws_lc/provider.json":
                value = copy.deepcopy(value)
                value["provider_version"] = "9.9.9"
            return value

        with mock.patch.object(adoption, "load_json", side_effect=moved_manifest):
            self.assert_code(
                "PROVIDER",
                lambda: adoption.validate_provider_result(
                    raw, expected_platform="macos-arm64",
                    expected_revision=self.revision,
                ),
            )

    def test_validate_provider_honors_selected_root(self) -> None:
        raw = provider_result("macos-arm64", self.revision)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest_path = root / "native/tls/aws_lc/provider.json"
            spec_path = root / "tools/tls_provider_poc/providers.json"
            manifest_path.parent.mkdir(parents=True)
            spec_path.parent.mkdir(parents=True)
            manifest = json.loads(
                (ROOT / "native/tls/aws_lc/provider.json").read_text(encoding="utf-8")
            )
            manifest["provider_version"] = "9.9.9"
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
            spec_path.write_text(
                (ROOT / "tools/tls_provider_poc/providers.json").read_text(encoding="utf-8"),
                encoding="utf-8",
            )
            self.assert_code(
                "PROVIDER",
                lambda: adoption.validate_provider_result(
                    raw,
                    expected_platform="macos-arm64",
                    expected_revision=self.revision,
                    root=root,
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
