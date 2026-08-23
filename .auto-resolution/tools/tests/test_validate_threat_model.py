from __future__ import annotations

import copy
import json
import sys
import unittest
from pathlib import Path

REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPOSITORY_ROOT / "tools"))

import validate_threat_model as validator  # noqa: E402


class ThreatModelValidatorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.canonical = json.loads(
            (REPOSITORY_ROOT / "docs/security/threat-model.json").read_text(
                encoding="utf-8"
            )
        )
        cls.backlog_tasks = {
            task
            for control in cls.canonical["controls"]
            for task in control["tasks"]
        } | {
            task
            for threat in cls.canonical["threats"]
            for task in threat["tasks"]
        }

    def model(self) -> dict:
        return copy.deepcopy(self.canonical)

    def assert_invalid(self, value: dict, needle: str) -> None:
        with self.assertRaisesRegex(validator.ThreatModelError, needle):
            validator.validate_model(value, self.backlog_tasks)

    def test_canonical_model_passes(self) -> None:
        validator.validate_model(self.model(), self.backlog_tasks)

    def test_missing_required_domain_fails_closed(self) -> None:
        value = self.model()
        value["required_domains"].remove("parser_smuggling")
        self.assert_invalid(value, "required_domains")

    def test_high_threat_cannot_be_accepted(self) -> None:
        value = self.model()
        value["threats"][0]["status"] = "ACCEPTED"
        self.assert_invalid(value, "may not be ACCEPTED")

    def test_high_threat_must_block_release(self) -> None:
        value = self.model()
        value["threats"][0]["release_blocker"] = False
        self.assert_invalid(value, "must block stable release")

    def test_malformed_task_id_is_rejected(self) -> None:
        value = self.model()
        value["controls"][0]["tasks"][0] = "M9-999"
        self.assert_invalid(value, "malformed task id")

    def test_well_formed_missing_backlog_task_is_rejected(self) -> None:
        value = self.model()
        value["controls"][0]["tasks"][0] = "M7-999"
        self.assert_invalid(value, "absent from backlog")

    def test_unknown_control_reference_is_rejected(self) -> None:
        value = self.model()
        value["threats"][0]["controls"][0] = "C-NOT-DEFINED"
        self.assert_invalid(value, "unknown control reference")

    def test_empty_residual_risk_is_rejected(self) -> None:
        value = self.model()
        value["threats"][0]["residual"] = ""
        self.assert_invalid(value, "residual must be non-empty")

    def test_required_control_cannot_be_silently_renamed(self) -> None:
        value = self.model()
        value["controls"][0]["id"] = "C-SUPPLY-RENAMED"
        for threat in value["threats"]:
            threat["controls"] = [
                "C-SUPPLY-RENAMED" if item == "C-SUPPLY" else item
                for item in threat["controls"]
            ]
        self.assert_invalid(value, "required controls missing")

    def test_duplicate_threat_id_is_rejected(self) -> None:
        value = self.model()
        value["threats"][1]["id"] = value["threats"][0]["id"]
        self.assert_invalid(value, "duplicate IDs")


if __name__ == "__main__":
    unittest.main()
