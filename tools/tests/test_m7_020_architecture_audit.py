import copy
import json
import tempfile
import unittest
from pathlib import Path

from tools.validate_m7_020_architecture_audit import (
    AuditError,
    DEFAULT_AUDIT,
    validate_audit,
)


class M7020ArchitectureAuditTest(unittest.TestCase):
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

    def test_missing_check_fails(self) -> None:
        changed = copy.deepcopy(self.audit)
        changed["checks"].pop()
        with self.assertRaisesRegex(AuditError, "check inventory"):
            self.validate_changed(changed)

    def test_pass_cannot_be_weakened(self) -> None:
        changed = copy.deepcopy(self.audit)
        changed["checks"][0]["status"] = "GAP"
        with self.assertRaisesRegex(AuditError, "status must be PASS"):
            self.validate_changed(changed)

    def test_stale_guard_hash_fails(self) -> None:
        changed = copy.deepcopy(self.audit)
        changed["source_sha256"]["tools/architecture_guard.py"] = "0" * 64
        with self.assertRaisesRegex(AuditError, "source hash is stale"):
            with tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "audit.data"
                path.write_text(json.dumps(changed), encoding="utf-8")
                validate_audit(path)

    def test_std_net_adapter_inventory_schema_is_strict(self) -> None:
        changed = copy.deepcopy(self.audit)
        changed["inventory"]["semantic_std_net_files"].append(
            changed["inventory"]["semantic_std_net_files"][0]
        )
        with self.assertRaisesRegex(AuditError, "std.net inventory is invalid"):
            self.validate_changed(changed)

    def test_structural_inventory_rejects_zero_counts(self) -> None:
        changed = copy.deepcopy(self.audit)
        changed["inventory"]["cangjie_files"] = 0
        with self.assertRaisesRegex(AuditError, "inventory field is invalid"):
            self.validate_changed(changed)

    def test_structural_inventory_rejects_std_net_outside_adapter(self) -> None:
        changed = copy.deepcopy(self.audit)
        changed["inventory"]["semantic_std_net_files"] = ["src/http/client.cj"]
        with self.assertRaisesRegex(AuditError, "std.net escaped the adapter package"):
            self.validate_changed(changed)

    def test_structural_inventory_rejects_escaping_path(self) -> None:
        changed = copy.deepcopy(self.audit)
        changed["inventory"]["semantic_std_net_files"] = ["../outside.cj"]
        with self.assertRaisesRegex(AuditError, "inventory path is invalid"):
            self.validate_changed(changed)


if __name__ == "__main__":
    unittest.main()
