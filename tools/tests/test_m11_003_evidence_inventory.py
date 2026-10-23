from __future__ import annotations

import json
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
TASK = ROOT / "tools/tasks/M11-003.json"
EVIDENCE = ROOT / "docs/evidence/M11-003"
HISTORICAL = EVIDENCE / "historical"


class M11003EvidenceInventoryTests(unittest.TestCase):
    """Bind every file the M11-003 owner PR changed into the task evidence inventory."""

    def manifest(self) -> dict[str, object]:
        return json.loads(TASK.read_text(encoding="utf-8"))

    def test_owner_pr_changes_are_all_bound(self) -> None:
        # The merged owner PR #206 is the reviewed candidate this task must hash. Its
        # non-evidence, non-generated files must all appear as source inputs.
        result = subprocess.run(
            ["git", "show", "--name-only", "--format=", "67f06cb079bf0de9502121c3481d554c690b92eb"],
            cwd=ROOT, capture_output=True, text=True, check=False)
        if result.returncode != 0:
            self.skipTest("owner PR commit is not available in this clone")
        changed = [
            name for name in result.stdout.split()
            if not name.startswith("docs/evidence/M11-003/")
            and not name.startswith("docs/api/generated/")
        ]
        self.assertIn("src/internal/http1/proxy_literal_connect_deadline_test.cj", changed)
        self.assertIn(".gitignore", changed)
        sources = set(self.manifest()["source_paths"])
        self.assertEqual([], sorted(name for name in changed if name not in sources))

    def test_review_regressions_are_bound_and_present(self) -> None:
        manifest = self.manifest()
        sources = set(manifest["source_paths"])
        allowed = set(manifest["allowed_paths"])
        for relative in (
            ".gitignore",
            "src/internal/http1/proxy_literal_connect_deadline_test.cj",
            "src/http/websocket.cj",
            "src/http/websocket_test.cj",
            "src/http/client.cj",
            "src/http/facade_test.cj",
            "src/http/upgrade_terminal_test.cj",
            "src/internal/connector/happy_eyeballs.cj",
            "src/internal/connector/happy_eyeballs_test.cj",
            "tools/tests/test_m11_003_evidence_inventory.py",
        ):
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
        self.assertEqual("docs/evidence/M11-003/historical",
            current["status_detail"]["historical_receipts"]["directory"])
        self.assertFalse(
            current["status_detail"]["historical_receipts"]["citable_as_current_evidence"])
        for name in ("verification.json", "task-gate.json", "workspace.json",
            "public-api.json", "installed/report.json", "installed-sdk113/report.json",
            "docs/report.json", "scenario-matrix.md"):
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
