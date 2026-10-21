from __future__ import annotations

import io
import json
import os
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
            relative_root = Path(os.path.relpath(root, Path.cwd()))

            historical_inventory_path = root / api_inventory.HISTORICAL_INVENTORY
            historical_report_path = root / api_inventory.HISTORICAL_REPORT
            for destination, source in (
                (historical_inventory_path, ROOT / api_inventory.HISTORICAL_INVENTORY),
                (historical_report_path, ROOT / api_inventory.HISTORICAL_REPORT),
            ):
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, destination)
            original_historical_inventory = historical_inventory_path.read_bytes()
            original_historical_report = historical_report_path.read_bytes()

            with self.assertRaisesRegex(
                api_inventory.PublicApiInventoryError,
                "sealed historical M7-032 API artifacts",
            ):
                api_inventory.reject_sealed_write_paths(
                    root,
                    ROOT / api_inventory.HISTORICAL_INVENTORY,
                    ROOT / api_inventory.HISTORICAL_REPORT,
                )

            m7_inventory_path = root / api_inventory.DEFAULT_INVENTORY
            m7_report_path = root / api_inventory.DEFAULT_REPORT
            m11_inventory_relative = Path(
                "docs/api/baselines/wirestack-linux-pre1-m11-003.json"
            )
            m11_report_relative = Path("docs/evidence/M11-003/public-api.json")
            m11_inventory_path = root / m11_inventory_relative
            m11_report_path = root / m11_report_relative

            output = io.StringIO()
            with redirect_stdout(output):
                result = api_inventory.main([
                    "--root", str(relative_root), "--write", "--json"
                ])
            self.assertEqual(0, result)
            m7_report = json.loads(output.getvalue())
            self.assertEqual("M7-032", m7_report["taskId"])
            self.assertEqual("PASS", m7_report["status"])
            original_m7_inventory = m7_inventory_path.read_bytes()
            original_m7_report = m7_report_path.read_bytes()
            self.assertEqual(
                original_historical_inventory,
                historical_inventory_path.read_bytes(),
            )
            self.assertEqual(
                original_historical_report,
                historical_report_path.read_bytes(),
            )

            output = io.StringIO()
            with redirect_stdout(output):
                result = api_inventory.main([
                    "--root", str(relative_root),
                    "--inventory", str(m11_inventory_relative),
                    "--report", str(m11_report_relative),
                    "--write", "--json",
                ])
            self.assertEqual(0, result)
            m11_report = json.loads(output.getvalue())
            self.assertEqual(
                m7_report["inventorySha256"],
                m11_report["inventorySha256"],
            )
            self.assertEqual(
                original_m7_inventory, m7_inventory_path.read_bytes()
            )
            self.assertEqual(original_m7_report, m7_report_path.read_bytes())

            output = io.StringIO()
            with redirect_stdout(output):
                result = api_inventory.main([
                    "--root", str(relative_root),
                    "--inventory", str(api_inventory.HISTORICAL_INVENTORY),
                    "--report", str(api_inventory.HISTORICAL_REPORT),
                    "--write", "--json",
                ])
            self.assertEqual(1, result)
            protected_write_failure = json.loads(output.getvalue())
            self.assertEqual("FAIL", protected_write_failure["status"])
            self.assertIn(
                "sealed historical M7-032 API artifacts",
                protected_write_failure["error"],
            )
            self.assertEqual(
                original_historical_inventory,
                historical_inventory_path.read_bytes(),
            )
            self.assertEqual(
                original_historical_report,
                historical_report_path.read_bytes(),
            )
            original_m11_inventory = m11_inventory_path.read_bytes()
            original_m11_report = m11_report_path.read_bytes()
            for inventory_path, report_path in (
                (m11_inventory_path, None),
                (None, m11_report_path),
            ):
                with self.assertRaisesRegex(
                    api_inventory.PublicApiInventoryError,
                    "must be provided together",
                ):
                    api_inventory.validate(root, inventory_path, report_path)
            m7_report_path.write_bytes(b'{"sentinel":"m7-report"}\n')
            m7_report_sentinel = m7_report_path.read_bytes()

            m11_inventory_path.write_bytes(b'{"sentinel":"m11-inventory"}\n')
            m11_inventory_sentinel = m11_inventory_path.read_bytes()
            output = io.StringIO()
            with redirect_stdout(output):
                result = api_inventory.main([
                    "--root", str(relative_root),
                    "--inventory", str(m11_inventory_relative),
                    "--write", "--json",
                ])
            self.assertEqual(1, result)
            inventory_only_failure = json.loads(output.getvalue())
            self.assertEqual("FAIL", inventory_only_failure["status"])
            self.assertIn(
                "must be provided together",
                inventory_only_failure["error"],
            )
            self.assertEqual(
                original_m7_inventory, m7_inventory_path.read_bytes()
            )
            self.assertEqual(
                m7_report_sentinel, m7_report_path.read_bytes()
            )
            self.assertEqual(
                m11_inventory_sentinel, m11_inventory_path.read_bytes()
            )
            self.assertEqual(
                original_m11_report, m11_report_path.read_bytes()
            )

            m11_inventory_path.write_bytes(original_m11_inventory)
            m7_inventory_path.write_bytes(b'{"sentinel":"m7-inventory"}\n')
            m7_inventory_sentinel = m7_inventory_path.read_bytes()
            m11_report_path.write_bytes(b'{"sentinel":"m11-report"}\n')
            m11_report_sentinel = m11_report_path.read_bytes()
            output = io.StringIO()
            with redirect_stdout(output):
                result = api_inventory.main([
                    "--root", str(relative_root),
                    "--report", str(m11_report_relative),
                    "--write", "--json",
                ])
            self.assertEqual(1, result)
            report_only_failure = json.loads(output.getvalue())
            self.assertEqual("FAIL", report_only_failure["status"])
            self.assertIn(
                "must be provided together",
                report_only_failure["error"],
            )
            self.assertEqual(
                m7_inventory_sentinel, m7_inventory_path.read_bytes()
            )
            self.assertEqual(
                m7_report_sentinel, m7_report_path.read_bytes()
            )
            self.assertEqual(
                original_m11_inventory, m11_inventory_path.read_bytes()
            )
            self.assertEqual(
                m11_report_sentinel, m11_report_path.read_bytes()
            )

            m7_inventory_path.write_bytes(original_m7_inventory)
            m7_report_path.write_bytes(original_m7_report)
            m11_report_path.write_bytes(original_m11_report)
            m11_inventory_path.write_bytes(original_m11_inventory)

            api_inventory.write_json(
                m7_report_path,
                {**m7_report, "inventorySha256": "0" * 64},
            )
            output = io.StringIO()
            with redirect_stdout(output):
                result = api_inventory.main([
                    "--root", str(relative_root), "--json"
                ])
            self.assertEqual(1, result)
            failure = json.loads(output.getvalue())
            self.assertEqual("FAIL", failure["status"])
            self.assertIn(
                "committed public API report is stale", failure["error"]
            )
            output = io.StringIO()
            with redirect_stdout(output):
                result = api_inventory.main([
                    "--root", str(relative_root),
                    "--inventory", str(m11_inventory_relative),
                    "--report", str(m11_report_relative),
                    "--json",
                ])
            self.assertEqual(0, result)
            self.assertEqual("PASS", json.loads(output.getvalue())["status"])

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
