from __future__ import annotations

from tools import evidence_digest

import tempfile
import tomllib
import unittest
from pathlib import Path
from unittest import mock

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
            f"[ PASSED ] CASE: {name}\n" for name in gate.EXPECTED_CASES[mode]
        ) + "FAILED: 0\nERROR: 0\n"
    return {
        "timed_out": False,
        "exit_code": 0,
        "output": output,
    }


def valid_report(mode: str = "macos") -> dict[str, object]:
    return {
        "schema_version": 1,
        "task_id": "M2-006",
        "revision": "abc",
        "mode": mode,
        "platform": {
            "system": "Darwin",
            "machine": "arm64",
            "toolchain": {"output": "Target: aarch64-apple-darwin\n"},
        },
        "decision": "PASS",
        "failures": [],
        "resolver_test": valid_process(mode),
        "resolver_manifest": {
            "platform": gate.MODES[mode],
            "private_runtime_abi": False,
            "test_fixture": True,
            "inputs": {"flags": gate.deployment_flags(gate.MODES[mode])},
        },
        "test_link_stub": {"test_only": True},
        "simulator": {
            "device_udid": "00000000-0000-0000-0000-000000000000",
            "runtime": "com.apple.CoreSimulator.SimRuntime.iOS-26-2",
            "probe_sha256": "a" * 64,
            "bundle_source_probe_sha256": "a" * 64,
            "bundle_probe_sha256": "b" * 64,
            "install": {"timed_out": False, "exit_code": 0},
            "runtime_libraries": [{
                "path": "Frameworks/libcangjie-runtime.dylib",
                "sha256": "c" * 64,
            }],
            "probe_compile": {"command": ["cjc", "--target", gate.IOS_TARGET]},
            "launch_attempts": [valid_process("ios-simulator")],
            "launch_recovery": [],
        } if mode == "ios-simulator" else None,
    }


class M2006AppleResolverGateTests(unittest.TestCase):
    def test_target_native_libraries_propagate_to_path_consumers(self) -> None:
        manifest = tomllib.loads(Path("cjpm.toml").read_text(encoding="utf-8"))
        targets = manifest["target"]

        for target, selected in (
            ("aarch64-apple-darwin", "macos-arm64"),
            ("arm64-apple-ios11-simulator", "ios-simulator-arm64"),
        ):
            configuration = targets[target]
            self.assertEqual(
                {"path": gate.resolver_ffi_path(selected)},
                configuration["ffi"]["c"]["wirestack_resolver"],
            )
            self.assertNotIn("wirestack_m2_006_tls_link_stub", configuration["ffi"]["c"])
            self.assertNotIn("-lwirestack_", configuration["link-option"])
        build_driver = Path("tools/build_native_dependencies.py").read_text(
            encoding="utf-8"
        )
        self.assertIn("required_resolvers = [selected_resolver]", build_driver)
        self.assertIn("required_resolvers.append", build_driver)
        self.assertIn("CJPM validates every Darwin target FFI table", build_driver)
        apple_builder = Path("tools/build_apple_resolver.py").read_text(
            encoding="utf-8"
        )
        self.assertIn("fcntl.LOCK_EX", apple_builder)

    def test_ios_target_uses_builder_published_sysroot(self) -> None:
        manifest = tomllib.loads(Path("cjpm.toml").read_text(encoding="utf-8"))
        option = manifest["target"][gate.IOS_TARGET]["override-compile-option"]
        self.assertEqual(
            "--sysroot ./target/native/resolver/ios-simulator-arm64/sdk",
            option,
        )
        self.assertNotIn("WIRESTACK_IOS_SIMULATOR_SYSROOT", option)

    def test_sdk_discovery_uses_the_configured_xcrun(self) -> None:
        commands = []

        def capture(command: list[str], *, cwd=None) -> str:
            commands.append(command)
            return "/configured/Simulator.sdk\n"

        with mock.patch.object(
            build_apple_resolver, "find_tool", return_value="/configured/xcrun"
        ), mock.patch.object(build_apple_resolver, "run", side_effect=capture):
            self.assertEqual(
                "/configured/Simulator.sdk",
                build_apple_resolver.xcrun_query(
                    "iphonesimulator", "--show-sdk-path"
                ),
            )
        self.assertEqual(
            [["/configured/xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"]],
            commands,
        )

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

    def test_cancellation_waits_for_native_job_readiness(self) -> None:
        for path in (
            Path("tools/gates/probes/m2_006_apple_resolver.cj"),
            Path("src/internal/resolver/apple_system_resolver_test.cj"),
        ):
            source = path.read_text(encoding="utf-8")
            start = source.index("let resolving = spawn")
            cancel = source.index("source.cancel()", start)
            setup = source[start:cancel]
            self.assertIn("metrics.runningJobs == 1", setup)
            self.assertNotIn("sleep(20 * Duration.millisecond)", setup)

    def test_gate_injects_test_stub_only_into_selected_workspace_target(self) -> None:
        original = Path("cjpm.toml").read_text(encoding="utf-8")
        self.assertNotIn("wirestack_m2_006_tls_link_stub", original)
        for selected in gate.MODES.values():
            bound = gate.bind_test_link_stub(original, selected)
            self.assertEqual(1, bound.count("wirestack_m2_006_tls_link_stub"))

    def test_valid_native_macos_report_passes(self) -> None:
        self.assertEqual([], gate.validate_report(valid_report(), "abc", "macos"))

    def test_validation_payload_binds_the_exact_native_report(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            report_path = Path(directory) / "report.json"
            report_path.write_text('{"decision":"PASS"}\n', encoding="utf-8")
            validation = gate.validation_payload(report_path, "abc", "macos", [])
            self.assertEqual(evidence_digest.text_evidence_sha256(report_path), validation["report_sha256"])
            original_digest = validation["report_sha256"]

            report_path.write_text('{"decision":"FAIL"}\n', encoding="utf-8")
            self.assertNotEqual(
                original_digest,
                gate.validation_payload(
                    report_path, "abc", "macos", ["REPORT:FAIL"]
                )["report_sha256"],
            )

    def test_valid_native_ios_simulator_report_passes(self) -> None:
        self.assertEqual(
            [],
            gate.validate_report(valid_report("ios-simulator"), "abc", "ios-simulator"),
        )

    def test_ios_probe_accepts_cjc_equals_form_target_argument(self) -> None:
        report = valid_report("ios-simulator")
        report["simulator"]["probe_compile"]["command"] = [
            "cjc", f"--target={gate.IOS_TARGET}"
        ]
        self.assertEqual(
            [], gate.validate_report(report, "abc", "ios-simulator")
        )

    def test_rejects_unknown_schema_stale_revision_and_wrong_platform(self) -> None:
        report = valid_report()
        report["schema_version"] = 9
        report["revision"] = "old"
        report["platform"] = {"system": "Linux", "machine": "x86_64"}
        failures = gate.validate_report(report, "abc", "macos")
        self.assertIn("REPORT:UNKNOWN_SCHEMA", failures)
        self.assertIn("REPORT:STALE_REVISION", failures)
        self.assertIn("REPORT:NON_NATIVE_APPLE", failures)

    def test_rejects_cross_compile_only_and_missing_simulator_evidence(self) -> None:
        report = valid_report("ios-simulator")
        report["simulator"] = None
        report["resolver_test"] = {
            "timed_out": False,
            "exit_code": 0,
            "output": "cjpm test success\n",
        }
        failures = gate.validate_report(report, "abc", "ios-simulator")
        self.assertIn("REPORT:SIMULATOR_MISSING", failures)
        self.assertIn("RESOLVER_TEST:CASE_COUNT", failures)

    def test_rejects_incomplete_or_changed_simulator_probe(self) -> None:
        report = valid_report("ios-simulator")
        report["simulator"] = {
            "device_udid": "",
            "runtime": "macOS",
            "probe_sha256": "a" * 64,
            "bundle_source_probe_sha256": "b" * 64,
            "bundle_probe_sha256": "b" * 64,
            "install": {"timed_out": False, "exit_code": 1},
            "runtime_libraries": [],
        }
        failures = gate.validate_report(report, "abc", "ios-simulator")
        self.assertIn("REPORT:SIMULATOR_DEVICE", failures)
        self.assertIn("REPORT:SIMULATOR_RUNTIME", failures)
        self.assertIn("REPORT:SIMULATOR_PROBE", failures)

    def test_ios_uses_single_process_app_launch_and_fixed_deployment_target(self) -> None:
        command = gate.ios_launch_command("device")
        self.assertEqual("launch", command[2])
        self.assertNotIn("spawn", command)
        self.assertIn("--console", command)
        self.assertIn("-rpath @executable_path/Frameworks", gate.ios_link_options())
        probe = Path("tools/gates/probes/m2_006_apple_resolver.cj").read_text(encoding="utf-8")
        self.assertIn("import std.env.exit", probe)
        self.assertIn("exit(if (failures == 0)", probe)
        self.assertIn("wirestack_m2_006_probe_trace(caseId, 0)", probe)
        self.assertIn("Deadline.after(5 * Duration.second)", probe)
        self.assertEqual(
            ["-mios-simulator-version-min=11.0"],
            gate.deployment_flags("ios-simulator-arm64"),
        )
        self.assertEqual(
            ["-mmacosx-version-min=12.0"],
            gate.deployment_flags("macos-arm64"),
        )

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
        report["resolver_test"] = {
            "timed_out": True,
            "exit_code": 0,
            "output": "[ PASSED ] CASE:\n" * 7 + "[ SKIPPED ] CASE:\n",
        }
        manifest = dict(report["resolver_manifest"])
        manifest["test_fixture"] = False
        report["resolver_manifest"] = manifest
        failures = gate.validate_report(report, "abc", "macos")
        self.assertIn("RESOLVER_TEST:TIMEOUT", failures)
        self.assertIn("RESOLVER_TEST:NON_PASS_CASE", failures)
        self.assertIn("REPORT:FIXTURE_NOT_BOUND", failures)

    def test_rejects_duplicate_case_names_and_unbound_probe_copy(self) -> None:
        report = valid_report("ios-simulator")
        report["resolver_test"] = {
            "timed_out": False,
            "exit_code": 0,
            "output": "[ PASSED ] CASE: resolves localhost\n" * gate.EXPECTED_TESTS,
        }
        report["simulator"]["bundle_source_probe_sha256"] = "c" * 64
        failures = gate.validate_report(report, "abc", "ios-simulator")
        self.assertIn("RESOLVER_TEST:CASE_INVENTORY", failures)
        self.assertIn("REPORT:SIMULATOR_PROBE", failures)

    def test_rejects_incomplete_duplicate_or_failed_simulator_trace(self) -> None:
        for output in (
            "[ TRACE ] CASE: 1 START\n[ TRACE ] CASE: 1 PASS\n",
            valid_process("ios-simulator")["output"] + "[ TRACE ] CASE: 8 PASS\n",
            str(valid_process("ios-simulator")["output"]).replace(
                "[ TRACE ] CASE: 8 PASS", "[ TRACE ] CASE: 8 FAIL"
            ),
        ):
            report = valid_report("ios-simulator")
            report["resolver_test"]["output"] = output
            failures = gate.validate_report(report, "abc", "ios-simulator")
            self.assertTrue(
                "RESOLVER_TEST:CASE_COUNT" in failures or
                "RESOLVER_TEST:CASE_INVENTORY" in failures
            )
        self.assertIn("RESOLVER_TEST:NON_PASS_CASE", failures)

    def test_retry_requires_empty_timeout_and_complete_recovery(self) -> None:
        report = valid_report("ios-simulator")
        report["simulator"]["launch_attempts"] = [
            {"timed_out": True, "exit_code": None, "output": "partial"},
            valid_process("ios-simulator"),
        ]
        report["simulator"]["launch_recovery"] = []
        failures = gate.validate_report(report, "abc", "ios-simulator")
        self.assertIn("REPORT:SIMULATOR_RECOVERY", failures)

        report["simulator"]["launch_attempts"][0]["output"] = ""
        report["simulator"]["launch_recovery"] = [
            {"command": ["xcrun", "simctl", operation], "timed_out": False,
             "exit_code": 0}
            for operation in ("terminate", "shutdown", "boot", "bootstatus")
        ]
        self.assertEqual(
            [], gate.validate_report(report, "abc", "ios-simulator")
        )

    def test_atomic_json_replaces_complete_document_without_temp_residue(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "report.json"
            gate.atomic_json(output, {"status": "PASS"})
            self.assertEqual('{\n  "status": "PASS"\n}\n', output.read_text())
            self.assertEqual([output], list(Path(directory).iterdir()))


if __name__ == "__main__":
    unittest.main()
