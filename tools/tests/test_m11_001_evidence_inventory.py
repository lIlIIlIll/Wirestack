from __future__ import annotations

import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
TASK = ROOT / "tools/tasks/M11-001.json"
EVIDENCE = ROOT / "docs/evidence/M11-001"
HISTORICAL = EVIDENCE / "historical"


class M11001EvidenceInventoryTests(unittest.TestCase):
    """Bound every production file the M11-001 owner PR changed into the task evidence."""

    def manifest(self) -> dict[str, object]:
        return json.loads(TASK.read_text(encoding="utf-8"))

    def test_changed_production_files_are_hashed_source_inputs(self) -> None:
        manifest = self.manifest()
        allowed = set(manifest["allowed_paths"])
        sources = set(manifest["source_paths"])
        required = {
            "src/http/server.cj",
            "src/internal/http2/server_connection.cj",
            "src/internal/http_resource_budget.cj",
        }
        self.assertLessEqual(required, sources)
        self.assertLessEqual(required, allowed)
        for relative in sorted(sources):
            self.assertTrue((ROOT / relative).is_file(), relative)

    def test_changed_production_tests_are_bound_and_present(self) -> None:
        manifest = self.manifest()
        allowed = set(manifest["allowed_paths"])
        sources = set(manifest["source_paths"])
        tests = {
            "src/internal/http_resource_budget_test.cj",
            "src/internal/http2/server_mapping_test.cj",
            "src/internal/http2/write_scheduler_test.cj",
            "src/http/facade_test.cj",
        }
        for relative in sorted(tests):
            self.assertIn(relative, sources)
            self.assertIn(relative, allowed)
            self.assertTrue((ROOT / relative).is_file(), relative)

    def test_every_source_path_is_an_allowed_path(self) -> None:
        manifest = self.manifest()
        allowed = set(manifest["allowed_paths"])
        for relative in manifest["source_paths"]:
            covered = any(
                relative == entry or relative.startswith(entry.rstrip("/") + "/")
                for entry in allowed
            )
            self.assertTrue(covered, f"{relative} is not an allowed path")

    def test_historical_receipts_are_not_current_evidence(self) -> None:
        self.assertTrue((HISTORICAL / "README.md").is_file())
        current = json.loads((EVIDENCE / "verification.json").read_text(encoding="utf-8"))
        self.assertEqual("BLOCKED", current["status"])
        self.assertEqual("BLOCKED", current["acceptance_status"])
        self.assertFalse(current["candidate_committed"])
        self.assertEqual(
            "docs/evidence/M11-001/historical",
            current["status_detail"]["historical_receipts"]["directory"],
        )
        self.assertFalse(
            current["status_detail"]["historical_receipts"]["citable_as_current_evidence"]
        )
        for name in ("verification-2026-10-08.json", "task-gate.json"):
            self.assertTrue((HISTORICAL / name).is_file(), name)

    def test_no_current_receipt_claims_a_pass(self) -> None:
        for path in sorted(EVIDENCE.rglob("*")):
            if not path.is_file() or path == EVIDENCE / "README.md":
                continue
            if HISTORICAL in path.parents:
                continue
            if path.suffix == ".json":
                payload = json.loads(path.read_text(encoding="utf-8"))
                self.assertNotEqual("PASS", payload.get("status"), path)
                self.assertNotEqual("PASS", payload.get("acceptance_status"), path)


if __name__ == "__main__":
    unittest.main()
