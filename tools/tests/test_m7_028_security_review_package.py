from __future__ import annotations

from tools import evidence_digest

import copy
import json
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))

import m7_028_security_review_package as review  # noqa: E402


class M7028SecurityReviewPackageTests(unittest.TestCase):
    def fixture(self) -> tuple[tempfile.TemporaryDirectory[str], Path, dict]:
        temporary = tempfile.TemporaryDirectory(prefix="wirestack-m7-028-")
        root = Path(temporary.name)
        index = review.build_index(ROOT)
        for item in index["documents"] + index["evidence"]:
            source = ROOT / item["path"]
            target = root / item["path"]
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(source.read_bytes())
        return temporary, root, index

    @staticmethod
    def digest(path: Path) -> str:
        return evidence_digest.text_evidence_bytes_sha256(path.read_bytes())

    def test_checked_in_package_is_valid(self) -> None:
        report = review.validate(ROOT, review.DEFAULT_INDEX, review.DEFAULT_REPORT)
        self.assertEqual("PASS", report["status"])
        self.assertEqual("DISABLED_PRE_1_0", report["checks"]["compatibilityGate"])
        self.assertEqual(
            {
                "CURRENT_PASS": 8,
                "CURRENT_BOUND_INPUT": 3,
                "STALE_AFTER_M7_032": 1,
                "HISTORICAL_NON_GATING": 1,
            },
            report["stateCounts"],
        )

    def test_current_bound_inputs_require_pass_bundle_digest(self) -> None:
        temporary, root, index = self.fixture()
        self.addCleanup(temporary.cleanup)
        bound = next(
            item for item in index["evidence"] if item["state"] == "CURRENT_BOUND_INPUT"
        )
        target = root / bound["path"]
        target.write_bytes(target.read_bytes() + b"\n")
        bound["sha256"] = self.digest(target)
        with self.assertRaises(review.ReviewPackageError) as caught:
            review.validate_index(root, index)
        self.assertEqual("BOUND_INPUT_MISMATCH", caught.exception.code)

    def test_path_escape_is_rejected(self) -> None:
        temporary, root, index = self.fixture()
        self.addCleanup(temporary.cleanup)
        index["documents"][0]["path"] = "../outside"
        with self.assertRaisesRegex(review.ReviewPackageError, "../outside") as caught:
            review.validate_index(root, index)
        self.assertEqual("PATH_ESCAPE", caught.exception.code)

    def test_unknown_schema_and_field_are_rejected(self) -> None:
        temporary, root, index = self.fixture()
        self.addCleanup(temporary.cleanup)
        unknown_version = copy.deepcopy(index)
        unknown_version["schemaVersion"] = 99
        with self.assertRaises(review.ReviewPackageError) as caught:
            review.validate_index(root, unknown_version)
        self.assertEqual("SCHEMA_VERSION", caught.exception.code)
        index["unexpected"] = True
        with self.assertRaises(review.ReviewPackageError) as caught:
            review.validate_index(root, index)
        self.assertEqual("SCHEMA", caught.exception.code)

    def test_missing_file_and_digest_drift_are_rejected(self) -> None:
        temporary, root, index = self.fixture()
        self.addCleanup(temporary.cleanup)
        target = root / index["documents"][0]["path"]
        target.unlink()
        with self.assertRaises(review.ReviewPackageError) as caught:
            review.validate_index(root, index)
        self.assertEqual("FILE_MISSING", caught.exception.code)

        temporary2, root2, index2 = self.fixture()
        self.addCleanup(temporary2.cleanup)
        target2 = root2 / index2["documents"][0]["path"]
        target2.write_text("drift\n", encoding="utf-8")
        with self.assertRaises(review.ReviewPackageError) as caught:
            review.validate_index(root2, index2)
        self.assertEqual("DIGEST_MISMATCH", caught.exception.code)

    def test_stale_or_skipped_evidence_cannot_claim_pass(self) -> None:
        temporary, root, index = self.fixture()
        self.addCleanup(temporary.cleanup)
        stale = next(item for item in index["evidence"] if item["state"] == "STALE_AFTER_M7_032")
        stale["gating"] = True
        with self.assertRaises(review.ReviewPackageError) as caught:
            review.validate_index(root, index)
        self.assertEqual("FALSE_PASS", caught.exception.code)

        temporary2, root2, index2 = self.fixture()
        self.addCleanup(temporary2.cleanup)
        current = next(item for item in index2["evidence"] if item["state"] == "CURRENT_PASS")
        target = root2 / current["path"]
        target.write_text('{"status":"SKIPPED"}\n', encoding="utf-8")
        current["sha256"] = self.digest(target)
        with self.assertRaises(review.ReviewPackageError) as caught:
            review.validate_index(root2, index2)
        self.assertEqual("SKIPPED_AS_PASS", caught.exception.code)

    def test_sensitive_data_is_rejected_without_echoing_value(self) -> None:
        temporary, root, index = self.fixture()
        self.addCleanup(temporary.cleanup)
        target = root / index["documents"][0]["path"]
        target.write_text("Authorization: Bearer synthetic-secret-value\n", encoding="utf-8")
        index["documents"][0]["sha256"] = self.digest(target)
        with self.assertRaises(review.ReviewPackageError) as caught:
            review.validate_index(root, index)
        self.assertEqual("SENSITIVE_DATA", caught.exception.code)
        self.assertNotIn("synthetic-secret-value", caught.exception.detail)

        temporary2, root2, index2 = self.fixture()
        self.addCleanup(temporary2.cleanup)
        stale = next(
            item for item in index2["evidence"] if item["state"] == "STALE_AFTER_M7_032"
        )
        evidence = root2 / stale["path"]
        evidence.write_text(
            evidence.read_text(encoding="utf-8")
            + "\nAuthorization: Bearer synthetic-evidence-secret\n",
            encoding="utf-8",
        )
        stale["sha256"] = self.digest(evidence)
        with self.assertRaises(review.ReviewPackageError) as caught:
            review.validate_index(root2, index2)
        self.assertEqual("SENSITIVE_DATA", caught.exception.code)
        self.assertNotIn("synthetic-evidence-secret", caught.exception.detail)

    def test_required_topic_and_compatibility_gate_are_enforced(self) -> None:
        temporary, root, index = self.fixture()
        self.addCleanup(temporary.cleanup)
        index["documents"] = [item for item in index["documents"] if item["topic"] != "threat-model"]
        with self.assertRaises(review.ReviewPackageError) as caught:
            review.validate_index(root, index)
        self.assertEqual("TOPIC_MISSING", caught.exception.code)

        temporary2, root2, index2 = self.fixture()
        self.addCleanup(temporary2.cleanup)
        historical = next(item for item in index2["evidence"] if item["sourceTask"] == "M7-026")
        historical["state"] = "CURRENT_PASS"
        historical["gating"] = True
        with self.assertRaises(review.ReviewPackageError) as caught:
            review.validate_index(root2, index2)
        self.assertEqual("COMPATIBILITY_GATE", caught.exception.code)

    def test_atomic_report_failure_preserves_previous_bytes(self) -> None:
        with tempfile.TemporaryDirectory(prefix="wirestack-m7-028-atomic-") as directory:
            target = Path(directory) / "report.json"
            target.write_bytes(b"previous\n")

            def fail_replace(source: Path, destination: Path) -> None:
                raise review.ReviewPackageError("INJECTED", f"{source.name}->{destination.name}")

            with self.assertRaises(review.ReviewPackageError):
                review.atomic_json(target, {"status": "PASS"}, replace=fail_replace)
            self.assertEqual(b"previous\n", target.read_bytes())
            self.assertFalse(target.with_name("report.json.tmp").exists())


if __name__ == "__main__":
    unittest.main()
