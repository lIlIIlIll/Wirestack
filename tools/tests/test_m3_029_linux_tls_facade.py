from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from tools import m3_029_linux_tls_facade as gate


class M3029LinuxTlsFacadeTest(unittest.TestCase):
    def test_platform_gate_fails_closed(self) -> None:
        with self.assertRaisesRegex(gate.FacadeGateError, "requires Linux x86_64"):
            gate.require_linux("Darwin", "arm64")

    def test_smoke_output_requires_both_real_and_public_markers(self) -> None:
        gate.validate_smoke_output("HTTPS_CLIENT_SERVER=PASS\nPUBLIC_TLS_FACADE=PASS\n")
        with self.assertRaisesRegex(gate.FacadeGateError, "PUBLIC_TLS_FACADE"):
            gate.validate_smoke_output("HTTPS_CLIENT_SERVER=PASS\n")

    def test_atomic_report_replaces_old_content_with_valid_json(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "nested/report.json"
            path.parent.mkdir(parents=True)
            path.write_text("stale", encoding="utf-8")
            gate.atomic_json(path, {"decision": "PASS", "skippedAsPass": False})
            self.assertEqual("PASS", json.loads(path.read_text(encoding="utf-8"))["decision"])
            self.assertEqual([], list(path.parent.glob("tmp*")))

    def test_consumer_manifest_uses_public_dependency_without_internal_packages(self) -> None:
        manifest = gate.consumer_manifest()
        self.assertIn("wirestack = { path =", manifest)
        self.assertNotIn("wirestack.internal", manifest)

    def test_fixture_package_rewrite_is_exactly_one_source_declaration(self) -> None:
        source = (gate.ROOT / "tools/release_smoke/main.cj").read_text(encoding="utf-8")
        self.assertEqual(1, source.count("package wirestack_release_smoke"))


if __name__ == "__main__":
    unittest.main()
