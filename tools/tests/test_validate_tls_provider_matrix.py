from __future__ import annotations

import copy
import json
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))

import validate_tls_provider_matrix as validator


class Tests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.matrix_path = ROOT / "docs/architecture/tls-provider-candidates.json"
        cls.value = json.loads(cls.matrix_path.read_text(encoding="utf-8"))

    def test_repository_matrix_passes(self):
        validator.validate_matrix(self.value)

    def test_unknown_schema_fails_closed(self):
        value = copy.deepcopy(self.value)
        value["schema_version"] = 2
        with self.assertRaises(validator.MatrixError):
            validator.validate_matrix(value)

    def test_final_selection_must_be_deferred_to_m0_020(self):
        value = copy.deepcopy(self.value)
        value["decision_scope"] = "final provider selection completed by M0-015"
        with self.assertRaises(validator.MatrixError):
            validator.validate_matrix(value)

    def test_missing_platform_fails(self):
        value = copy.deepcopy(self.value)
        del value["candidates"][0]["platforms"]["harmony"]
        with self.assertRaises(validator.MatrixError):
            validator.validate_matrix(value)

    def test_incompatible_license_must_be_excluded(self):
        value = copy.deepcopy(self.value)
        candidate = value["candidates"][0]
        candidate["license"]["compatible"] = False
        candidate["disposition"] = "PRIMARY_POC"
        with self.assertRaises(validator.MatrixError):
            validator.validate_matrix(value)

    def test_excluded_candidate_cannot_be_shortlisted(self):
        value = copy.deepcopy(self.value)
        value["shortlist"]["primary"] = "wolfssl"
        with self.assertRaises(validator.MatrixError):
            validator.validate_matrix(value)

    def test_harmony_cannot_be_claimed_before_poc(self):
        value = copy.deepcopy(self.value)
        value["candidates"][0]["platforms"]["harmony"] = "DOCUMENTED"
        with self.assertRaises(validator.MatrixError):
            validator.validate_matrix(value)

    def test_third_party_comparison_source_rejected(self):
        value = copy.deepcopy(self.value)
        value["candidates"][0]["evidence"][0] = "https://medium.com/example"
        with self.assertRaises(validator.MatrixError):
            validator.validate_matrix(value)


if __name__ == "__main__":
    unittest.main()
