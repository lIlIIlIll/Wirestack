from __future__ import annotations

import io
import json
import shutil
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))

import m7_032_public_api_inventory as api_inventory  # noqa: E402


class M7032PublicApiContractTests(unittest.TestCase):

    def test_current_inventory_has_only_public_alias_targets(self) -> None:
        inventory = api_inventory.build_inventory(ROOT)
        self.assertTrue(all(
            item["targetPackage"] in api_inventory.PUBLIC_PACKAGES
            for item in inventory["resolvedAliases"]
        ))

    def test_cli_defaults_to_m7_pair_and_preserves_explicit_m11_pair(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory(
            prefix="wirestack-m7-032-api-"
        ) as directory:
            root = Path(directory)
            shutil.copy2(ROOT / "cjpm.toml", root / "cjpm.toml")
            shutil.copytree(ROOT / "src", root / "src")

            output = io.StringIO()
            with redirect_stdout(output):
                result = api_inventory.main(
                    ["--root", str(root), "--write", "--json"]
                )
            self.assertEqual(0, result)
            m7_report = json.loads(output.getvalue())
            self.assertEqual("M7-032", m7_report["taskId"])
            self.assertEqual("PASS", m7_report["status"])
            m7_report_path = (
                root / "docs/evidence/M7-032/linux_x86_64/public-api.json"
            )
            original_m7_report = m7_report_path.read_bytes()

            output = io.StringIO()
            with redirect_stdout(output):
                result = api_inventory.main([
                    "--root", str(root),
                    "--inventory",
                    "docs/api/baselines/wirestack-linux-pre1-m11-001.json",
                    "--report",
                    "docs/evidence/M11-001/public-api.json",
                    "--write", "--json",
                ])
            self.assertEqual(0, result)
            m11_report = json.loads(output.getvalue())
            self.assertEqual(m7_report["inventorySha256"], m11_report["inventorySha256"])
            self.assertEqual(original_m7_report, m7_report_path.read_bytes())

            api_inventory.write_json(
                m7_report_path,
                {**m7_report, "inventorySha256": "0" * 64},
            )
            output = io.StringIO()
            with redirect_stdout(output):
                result = api_inventory.main(["--root", str(root), "--json"])
            self.assertEqual(1, result)
            failure = json.loads(output.getvalue())
            self.assertEqual("FAIL", failure["status"])
            self.assertIn(
                "committed public API report is stale", failure["error"]
            )

    def test_stale_inventory_is_rejected_without_compatibility_verdict(self) -> None:
        inventory = api_inventory.build_inventory(ROOT)
        with tempfile.TemporaryDirectory(prefix="wirestack-m7-032-api-") as directory:
            inventory_path = Path(directory) / "inventory.json"
            report_path = Path(directory) / "report.json"
            api_inventory.write_json(inventory_path, inventory)
            api_inventory.write_json(
                report_path,
                api_inventory.build_report(inventory_path, inventory),
            )
            inventory["declarations"] = inventory["declarations"][:-1]
            api_inventory.write_json(inventory_path, inventory)
            with self.assertRaises(api_inventory.PublicApiInventoryError):
                api_inventory.validate(ROOT, inventory_path, report_path)


if __name__ == "__main__":
    unittest.main()
