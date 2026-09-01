from __future__ import annotations

import inspect
import json
import unittest
from pathlib import Path

from tools import m7_021_linux_release as release
from tools import m7_031_linux_candidate as candidate
from tools.validate_m7_019_linux_audit import AuditError as M7019Error
from tools.validate_m7_019_linux_audit import validate_audit as validate_m7_019
from tools.validate_m7_020_architecture_audit import AuditError as M7020Error
from tools.validate_m7_020_architecture_audit import validate_audit as validate_m7_020


ROOT = Path(__file__).resolve().parents[2]


class P1013DevelopmentReleaseGateTests(unittest.TestCase):
    def test_release_validators_are_strict_by_default(self) -> None:
        for function in (
            validate_m7_019,
            validate_m7_020,
            release.validate_report,
            candidate.build_candidate,
        ):
            parameter = inspect.signature(function).parameters["verify_current_sources"]
            self.assertIs(True, parameter.default)

    def test_structural_modes_accept_frozen_records_without_local_release_artifact(self) -> None:
        validate_m7_019(verify_current_sources=False)
        validate_m7_020(verify_current_sources=False)
        qualification = json.loads(
            (ROOT / "docs/evidence/M7-021/linux_x86_64/qualification.json").read_text(
                encoding="utf-8"
            )
        )
        release.validate_report(
            qualification,
            ROOT,
            verify_current_sources=False,
        )
        documents = candidate.load_documents(ROOT)
        recorded = candidate.validate_recorded_sources(ROOT, documents)
        self.assertEqual(
            {"releaseSourceTreeSha256", "fuzzSourceSha256",
             "http2PerformanceSourceSha256"},
            set(recorded),
        )
        self.assertTrue(all(len(value) == 64 for value in recorded.values()))

    def test_strict_modes_reject_the_same_stale_records(self) -> None:
        with self.assertRaisesRegex(M7019Error, "source hash is stale"):
            validate_m7_019()
        with self.assertRaisesRegex(M7020Error, "source hash is stale"):
            validate_m7_020()
        qualification = json.loads(
            (ROOT / "docs/evidence/M7-021/linux_x86_64/qualification.json").read_text(
                encoding="utf-8"
            )
        )
        with self.assertRaisesRegex(release.ReleaseError, "source tree fingerprint is stale"):
            release.validate_report(qualification, ROOT)
        with self.assertRaisesRegex(
            (
                candidate.CandidateError,
                candidate.m7_032_public_api_inventory.PublicApiInventoryError,
            ),
            "DIGEST_INVALID|committed public API report is stale",
        ):
            candidate.build_candidate(ROOT)


if __name__ == "__main__":
    unittest.main()
