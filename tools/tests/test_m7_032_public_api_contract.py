from __future__ import annotations

import sys
import tempfile
import unittest
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
