from __future__ import annotations

from tools import evidence_digest

import json
import tempfile
import unittest
from pathlib import Path

from tools import build_apple_resolver
from tools.gates import m2_006_apple_resolver as gate


def valid_process(mode: str = "macos") -> dict[str, object]:
    if mode == "ios-simulator":
        output = "".join(
            f"[ TRACE ] CASE: {case_id} START\n[ TRACE ] CASE: {case_id} PASS\n"
            for case_id in range(1, gate.EXPECTED_TESTS + 1)
        )
    else:
        output = "".join(
            f"[ PASSED ] CASE: {name}\n" for name in gate.EXPECTED_CASES["macos"]
        ) + "FAILED: 0\nERROR: 0\n"
    return {
        "timed_out": False,
        "exit_code": 0,
        "output": output,
    }


def command_receipt(command: list[str], output: str = "") -> dict[str, object]:
    return {
        "command": command,
        "duration_ms": 1.0,
        "exit_code": 0,
        "diagnostics": gate._diagnostics_for_output(output),
        "output": output,
        "timed_out": False,
    }


def valid_report(mode: str = "macos") -> dict[str, object]:
    source_inventory = [
        {
            "path": path,
            "digest": evidence_digest.text_evidence_digest_bytes(
                path.encode("utf-8")
            ).to_json(),
        }
        for path in gate.SOURCE_PATHS
    ]
    source_digests = {
        item["path"]: item["digest"]["sha256"] for item in source_inventory
    }
    native_sources = {
        path: source_digests[path]
        for path in (
            "native/resolver/apple/wirestack_resolver.c",
            "native/resolver/apple/wirestack_resolver.h",
            "native/resolver/linux/wirestack_resolver.c",
            "native/resolver/linux/wirestack_resolver.h",
        )
    }
    manifest = {
        "schema_version": 1,
        "build_fingerprint": "b" * 64,
        "platform": "macos-arm64",
        "inputs": {
            "schema": 1,
            "platform": "macos-arm64",
            "sources": native_sources,
            "compiler": "<XCODE_PATH>",
            "compiler_version": "Apple clang version",
            "flags": ["-std=c11", "-mmacosx-version-min=12.0"],
            "test_fixture": True,
        },
        "archive": {
            "path": "lib/libwirestack_resolver.a",
            "digest": {
                "domain": evidence_digest.ARTIFACT_BYTE_DOMAIN,
                "sha256": "c" * 64,
            },
        },
        "worker_model": "fixed pthread pool",
        "close_model": "bounded quarantine",
        "private_runtime_abi": False,
        "test_fixture": True,
        "build_smoke": "PASS",
    }
    report: dict[str, object] = {
        "schema_version": gate.SCHEMA_VERSION,
        "task_id": "M2-006",
        "gate_id": "M2-006-APPLE-SYSTEM-RESOLVER",
        "generated_at_utc": "2030-01-01T00:00:00Z",
        "revision": "a" * 40,
        "mode": mode,
        "platform": {
            "system": "Darwin",
            "release": "26.0.0",
            "machine": "arm64",
            "runner_image": "macos-15",
            "runner_image_version": "15A",
            "toolchain": command_receipt(
                ["$CANGJIE_HOME/bin/cjc", "-v"],
                "Cangjie Compiler: 1.2.0\nTarget: aarch64-apple-darwin\n",
            ),
        },
        "source_inventory": {
            "revision": "a" * 40,
            "clean_worktree": True,
            "files": source_inventory,
        },
        "sdk": {
            "channel": "STS",
            "version": "1.2.0",
            "archive_name": gate.PINNED_SDK_ARCHIVE_NAME,
            "archive": {
                "domain": evidence_digest.ARTIFACT_BYTE_DOMAIN,
                "sha256": gate.PINNED_SDK_ARCHIVE_SHA256,
            },
            "matched_archive_files": 1200,
            "platform": {
                "system": "Darwin",
                "machine": "arm64",
                "native_target": gate.PINNED_SDK_TARGET,
            },
            "cjc": {
                "relative_path": "bin/cjc",
                "version": "1.2.0",
                "version_output": (
                    "Cangjie Compiler: 1.2.0\nTarget: aarch64-apple-darwin"
                ),
                "target": gate.PINNED_SDK_TARGET,
            },
            "cjpm": {
                "relative_path": "tools/bin/cjpm",
                "version": "1.2.0",
                "version_output": "Cangjie Project Manager: 1.2.0",
            },
        },
        "resolver_manifest": manifest,
        "resolver_manifest_digest": gate._json_text_digest(manifest),
        "build": command_receipt(
            [
                "python3", "<repo>/tools/build_resolver.py", "--root", "<repo>",
                "--platform", "macos-arm64", "--test-fixture", "--quiet",
            ]
        ),
        "test_link_stub": {
            "archive_digest": {
                "domain": evidence_digest.ARTIFACT_BYTE_DOMAIN,
                "sha256": "d" * 64,
            },
            "compile": command_receipt(["clang", "-c", "m2_006_tls_link_stub.c"]),
            "archive": command_receipt(["ar", "rcs", "libwirestack_m2_006_tls_link_stub.a"]),
            "source_digest": {
                "domain": evidence_digest.TEXT_EVIDENCE_DOMAIN,
                "sha256": source_digests["tools/gates/native/m2_006_tls_link_stub.c"],
            },
            "test_only": True,
            "target": "macos-arm64",
        },
        "resolver_test": command_receipt(
            [
                "$CANGJIE_HOME/tools/bin/cjpm", "test", "src/internal/resolver", "-j", "1",
                "--parallel", "1", "--filter", "M2006AppleSystemResolverTest",
                "--show-all-output", "--no-color", "--no-progress",
            ],
            valid_process()["output"],
        ),
        "logs": [],
        "failures": [],
        "decision": "PASS",
        "scope": "native macOS arm64",
    }

    receipts = gate._log_receipts(report)
    report["logs"] = [
        {
            "id": log_id,
            "path": f"logs/{log_id}.log",
            "digest": evidence_digest.text_evidence_digest_bytes(
                receipts[log_id]["output"].encode("utf-8")
            ).to_json(),
        }
        for log_id in gate.LOG_IDS
    ]
    return report


class M2006AppleResolverGateTests(unittest.TestCase):


    def test_atomic_links_and_bounded_cache(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            cache = root / "cache"
            cache.mkdir()
            entries = []
            for index in range(build_apple_resolver.MAX_CACHE_ENTRIES + 3):
                entry = cache / f"digest-{index}"
                entry.mkdir()
                entries.append(entry)

            build_apple_resolver.activate(root, entries[-1])
            self.assertTrue((root / "current").is_symlink())
            self.assertEqual(entries[-1].resolve(), (root / "current").resolve())
            build_apple_resolver.prune_cache(root, entries[-1])
            self.assertLessEqual(
                len([path for path in cache.iterdir() if path.is_dir()]),
                build_apple_resolver.MAX_CACHE_ENTRIES,
            )
            self.assertTrue(entries[-1].is_dir())

            sdk = root / "Simulator.sdk"
            sdk.mkdir()
            build_apple_resolver.publish_symlink(root / "sdk", sdk)
            self.assertEqual(sdk.resolve(), (root / "sdk").resolve())


    def test_path_redaction_covers_unresolved_symlink_alias(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / "target"
            target.mkdir()
            alias = root / "workspace"
            alias.symlink_to(target, target_is_directory=True)
            unresolved = alias / "repo"
            resolved = unresolved.resolve()
            redactions = gate._path_redactions(unresolved, "<repo>")
            for workspace in (unresolved, resolved):
                self.assertEqual(
                    "<repo>/logs/native.log",
                    gate._sanitize_text(
                        str(workspace / "logs/native.log"), redactions
                    ),
                )


    def test_valid_native_macos_report_passes(self) -> None:
        self.assertEqual([], gate.validate_report(valid_report(), "a" * 40, "macos"))

    def test_macos_sdk_pin_requires_its_exact_archive_size(self) -> None:
        pin = gate._load_sdk_pin(Path(".").resolve())
        self.assertEqual(163787681, pin["archive"]["size_bytes"])
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            pin_path = root / gate.SDK_PIN_PATH
            pin_path.parent.mkdir(parents=True)
            mutations = (
                ("missing", None),
                ("wrong", 163787680),
                ("boolean", True),
            )
            for label, size in mutations:
                candidate = json.loads(json.dumps(pin))
                if label == "missing":
                    candidate["archive"].pop("size_bytes")
                else:
                    candidate["archive"]["size_bytes"] = size
                pin_path.write_text(json.dumps(candidate), encoding="utf-8")
                with self.subTest(size=label), self.assertRaises(gate.GateError):
                    gate._load_sdk_pin(root)

    def test_validation_payload_binds_the_typed_text_digest(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            report_path = Path(directory) / "report.json"
            report_path.write_text('{"decision":"PASS"}\n', encoding="utf-8")
            validation = gate.validation_payload(report_path, "a" * 40, "macos", [])
            self.assertEqual(
                evidence_digest.text_evidence_digest(report_path).to_json(),
                validation["report_digest"],
            )
            original_digest = validation["report_digest"]

            report_path.write_text('{"decision":"FAIL"}\n', encoding="utf-8")
            self.assertNotEqual(
                original_digest,
                gate.validation_payload(
                    report_path, "a" * 40, "macos", ["REPORT:FAIL"]
                )["report_digest"],
            )

    def test_current_desktop_artifacts_bind_report_validation_and_logs(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            report_path = root / "report.json"
            validation_path = root / "validation.json"
            logs = root / "logs"
            logs.mkdir()
            report = valid_report()
            receipts = gate._log_receipts(report)
            for entry in report["logs"]:
                log_path = logs / f"{entry['id']}.log"
                output = receipts[entry["id"]]["output"]
                log_path.write_text(output, encoding="utf-8")
                entry["digest"] = evidence_digest.text_evidence_digest(log_path).to_json()
            report_path.write_text(
                json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8"
            )
            gate.atomic_json(
                validation_path,
                gate.validation_payload(report_path, "a" * 40, "macos", []),
            )
            self.assertEqual(
                [],
                gate.validate_current_desktop_artifacts(
                    report_path, validation_path, "a" * 40
                ),
            )

            resolver_log = logs / "resolver-test.log"
            resolver_log.write_text(
                "".join(
                    f"[ PASSED ] CASE: {case}\n"
                    for case in gate.EXPECTED_CASES["macos"][:7]
                )
                + "[ SKIPPED ] CASE: omitted-case\n",
                encoding="utf-8",
            )
            resolver_entry = next(
                entry for entry in report["logs"] if entry["id"] == "resolver-test"
            )
            resolver_entry["digest"] = evidence_digest.text_evidence_digest(
                resolver_log
            ).to_json()
            report_path.write_text(
                json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8"
            )
            gate.atomic_json(
                validation_path,
                gate.validation_payload(report_path, "a" * 40, "macos", []),
            )
            failures = gate.validate_current_desktop_artifacts(
                report_path, validation_path, "a" * 40
            )
            self.assertIn("LOG:PROCESS_MISMATCH", failures)
            self.assertIn("RESOLVER_TEST:CASE_INVENTORY", failures)
            self.assertIn("RESOLVER_TEST:NON_PASS_CASE", failures)
    def test_ios_report_is_not_a_current_qualification(self) -> None:
        self.assertIn(
            "REPORT:IOS_NOT_QUALIFIED",
            gate.validate_report(valid_report("ios-simulator"), "a" * 40, "ios-simulator"),
        )

    def test_rejects_unknown_schema_stale_revision_and_wrong_platform(self) -> None:
        report = valid_report()
        report["schema_version"] = 9
        report["revision"] = "b" * 40
        report["platform"] = {
            "system": "Linux",
            "release": "6.0",
            "machine": "x86_64",
            "runner_image": "linux",
            "runner_image_version": "1",
            "toolchain": report["platform"]["toolchain"],
        }
        failures = gate.validate_report(report, "a" * 40, "macos")
        self.assertIn("REPORT:UNKNOWN_SCHEMA", failures)
        self.assertIn("REPORT:STALE_REVISION", failures)
        self.assertIn("REPORT:NON_NATIVE_APPLE", failures)


    def test_ios_launch_retry_is_limited_to_empty_timeout(self) -> None:
        self.assertTrue(gate.retryable_ios_launch_timeout({
            "timed_out": True, "output": ""
        }))
        self.assertFalse(gate.retryable_ios_launch_timeout({
            "timed_out": True, "output": "[ TRACE ] CASE: 1 START\n"
        }))
        self.assertFalse(gate.retryable_ios_launch_timeout({
            "timed_out": False, "output": ""
        }))

    def test_ios_runtime_libraries_use_only_the_simulator_sdk_directory(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            runtime = root / "runtime/lib/ios_simulator_aarch64_cjnative"
            runtime.mkdir(parents=True)
            expected = runtime / "libcangjie-runtime.dylib"
            expected.write_bytes(b"runtime")
            (runtime / "libcangjie-std-core.dylib").write_bytes(b"std")
            host = root / "runtime/lib/darwin_aarch64_cjnative"
            host.mkdir(parents=True)
            (host / "libcangjie-runtime.dylib").write_bytes(b"host")
            libraries = gate.ios_runtime_libraries({"CANGJIE_HOME": str(root)})
            self.assertEqual(
                ["libcangjie-runtime.dylib", "libcangjie-std-core.dylib"],
                [path.name for path in libraries],
            )
            self.assertIn(expected, libraries)

    def test_rejects_skipped_timeout_and_fixture_not_bound(self) -> None:
        report = valid_report()
        test_process = command_receipt(
            report["resolver_test"]["command"],
            "".join(
                f"[ PASSED ] CASE: {case}\n"
                for case in gate.EXPECTED_CASES["macos"][:7]
            ) + "[ SKIPPED ] CASE: skipped\n",
        )
        test_process["timed_out"] = True
        report["resolver_test"] = test_process
        manifest = dict(report["resolver_manifest"])
        manifest["test_fixture"] = False
        report["resolver_manifest"] = manifest
        report["resolver_manifest_digest"] = gate._json_text_digest(manifest)
        failures = gate.validate_report(report, "a" * 40, "macos")
        self.assertIn("RESOLVER_TEST:TIMEOUT", failures)
        self.assertIn("RESOLVER_TEST:NON_PASS_CASE", failures)
        self.assertIn("REPORT:MANIFEST", failures)

    def test_rejects_duplicate_case_names_and_unbound_link_stub_source(self) -> None:
        report = valid_report()
        report["resolver_test"] = command_receipt(
            report["resolver_test"]["command"],
            "[ PASSED ] CASE: "
            + gate.EXPECTED_CASES["macos"][0]
            + "\n" * gate.EXPECTED_TESTS,
        )
        report["test_link_stub"]["source_digest"] = {
            "domain": evidence_digest.TEXT_EVIDENCE_DOMAIN,
            "sha256": "f" * 64,
        }
        failures = gate.validate_report(report, "a" * 40, "macos")
        self.assertIn("RESOLVER_TEST:CASE_INVENTORY", failures)
        self.assertIn("REPORT:TEST_LINK_STUB_SOURCE", failures)

    def test_rejects_untyped_sdk_archive_digest(self) -> None:
        report = valid_report()
        report["sdk"]["archive"] = {"domain": "raw", "sha256": gate.PINNED_SDK_ARCHIVE_SHA256}
        self.assertIn("REPORT:SDK_PIN", gate.validate_report(report, "a" * 40, "macos"))

    def test_resolver_error_summary_in_diagnostics_is_rejected(self) -> None:
        report = valid_report()
        report["resolver_test"]["diagnostics"] = "ERROR: 1\n"
        failures = gate.validate_report(report, "a" * 40, "macos")
        self.assertIn("RESOLVER_TEST:SUMMARY_FAILURE", failures)


if __name__ == "__main__":
    unittest.main()
