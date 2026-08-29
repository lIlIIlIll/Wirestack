from __future__ import annotations

import json
import re
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))

import m7_032_public_api_inventory as api_inventory  # noqa: E402
PUBLIC_PACKAGES = {"wirestack", "wirestack.http", "wirestack.tls"}
PACKAGE_RE = re.compile(r"(?m)^package\s+([A-Za-z_][A-Za-z0-9_.]*)\s*$")
PUBLIC_INTERNAL_RE = re.compile(
    r"(?m)^\s*public\s+(?:class|struct|interface|enum|func|prop|let|var|type)\b[^\n]*"
    r"wirestack\.internal\."
)


class M7032PublicApiContractTests(unittest.TestCase):
    def read(self, relative: str) -> str:
        return (ROOT / relative).read_text(encoding="utf-8")

    def test_task_manifest_has_no_long_running_command(self) -> None:
        manifest = json.loads(self.read("tools/tasks/M7-032.json"))
        self.assertFalse(manifest["long_running_gate"])
        self.assertTrue(manifest["acceptance_commands"])
        self.assertTrue(all(not item["long_running"] for item in manifest["acceptance_commands"]))
        flattened = " ".join(
            argument
            for item in manifest["acceptance_commands"]
            for argument in item["argv"]
        )
        self.assertNotIn("86400", flattened)
        self.assertNotIn("check-long", flattened)

    def test_public_package_sources_do_not_spell_internal_types_in_declarations(self) -> None:
        violations: list[str] = []
        for path in sorted((ROOT / "src").rglob("*.cj")):
            text = path.read_text(encoding="utf-8")
            package = PACKAGE_RE.search(text)
            if package is None or package.group(1) not in PUBLIC_PACKAGES:
                continue
            if PUBLIC_INTERNAL_RE.search(text):
                violations.append(path.relative_to(ROOT).as_posix())
        self.assertEqual([], violations)

    def test_adr_explicitly_rejects_compatibility_shims(self) -> None:
        adr = self.read("docs/architecture/adr/0006-public-contract-ownership.md")
        self.assertIn("No compatibility alias or\nmigration shim is added", adr)
        self.assertIn("source, API, ABI, or semantic compatibility", adr)

    def test_m7_031_depends_on_m7_032(self) -> None:
        backlog = self.read("docs/planning/implementation-backlog.md")
        row = next(line for line in backlog.splitlines() if line.startswith("| M7-031 |"))
        self.assertIn("M7-032", row.split("|")[5])

    def test_current_inventory_has_only_public_alias_targets(self) -> None:
        inventory = api_inventory.build_inventory(ROOT)
        self.assertEqual("NOT_EVALUATED_PRE_1_0", inventory["compatibilityPolicy"])
        self.assertTrue(inventory["resolvedAliases"])
        self.assertTrue(all(
            item["targetPackage"] in PUBLIC_PACKAGES
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
            with self.assertRaisesRegex(
                api_inventory.PublicApiInventoryError,
                "committed public API inventory is stale",
            ):
                api_inventory.validate(ROOT, inventory_path, report_path)


if __name__ == "__main__":
    unittest.main()
