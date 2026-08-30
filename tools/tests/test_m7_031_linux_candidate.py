from __future__ import annotations

import copy
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))

import m7_031_linux_candidate as candidate  # noqa: E402


class M7031LinuxCandidateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.documents = candidate.load_documents(ROOT)
        cls.report = candidate.build_candidate(ROOT, documents=cls.documents)

    def documents_copy(self):
        return copy.deepcopy(self.documents)

    def test_current_repository_generates_exact_go_report(self) -> None:
        self.assertEqual("PASS", self.report["status"])
        self.assertEqual("GO_FOR_LINUX_STABLE_RELEASE", self.report["decision"])
        self.assertEqual(
            {"total": 22, "pass": 21, "fail": 0, "notApplicable": 1},
            self.report["criteriaSummary"],
        )
        self.assertEqual(
            [f"REL-{number:02d}" for number in range(1, 23)],
            [item["id"] for item in self.report["criteria"]],
        )
        self.assertEqual(
            "NOT_APPLICABLE_TO_LINUX_PROFILE",
            self.report["criteria"][2]["status"],
        )
        self.assertFalse(self.report["longEvidence"]["rerunByM7031"])

    def test_criterion_inventory_rejects_missing_duplicate_unknown_and_skipped(self) -> None:
        valid = copy.deepcopy(self.report["criteria"])
        for mutate in (
            lambda values: values.pop(),
            lambda values: values.__setitem__(1, copy.deepcopy(values[0])),
            lambda values: values[0].__setitem__("status", "SKIPPED"),
            lambda values: values[0].__setitem__("status", "UNKNOWN"),
            lambda values: values[0].__setitem__("evidence", []),
        ):
            values = copy.deepcopy(valid)
            mutate(values)
            with self.assertRaises(candidate.CandidateError):
                candidate.validate_criteria(values)

    def test_artifact_identity_rejects_each_cross_report_mismatch(self) -> None:
        mutations = (
            ("m7_022", lambda value: value["artifact"].__setitem__("sha256", "0" * 64)),
            ("m7_022", lambda value: value["artifact"].__setitem__("payload_sha256", "0" * 64)),
            ("m7_025", lambda value: value["artifact"].__setitem__("sha256", "0" * 64)),
            ("m7_025", lambda value: value["artifact"].__setitem__("payloadSha256", "0" * 64)),
            ("m7_030_hosted", lambda value: value["subjects"][0].__setitem__("sha256", "0" * 64)),
            ("m7_030_hosted", lambda value: value["subjects"][2].__setitem__("sha256", "0" * 64)),
        )
        for key, mutate in mutations:
            documents = self.documents_copy()
            mutate(documents[key])
            with self.assertRaises(candidate.CandidateError):
                candidate.validate_artifact_identity(documents, ROOT)

    def test_soak_rejects_short_preflight_interruption_and_wrong_artifact(self) -> None:
        artifact = self.report["artifact"]["sha256"]
        mutations = (
            lambda value: value["parameters"].__setitem__("duration_seconds", 3600),
            lambda value: value.__setitem__("formal_parameters_met", False),
            lambda value: value["process"].__setitem__("timed_out", True),
            lambda value: value["process"].__setitem__("wall_elapsed_ms", 3599000),
            lambda value: value["artifact"].__setitem__("sha256", "0" * 64),
            lambda value: value["workload"].__setitem__("decision", "SKIPPED"),
        )
        for mutate in mutations:
            soak = copy.deepcopy(self.documents["m7_022"])
            mutate(soak)
            with self.assertRaises(candidate.CandidateError):
                candidate.validate_soak(ROOT, soak, artifact)

    def test_open_high_or_critical_finding_blocks_release(self) -> None:
        for severity in ("High", "Critical"):
            validation = copy.deepcopy(self.documents["m7_029"])
            review = copy.deepcopy(self.documents["m7_029_review"])
            review["findings"][0]["severity"] = severity
            review["findings"][0]["status"] = "Open"
            with self.assertRaisesRegex(candidate.CandidateError, "SECURITY_BLOCKER"):
                candidate.validate_security(validation, review)

    def test_historical_or_internal_public_api_cannot_pass(self) -> None:
        for key, value in (
            ("internalAliasCount", 1),
            ("compatibilityPolicy", "SOURCE_COMPATIBLE"),
            ("profile", "linux-musl-x86_64"),
        ):
            report = copy.deepcopy(self.documents["m7_032"])
            report[key] = value
            with self.assertRaises(candidate.CandidateError):
                candidate.validate_public_api(ROOT, report)

    def test_source_digest_drift_is_stale(self) -> None:
        documents = self.documents_copy()
        with mock.patch.object(candidate.m7_021_linux_release, "validate_report"), mock.patch.object(
            candidate.m7_021_linux_release, "source_tree_sha256", return_value="0" * 64
        ):
            with self.assertRaisesRegex(candidate.CandidateError, "SOURCE_STALE"):
                candidate.validate_current_sources(ROOT, documents)

    def test_json_schema_duplicate_key_and_path_escape_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory(prefix="wirestack-m7-031-json-") as directory:
            root = Path(directory)
            duplicate = root / "duplicate.json"
            duplicate.write_text('{"schemaVersion":1,"taskId":"a","taskId":"b"}', encoding="utf-8")
            with self.assertRaisesRegex(candidate.CandidateError, "JSON_DUPLICATE_KEY"):
                candidate.load_json(duplicate)
            unknown = root / "unknown.json"
            unknown.write_text('{"schemaVersion":99}', encoding="utf-8")
            with self.assertRaisesRegex(candidate.CandidateError, "SCHEMA_UNSUPPORTED"):
                candidate.load_json(unknown)
            with self.assertRaisesRegex(candidate.CandidateError, "PATH_ESCAPE"):
                candidate.safe_path(root, "../escape.json", must_exist=False)

    def test_hosted_report_requires_all_three_verified_subjects(self) -> None:
        for mutate in (
            lambda value: value["subjects"].pop(),
            lambda value: value["subjects"][0].__setitem__("verification", "SKIPPED"),
            lambda value: value["subjects"].reverse(),
        ):
            documents = self.documents_copy()
            mutate(documents["m7_030_hosted"])
            with self.assertRaises(candidate.CandidateError):
                candidate.validate_artifact_identity(documents, ROOT)

    def test_atomic_replace_failure_preserves_previous_bytes(self) -> None:
        with tempfile.TemporaryDirectory(prefix="wirestack-m7-031-atomic-") as directory:
            report = Path(directory) / "report.json"
            original = b'{"previous":true}\n'
            report.write_bytes(original)

            def fail_replace(_source: Path, _target: Path) -> None:
                raise OSError("injected replace failure")

            with self.assertRaises(OSError):
                candidate.atomic_json(report, {"status": "PASS"}, replace=fail_replace)
            self.assertEqual(original, report.read_bytes())
            self.assertEqual([], list(report.parent.glob(f".{report.name}.*")))

    def test_committed_report_matches_deterministic_generator(self) -> None:
        path = ROOT / "docs/evidence/M7-031/linux_x86_64/release-candidate.json"
        committed = json.loads(path.read_text(encoding="utf-8"))
        self.assertEqual(self.report, committed)
        self.assertEqual(candidate.canonical_json(self.report), path.read_bytes())


if __name__ == "__main__":
    unittest.main()
