from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from tools import m7_027_linux_examples as gate


class M7027LinuxExamplesTest(unittest.TestCase):
    def test_checked_in_guide_and_sources_satisfy_static_contract(self) -> None:
        sources = gate.load_and_validate_sources()
        self.assertEqual(list(gate.SOURCE_NAMES), sorted(sources))
        gate.validate_guide(gate.GUIDE.read_text(encoding="utf-8"))

    def test_internal_import_and_inventory_drift_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.write_source_fixture(root)
            path = root / gate.SOURCE_NAMES[0]
            path.write_text(
                path.read_text(encoding="utf-8")
                + "import wirestack.internal.transport.*\n",
                encoding="utf-8",
            )
            with self.assertRaises(gate.ExampleGateError) as raised:
                gate.load_and_validate_sources(root)
            self.assertEqual("INTERNAL_IMPORT", raised.exception.code)

            path.write_text(gate.PACKAGE_DECLARATION + "\n", encoding="utf-8")
            (root / "unexpected.cj").write_text(
                gate.PACKAGE_DECLARATION + "\n", encoding="utf-8"
            )
            with self.assertRaises(gate.ExampleGateError) as inventory:
                gate.load_and_validate_sources(root)
            self.assertEqual("EXAMPLE_INVENTORY", inventory.exception.code)

    def test_marker_validation_rejects_missing_duplicate_reordered_and_skipped(self) -> None:
        valid = "\n".join(gate.EXPECTED_MARKERS) + "\n"
        gate.validate_markers(valid)
        for output in (
            "\n".join(gate.EXPECTED_MARKERS[:-1]),
            valid + gate.EXPECTED_MARKERS[-1] + "\n",
            "\n".join(reversed(gate.EXPECTED_MARKERS)),
            valid + "SKIPPED\n",
        ):
            with self.assertRaises(gate.ExampleGateError):
                gate.validate_markers(output)

    def test_platform_gate_rejects_other_os_cpu_and_musl(self) -> None:
        for values, code in (
            (("Darwin", "arm64", ""), "UNSUPPORTED_PLATFORM"),
            (("Linux", "aarch64", "glibc"), "UNSUPPORTED_PLATFORM"),
            (("Linux", "x86_64", "musl"), "UNSUPPORTED_LIBC"),
        ):
            with self.assertRaises(gate.ExampleGateError) as raised:
                gate.require_platform(*values)
            self.assertEqual(code, raised.exception.code)

    def test_output_is_tail_bounded(self) -> None:
        value = "a" * (gate.MAX_OUTPUT_CHARS + 37)
        self.assertEqual(gate.MAX_OUTPUT_CHARS, len(gate.bounded_output(value)))
        self.assertEqual("a" * gate.MAX_OUTPUT_CHARS, gate.bounded_output(value))

    def test_atomic_report_replaces_old_json(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "nested/report.json"
            path.parent.mkdir(parents=True)
            path.write_text("old", encoding="utf-8")
            gate.atomic_json(path, {"decision": "PASS"})
            self.assertEqual("PASS", json.loads(path.read_text(encoding="utf-8"))["decision"])
            self.assertEqual([], [item for item in path.parent.iterdir() if item != path])

    def test_atomic_report_preserves_old_file_when_replace_fails(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "report.json"
            path.write_text("old", encoding="utf-8")

            def fail_replace(_source: object, _target: object) -> None:
                raise OSError("injected replace failure")

            with self.assertRaises(OSError):
                gate.atomic_json(path, {"decision": "PASS"}, replace=fail_replace)
            self.assertEqual("old", path.read_text(encoding="utf-8"))
            self.assertEqual([path], list(path.parent.iterdir()))

    def test_guide_missing_topic_and_legacy_recommendation_fail_with_stable_codes(self) -> None:
        current = gate.GUIDE.read_text(encoding="utf-8")
        with self.assertRaises(gate.ExampleGateError) as missing:
            gate.validate_guide(current.replace(gate.GUIDE_TOPICS[0], "missing"))
        self.assertEqual("GUIDE_TOPIC", missing.exception.code)
        with self.assertRaises(gate.ExampleGateError) as legacy:
            gate.validate_guide(current + "\nsetGlobalTlsKit(provider)\n")
        self.assertEqual("LEGACY_RECOMMENDATION", legacy.exception.code)

    def test_consumer_manifest_uses_only_public_dependency(self) -> None:
        manifest = gate.consumer_manifest()
        self.assertIn("wirestack = { path =", manifest)
        self.assertNotIn("wirestack.internal", manifest)

    def test_tool_command_uses_hosted_path_without_local_wrapper(self) -> None:
        missing = Path("/definitely/missing/codex_cangjie_env")
        command = gate.tool_command(
            ["cjpm", "build"],
            Path("/tmp/consumer"),
            wrapper=missing,
            which=lambda name: "/usr/bin/cjpm" if name == "cjpm" else None,
        )
        self.assertEqual(["cjpm", "build"], command)
        with self.assertRaises(gate.ExampleGateError) as caught:
            gate.tool_command(
                ["cjpm", "build"],
                Path("/tmp/consumer"),
                wrapper=missing,
                which=lambda _name: None,
            )
        self.assertEqual("MISSING_TOOLCHAIN", caught.exception.code)

    @staticmethod
    def write_source_fixture(root: Path) -> None:
        root.mkdir(parents=True, exist_ok=True)
        for name in gate.SOURCE_NAMES:
            (root / name).write_text(gate.PACKAGE_DECLARATION + "\n", encoding="utf-8")


if __name__ == "__main__":
    unittest.main()
