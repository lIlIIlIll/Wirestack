import copy
import json
import tempfile
import unittest
from pathlib import Path

from tools.validate_m7_019_linux_audit import AuditError, DEFAULT_AUDIT, validate_audit


class M7019LinuxAuditTest(unittest.TestCase):
    def setUp(self) -> None:
        self.audit = json.loads(DEFAULT_AUDIT.read_text(encoding="utf-8"))

    def validate_changed(self, audit: dict) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "audit.data"
            path.write_text(json.dumps(audit), encoding="utf-8")
            validate_audit(path, verify_current_sources=False)

    def test_canonical_audit_passes(self) -> None:
        validate_audit(verify_current_sources=False)

    def test_strict_validation_rejects_stale_current_source(self) -> None:
        with self.assertRaisesRegex(AuditError, "source hash is stale"):
            validate_audit()

    def test_missing_requirement_fails(self) -> None:
        changed = copy.deepcopy(self.audit)
        changed["p0_requirements"].pop()
        with self.assertRaisesRegex(AuditError, "IDs or order"):
            self.validate_changed(changed)

    def test_missing_evidence_fails(self) -> None:
        changed = copy.deepcopy(self.audit)
        changed["lifecycle_invariants"][0]["evidence"] = ["missing/evidence"]
        with self.assertRaisesRegex(AuditError, "missing evidence path"):
            self.validate_changed(changed)

    def test_required_gap_cannot_be_weakened(self) -> None:
        changed = copy.deepcopy(self.audit)
        changed["release_acceptance"][13]["status"] = "PASS"
        changed["release_acceptance"][13].pop("blocking_task")
        with self.assertRaisesRegex(AuditError, "required release gap was weakened"):
            self.validate_changed(changed)

    def test_mobile_only_criterion_cannot_pass(self) -> None:
        changed = copy.deepcopy(self.audit)
        changed["release_acceptance"][2]["status"] = "PASS"
        with self.assertRaisesRegex(AuditError, "must not be reported as PASS"):
            self.validate_changed(changed)

    def test_blocker_list_must_match_gaps(self) -> None:
        changed = copy.deepcopy(self.audit)
        changed["blockers"].pop()
        with self.assertRaisesRegex(AuditError, "blocker list"):
            self.validate_changed(changed)


if __name__ == "__main__":
    unittest.main()
