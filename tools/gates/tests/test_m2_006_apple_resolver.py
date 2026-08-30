from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from tools.gates import m2_006_apple_resolver as gate


def valid_process() -> dict[str, object]:
    return {
        "timed_out": False,
        "exit_code": 0,
        "output": "[ PASSED ] CASE:\n" * gate.EXPECTED_TESTS + "FAILED: 0\nERROR: 0\n",
    }


def valid_report(mode: str = "macos") -> dict[str, object]:
    return {
        "schema_version": 1,
        "task_id": "M2-006",
        "revision": "abc",
        "mode": mode,
        "platform": {"system": "Darwin"},
        "decision": "PASS",
        "failures": [],
        "resolver_test": valid_process(),
        "resolver_manifest": {
            "platform": gate.MODES[mode],
            "private_runtime_abi": False,
            "test_fixture": True,
        },
        "test_link_stub": {"test_only": True},
        "simulator": {
            "device_udid": "00000000-0000-0000-0000-000000000000",
            "runtime": "com.apple.CoreSimulator.SimRuntime.iOS-26-2",
            "probe_sha256": "a" * 64,
            "bundle_probe_sha256": "b" * 64,
            "install": {"timed_out": False, "exit_code": 0},
        } if mode == "ios-simulator" else None,
    }


class M2006AppleResolverGateTests(unittest.TestCase):
    def test_valid_native_macos_report_passes(self) -> None:
        self.assertEqual([], gate.validate_report(valid_report(), "abc", "macos"))

    def test_valid_native_ios_simulator_report_passes(self) -> None:
        self.assertEqual(
            [],
            gate.validate_report(valid_report("ios-simulator"), "abc", "ios-simulator"),
        )

    def test_rejects_unknown_schema_stale_revision_and_wrong_platform(self) -> None:
        report = valid_report()
        report["schema_version"] = 9
        report["revision"] = "old"
        report["platform"] = {"system": "Linux"}
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
            "bundle_probe_sha256": "b" * 64,
            "install": {"timed_out": False, "exit_code": 1},
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
        source = Path(gate.__file__).read_text(encoding="utf-8")
        self.assertIn('"--static"', source)
        self.assertEqual(
            ["-mios-simulator-version-min=17.5"],
            gate.deployment_flags("ios-simulator-arm64"),
        )
        self.assertEqual([], gate.deployment_flags("macos-arm64"))

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

    def test_atomic_json_replaces_complete_document_without_temp_residue(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "report.json"
            gate.atomic_json(output, {"status": "PASS"})
            self.assertEqual('{\n  "status": "PASS"\n}\n', output.read_text())
            self.assertEqual([output], list(Path(directory).iterdir()))


if __name__ == "__main__":
    unittest.main()
