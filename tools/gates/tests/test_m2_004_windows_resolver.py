from __future__ import annotations

from tools import evidence_digest

import json
import tempfile
import unittest
from pathlib import Path

from tools.gates import m2_004_windows_resolver as gate


REVISION = "a" * 40


def command_process(command: list[str], output: str) -> dict[str, object]:
    return {
        "command": command,
        "duration_ms": 1.0,
        "exit_code": 0,
        "output": output,
        "timed_out": False,
    }


def valid_process() -> dict[str, object]:
    output = "".join(
        f"[ PASSED ] CASE: {case}\n" for case in gate.EXPECTED_CASES
    ) + "Summary: TOTAL: 6\nPASSED: 6, SKIPPED: 0, ERROR: 0\nFAILED: 0\n"
    return command_process(
        [
            "cjpm", "test", "src/internal/resolver", "-j", "1", "--parallel", "1",
            "--filter", "M2004WindowsSystemResolverTest", "--show-all-output",
            "--no-color", "--no-progress",
        ],
        output,
    )


def valid_report() -> dict[str, object]:
    root = Path.cwd()
    inventory = gate.source_inventory(root)
    source_digests = {entry["path"]: entry["digest"] for entry in inventory["paths"]}
    pin = gate.load_sdk_pin(root)
    cjc_output = (
        "Cangjie Compiler: 1.2.0\n"
        "Target: x86_64-w64-mingw32\n"
    )
    cjpm_output = "Cangjie Project Manager: 1.2.0\n"
    sdk = {
        "channel": "STS",
        "version": "1.2.0",
        "archive_name": pin["archive"]["name"],
        "archive": {
            "domain": evidence_digest.ARTIFACT_BYTE_DOMAIN,
            "sha256": pin["archive"]["sha256"],
        },
        "matched_archive_files": 1,
        "platform": {
            "system": "Windows",
            "machine": "AMD64",
            "native_target": "x86_64-w64-mingw32",
        },
        "cjc": {
            "relative_path": "tools/bin/cjc.exe",
            "version": "1.2.0",
            "version_output": cjc_output,
            "target": "x86_64-w64-mingw32",
        },
        "cjpm": {
            "relative_path": "tools/bin/cjpm.exe",
            "version": "1.2.0",
            "version_output": cjpm_output,
        },
    }
    build_output = "native resolver build passed\n"
    compile_output = "test-only resolver link stub compiled\n"
    archive_output = "test-only resolver link archive created\n"
    test_output = valid_process()["output"]
    manifest = {
        "schema_version": 1,
        "build_fingerprint": {
            "domain": evidence_digest.TEXT_EVIDENCE_DOMAIN,
            "sha256": "b" * 64,
        },
        "platform": "windows-x86_64",
        "inputs": {
            "schema": 1,
            "source_digest": source_digests["native/resolver/windows/wirestack_resolver.c"],
            "header_digest": source_digests["native/resolver/windows/wirestack_resolver.h"],
            "compiler": "clang.exe",
            "compiler_version": "clang version 20.1.0",
            "target": "x86_64-pc-windows-msvc",
            "flags": ["-std=c11", "-O2", "-Wall", "-Wextra", "-Werror"],
            "test_fixture": True,
        },
        "archive": {
            "path": "lib/libwirestack_resolver.a",
            "digest": {
                "domain": evidence_digest.ARTIFACT_BYTE_DOMAIN,
                "sha256": "c" * 64,
            },
        },
        "worker_model": "bounded",
        "close_model": "wait-for-native-completion",
        "private_runtime_abi": False,
        "test_fixture": True,
    }
    log_values = {
        "resolver_build": ("resolver-build.log", build_output),
        "link_stub_compile": ("test-link-stub-compile.log", compile_output),
        "link_stub_archive": ("test-link-stub-archive.log", archive_output),
        "resolver_test": ("resolver-tests.log", test_output),
        "cjc_version": ("cjc-version.log", cjc_output),
        "cjpm_version": ("cjpm-version.log", cjpm_output),
    }
    prefix = "docs/evidence/M2-004/current-desktop/windows-x86_64/logs"
    logs = {
        key: {
            "path": f"{prefix}/{filename}",
            "digest": gate.text_for_log_digest(output),
        }
        for key, (filename, output) in log_values.items()
    }
    stub = {
        "archive_digest": {
            "domain": evidence_digest.ARTIFACT_BYTE_DOMAIN,
            "sha256": "d" * 64,
        },
        "compile": command_process(
            [
                "clang.exe", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
                "-c", "tools/gates/native/m2_004_tls_link_stub.c", "-o",
                "target/native/test-support/m2-004/m2_004_tls_link_stub.o",
            ],
            compile_output,
        ),
        "archive": command_process(
            [
                "llvm-ar.exe", "rcs",
                "target/native/test-support/m2-004/lib/libwirestack_m2_004_tls_link_stub.a",
                "target/native/test-support/m2-004/m2_004_tls_link_stub.o",
            ],
            archive_output,
        ),
        "source_digest": source_digests["tools/gates/native/m2_004_tls_link_stub.c"],
        "purpose": "M2-004 resolver-test link support; all functions fail closed",
        "test_only": True,
    }
    build = command_process(
        [
            "python", "tools/build_resolver.py", "--root", ".",
            "--platform", "windows-x86_64", "--test-fixture", "--quiet",
        ],
        build_output,
    )
    return {
        "schema_version": gate.SCHEMA_VERSION,
        "task_id": "M2-004",
        "gate_id": "M2-004-WINDOWS-SYSTEM-RESOLVER",
        "generated_at_utc": "2026-10-24T12:00:00Z",
        "revision": REVISION,
        "platform": {
            "system": "Windows",
            "release": "2025",
            "machine": "AMD64",
            "runner_image": "windows-2025",
            "runner_image_version": "test",
        },
        "sdk": sdk,
        "resolver_manifest": manifest,
        "resolver_manifest_digest": gate.text_digest_for_value(manifest),
        "build": build,
        "test_link_stub": stub,
        "resolver_test": valid_process(),
        "source_inventory": inventory,
        "logs": logs,
        "failures": [],
        "decision": "PASS",
        "scope": "native Windows x86_64 resolver only",
    }


class M2004WindowsResolverGateTests(unittest.TestCase):
    def test_native_manifest_rejects_text_path_with_matching_digest(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            native = root / "native/resolver/windows"
            native.mkdir(parents=True)
            source = native / "wirestack_resolver.c"
            header = native / "wirestack_resolver.h"
            source.write_text("fixture source\n", encoding="utf-8")
            header.write_text("fixture header\n", encoding="utf-8")
            artifact_root = root / "target/native/resolver/current"
            archive = artifact_root / "lib/libwirestack_resolver.a"
            archive.parent.mkdir(parents=True)
            archive.write_bytes(b"!<arch>\n")
            manifest = {
                "build_fingerprint": "a" * 64,
                "inputs": {
                    "source_sha256": evidence_digest.text_evidence_sha256(source),
                    "header_sha256": evidence_digest.text_evidence_sha256(header),
                    "compiler": "clang.exe",
                },
                "archive": {
                    "path": "lib/libwirestack_resolver.a",
                    "sha256": evidence_digest.artifact_byte_sha256(archive),
                },
            }
            gate.normalize_resolver_manifest(root, manifest)
            text_path = artifact_root / "resolver-manifest.json"
            text_path.write_text("{}\n", encoding="utf-8")
            manifest["archive"] = {
                "path": "resolver-manifest.json",
                "sha256": evidence_digest.text_evidence_sha256(text_path),
            }
            with self.assertRaisesRegex(gate.GateError, "archive path"):
                gate.normalize_resolver_manifest(root, manifest)




    def test_valid_report_passes(self) -> None:
        self.assertEqual([], gate.validate_report(valid_report(), REVISION))

    def test_validation_payload_binds_typed_report_and_source_digests(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            report_path = Path(directory) / "report.json"
            report = valid_report()
            report_path.write_text(json.dumps(report), encoding="utf-8")
            _, report_digest = gate.load_report(report_path)
            validation = gate.validation_payload(
                report_digest, REVISION, report["source_inventory"]["digest"], []
            )
            self.assertEqual(
                evidence_digest.text_evidence_digest(report_path).to_json(),
                validation["report_digest"],
            )
            self.assertEqual(
                report["source_inventory"]["digest"], validation["source_inventory_digest"]
            )
            original_digest = validation["report_digest"]

            report_path.write_text(json.dumps({"decision": "FAIL"}), encoding="utf-8")
            self.assertNotEqual(original_digest, gate.load_report(report_path)[1])

    def test_loaded_report_digest_cannot_follow_an_atomic_replacement(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            report_path = Path(directory) / "report.json"
            report = valid_report()
            report_path.write_text(json.dumps(report), encoding="utf-8")
            payload, report_digest = gate.load_report(report_path)
            report_path.write_text(json.dumps({"decision": "FAIL"}), encoding="utf-8")
            validation = gate.validation_payload(
                report_digest,
                REVISION,
                payload["source_inventory"]["digest"],
                gate.validate_report(payload, REVISION),
            )
            self.assertEqual("PASS", validation["status"])
            self.assertNotEqual(
                evidence_digest.text_evidence_digest(report_path).to_json(),
                validation["report_digest"],
            )

    def test_stored_validation_must_match_the_validated_report(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            validation_path = Path(directory) / "validation.json"
            expected = gate.validation_payload(
                {
                    "domain": evidence_digest.TEXT_EVIDENCE_DOMAIN,
                    "sha256": "a" * 64,
                },
                REVISION,
                {
                    "domain": evidence_digest.TEXT_EVIDENCE_DOMAIN,
                    "sha256": "b" * 64,
                },
                [],
            )
            validation_path.write_text(json.dumps(expected), encoding="utf-8")
            self.assertEqual(
                [], gate.stored_validation_failures(validation_path, expected)
            )
            changed = dict(expected)
            changed["report_digest"] = {
                "domain": evidence_digest.TEXT_EVIDENCE_DOMAIN,
                "sha256": "c" * 64,
            }
            self.assertEqual(
                ["VALIDATION:MISMATCH"],
                gate.stored_validation_failures(validation_path, changed),
            )
            validation_path.unlink()
            self.assertEqual(
                ["VALIDATION:MISSING"],
                gate.stored_validation_failures(validation_path, expected),
            )

    def test_rejects_unknown_schema_stale_revision_and_wrong_platform(self) -> None:
        report = valid_report()
        report["schema_version"] = 9
        report["revision"] = "b" * 40
        report["platform"] = {
            "system": "Linux",
            "release": "test",
            "machine": "x86_64",
            "runner_image": "linux",
            "runner_image_version": "test",
        }
        failures = gate.validate_report(report, REVISION)
        self.assertIn("REPORT:UNKNOWN_SCHEMA", failures)
        self.assertIn("REPORT:STALE_REVISION", failures)
        self.assertIn("REPORT:NON_NATIVE_WINDOWS", failures)

    def test_rejects_source_inventory_drift_with_recomputed_typed_digest(self) -> None:
        report = valid_report()
        inventory = report["source_inventory"]
        entries = [dict(entry) for entry in inventory["paths"]]
        entries[0]["digest"] = {
            "domain": evidence_digest.TEXT_EVIDENCE_DOMAIN,
            "sha256": "f" * 64,
        }
        body = {"schema_version": inventory["schema_version"], "paths": entries}
        report["source_inventory"] = {
            **body,
            "digest": gate.text_digest_for_value(body),
        }
        self.assertIn("SOURCE:DRIFT", gate.validate_report(report, REVISION))

    def test_rejects_pinned_sdk_and_log_digest_drift(self) -> None:
        report = valid_report()
        report["sdk"]["archive"]["sha256"] = "0" * 64
        report["logs"]["resolver_build"]["digest"]["sha256"] = "1" * 64
        failures = gate.validate_report(report, REVISION)
        self.assertIn("SDK:ARCHIVE_DIGEST", failures)
        self.assertIn("LOGS:RESOLVER_BUILD_CONTENT", failures)

    def test_rejects_skipped_case_even_with_zero_exit(self) -> None:
        report = valid_report()
        process = valid_process()
        process["output"] += "[ SKIPPED ] CASE: delayed\n"
        report["resolver_test"] = process
        self.assertIn(
            "RESOLVER_TEST:NON_PASS_CASE",
            gate.validate_report(report, REVISION),
        )

    def test_rejects_timeout_and_missing_fixture_binding(self) -> None:
        report = valid_report()
        process = valid_process()
        process["timed_out"] = True
        report["resolver_test"] = process
        manifest = dict(report["resolver_manifest"])
        manifest["test_fixture"] = False
        report["resolver_manifest"] = manifest
        failures = gate.validate_report(report, REVISION)
        self.assertIn("RESOLVER_TEST:TIMEOUT", failures)
        self.assertIn("REPORT:FIXTURE_NOT_BOUND", failures)

    def test_rejects_missing_test_only_link_stub_marker(self) -> None:
        report = valid_report()
        report["test_link_stub"] = {"test_only": False}
        self.assertIn("REPORT:TEST_LINK_STUB", gate.validate_report(report, REVISION))



if __name__ == "__main__":
    unittest.main()
