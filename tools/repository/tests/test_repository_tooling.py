from __future__ import annotations

import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from tools.evidence_digest import text_evidence_digest
from tools.repository import repository_tooling as tooling


class RepositoryToolingTests(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory(prefix="wirestack-p1-012-")
        self.root = Path(self.directory.name)
        (self.root / "tools/tasks").mkdir(parents=True)
        (self.root / "docs/planning").mkdir(parents=True)
        (self.root / "docs/evidence/TEST-001").mkdir(parents=True)
        (self.root / "source.txt").write_text("current\n", encoding="utf-8")
        self.write_planning({"TEST-001": "COMPLETE", "BASE-001": "COMPLETE"})
        self.git("init", "--quiet")
        self.git("config", "core.hooksPath", str(self.root / "disabled-hooks"))
        self.git("config", "user.name", "Wirestack Test")
        self.git("config", "user.email", "wirestack-test@example.invalid")
        self.git("config", "commit.gpgsign", "false")
        self.git("add", "--force", "source.txt")
        self.git("commit", "--quiet", "-m", "fixture source")

    def tearDown(self) -> None:
        self.directory.cleanup()

    def git(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["git", *args],
            cwd=self.root,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=10,
            check=True,
        )


    def write_planning(self, statuses: dict[str, str]) -> None:
        rows = "\n".join(f"| {task_id} | task | source | condition |" for task_id in statuses)
        (self.root / "docs/planning/implementation-backlog.md").write_text(rows + "\n", encoding="utf-8")
        status_rows = "\n".join(f"| {task_id} | {status} | evidence | note |" for task_id, status in statuses.items())
        (self.root / "docs/planning/status.md").write_text(status_rows + "\n", encoding="utf-8")

    def manifest(self, task_id: str = "TEST-001", dependencies: list[str] | None = None) -> dict[str, object]:
        return {
            "schema_version": tooling.SCHEMA_VERSION,
            "task_id": task_id,
            "dependencies": ["BASE-001"] if dependencies is None else dependencies,
            "allowed_paths": ["tools/tasks", "source.txt"],
            "platforms": ["linux-x86_64-glibc"],
            "acceptance_commands": [{
                "id": "unit", "argv": ["python3", "-c", "pass"],
                "timeout_seconds": 10, "long_running": False, "gate": "task",
            }],
            "required_evidence": ["docs/evidence/TEST-001/evidence.json"],
            "timeout_seconds": 60,
            "long_running_gate": False,
            "source_paths": ["source.txt"],
        }

    def write_manifest(self, manifest: dict[str, object]) -> Path:
        path = self.root / "tools/tasks" / f"{manifest['task_id']}.json"
        path.write_text(json.dumps(manifest), encoding="utf-8")
        return path

    def evidence(self, report_status: str = "PASS") -> tuple[dict[str, object], Path]:
        report_path = self.root / "docs/evidence/TEST-001/report.json"
        report_path.write_text(json.dumps({"status": report_status}), encoding="utf-8")
        task = self.manifest()
        task["required_evidence"] = ["docs/evidence/TEST-001/evidence.json", "docs/evidence/TEST-001/report.json"]
        self.write_manifest(task)
        evidence = {
            "schema_version": tooling.EVIDENCE_SCHEMA_VERSION,
            "source_task": "TEST-001",
            "platform": tooling.platform_identity(),
            "toolchain": tooling.toolchain_identity(self.root),
            "acceptance_status": "PASS",
            "generated_at_utc": tooling.utc_now(),
            "revision": self.git("rev-parse", "HEAD").stdout.strip(),
            "reports": [{
                "path": "docs/evidence/TEST-001/report.json",
                "sha256": text_evidence_digest(report_path).to_json(),
                "source_task": "TEST-001",
                "acceptance_status": "PASS",
            }],
            "source_sha256": {
                "source.txt": text_evidence_digest(self.root / "source.txt").to_json()
            },
        }
        evidence_path = self.root / "docs/evidence/TEST-001/evidence.json"
        evidence_path.write_text(json.dumps(evidence), encoding="utf-8")
        return evidence, evidence_path

    def seal(self, candidate_revision: str | None = None) -> dict[str, object]:
        with mock.patch.object(
            tooling,
            "toolchain_identity",
            return_value={"cjc": None, "cjpm": None},
        ):
            return tooling.seal_evidence(
                self.root,
                "TEST-001",
                ["docs/evidence/TEST-001/report.json"],
                self.root / "docs/evidence/TEST-001/sealed-evidence.json",
                candidate_revision,
            )


    def test_valid_contract_and_unknown_schema_fail_closed(self) -> None:
        manifest = self.manifest()
        self.assertEqual("TEST-001", tooling.validate_task(manifest, self.root)["task_id"])
        manifest["schema_version"] = 99
        with self.assertRaisesRegex(tooling.ContractError, "unsupported task schema") as caught:
            tooling.validate_task(manifest, self.root)
        self.assertEqual("UNKNOWN_SCHEMA", caught.exception.code)

    def test_repository_plan_validator_tracks_paths_scenarios_and_tests(self) -> None:
        plan = self.root / "plan.md"
        plan.write_text(
            "## Control-flow paths\n| Path ID | Condition | Terminal |\n|---|---|---|\n| P001 | input | PASS |\n"
            "## Semantics and scenario matrix\n| Scenario ID | Input | Paths |\n|---|---|---|\n| S001 | valid | P001 |\n"
            "## Test-plan matrix\n| Test ID | Scenarios | Paths |\n|---|---|---|\n| T001 | S001 | P001 |\n",
            encoding="utf-8",
        )
        report = tooling.validate_plan(plan)
        self.assertEqual("PASS", report["status"])
        self.assertEqual({"paths": 1, "scenarios": 1, "tests": 1}, report["counts"])

    def test_path_escape_is_rejected(self) -> None:
        manifest = self.manifest()
        manifest["allowed_paths"] = ["../outside"]
        with self.assertRaises(tooling.ContractError) as caught:
            tooling.validate_task(manifest, self.root)
        self.assertEqual("PATH_ESCAPE", caught.exception.code)

    def test_unknown_field_is_rejected(self) -> None:
        manifest = self.manifest()
        manifest["surprise"] = True
        with self.assertRaises(tooling.ContractError) as caught:
            tooling.validate_task(manifest, self.root)
        self.assertEqual("UNKNOWN_FIELD", caught.exception.code)

    def test_missing_task_is_structured(self) -> None:
        self.write_manifest(self.manifest())
        with self.assertRaises(tooling.ContractError) as caught:
            tooling.validate_repository_tasks(self.root, "MISS-001")
        self.assertEqual("TASK_MISSING", caught.exception.code)

    def test_missing_dependency_is_rejected(self) -> None:
        self.write_manifest(self.manifest(dependencies=["MISS-001"]))
        with self.assertRaises(tooling.ContractError) as caught:
            tooling.validate_repository_tasks(self.root)
        self.assertEqual("DEPENDENCY_MISSING", caught.exception.code)

    def test_dependency_cycle_is_rejected(self) -> None:
        self.write_planning({"TEST-001": "COMPLETE", "TEST-002": "COMPLETE"})
        first = self.manifest("TEST-001", ["TEST-002"])
        second = self.manifest("TEST-002", ["TEST-001"])
        second["required_evidence"] = ["docs/evidence/TEST-001/evidence.json"]
        self.write_manifest(first)
        self.write_manifest(second)
        with self.assertRaises(tooling.ContractError) as caught:
            tooling.validate_repository_tasks(self.root)
        self.assertEqual("DEPENDENCY_CYCLE", caught.exception.code)

    def test_long_command_cannot_enter_fast_gate(self) -> None:
        manifest = self.manifest()
        manifest["acceptance_commands"][0]["long_running"] = True
        manifest["acceptance_commands"][0]["gate"] = "fast"
        manifest["long_running_gate"] = True
        with self.assertRaises(tooling.ContractError) as caught:
            tooling.validate_task(manifest, self.root)
        self.assertEqual("LONG_GATE_LEAK", caught.exception.code)

    def test_long_check_with_no_long_commands_is_skipped(self) -> None:
        self.write_manifest(self.manifest())
        report = tooling.check(self.root, "long", "TEST-001")
        self.assertEqual("SKIPPED", report["status"])
        self.assertEqual([], report["commands"])

    def test_long_timeout_allows_one_day_plus_bounded_teardown(self) -> None:
        manifest = self.manifest()
        manifest["timeout_seconds"] = 90_000
        manifest["acceptance_commands"][0].update({
            "timeout_seconds": 90_000,
            "long_running": True,
            "gate": "long",
        })
        manifest["long_running_gate"] = True
        tooling.validate_task(manifest, self.root)
        manifest["timeout_seconds"] = tooling.MAX_TIMEOUT_SECONDS + 1
        with self.assertRaises(tooling.ContractError) as caught:
            tooling.validate_task(manifest, self.root)
        self.assertEqual("TIMEOUT", caught.exception.code)

    def test_command_capture_is_bounded(self) -> None:
        command = {"id": "large", "argv": ["python3", "-c", "print('x'*50000)"],
                   "timeout_seconds": 10, "long_running": False, "gate": "task"}
        result = tooling.run_command(self.root, command, self.root / "build/logs")
        self.assertEqual("PASS", result["status"])
        self.assertTrue(result["stdout_truncated"])
        self.assertLessEqual(len(result["stdout_excerpt"].encode()), tooling.CAPTURE_BYTES)

    def test_atomic_report_preserves_old_target_on_injected_failure(self) -> None:
        path = self.root / "report.json"
        path.write_text("old\n", encoding="utf-8")
        with self.assertRaises(RuntimeError):
            tooling.atomic_json(path, {"status": "PASS"}, lambda: (_ for _ in ()).throw(RuntimeError("injected")))
        self.assertEqual("old\n", path.read_text(encoding="utf-8"))
        tooling.atomic_json(path, {"status": "PASS"})
        self.assertEqual("PASS", json.loads(path.read_text())["status"])

    def test_evidence_bound_to_real_commit_is_valid(self) -> None:
        evidence, _ = self.evidence()
        self.assertEqual(
            self.git("rev-parse", "HEAD").stdout.strip(), evidence["revision"]
        )
        self.assertEqual("PASS", tooling.verify(self.root, "TEST-001")["status"])

    def test_legitimate_working_tree_drift_is_stale(self) -> None:
        self.evidence()
        (self.root / "source.txt").write_text("changed\n", encoding="utf-8")
        report = tooling.verify(self.root, "TEST-001")
        self.assertEqual("STALE", report["status"])
        self.assertEqual("DIGEST_STALE", report["tasks"][0]["issues"][0]["code"])

    def test_evidence_line_ending_only_change_is_not_stale(self) -> None:
        self.evidence()
        (self.root / "source.txt").write_bytes(b"current\r\n")
        self.assertEqual("PASS", tooling.verify(self.root, "TEST-001")["status"])

    def test_old_or_untyped_evidence_digest_schema_is_rejected(self) -> None:
        evidence, evidence_path = self.evidence()
        evidence["schema_version"] = 1
        evidence_path.write_text(json.dumps(evidence), encoding="utf-8")
        report = tooling.verify(self.root, "TEST-001")
        self.assertEqual("FAIL", report["status"])
        self.assertEqual("UNKNOWN_SCHEMA", report["tasks"][0]["issues"][0]["code"])

        evidence["schema_version"] = tooling.EVIDENCE_SCHEMA_VERSION
        evidence["source_sha256"]["source.txt"] = "0" * 64
        evidence_path.write_text(json.dumps(evidence), encoding="utf-8")
        report = tooling.verify(self.root, "TEST-001")
        self.assertEqual("FAIL", report["status"])
        self.assertEqual("DIGEST_TYPE", report["tasks"][0]["issues"][0]["code"])

    def test_unknown_digest_domain_is_rejected(self) -> None:
        evidence, evidence_path = self.evidence()
        evidence["source_sha256"]["source.txt"]["domain"] = "future-domain"
        evidence_path.write_text(json.dumps(evidence), encoding="utf-8")
        report = tooling.verify(self.root, "TEST-001")
        self.assertEqual("FAIL", report["status"])
        self.assertEqual("DIGEST_DOMAIN", report["tasks"][0]["issues"][0]["code"])

    def test_stale_report_digest_is_stale(self) -> None:
        self.evidence()
        (self.root / "docs/evidence/TEST-001/report.json").write_text('{"status":"PASS","changed":true}', encoding="utf-8")
        self.assertEqual("STALE", tooling.verify(self.root, "TEST-001")["status"])

    def test_seal_uses_git_stdout_revision_despite_stderr_warning(self) -> None:
        self.evidence()
        revision = "c" * 40

        def git_result(argv: list[str], **_: object) -> subprocess.CompletedProcess:
            if argv[1] == "rev-parse":
                return subprocess.CompletedProcess(
                    argv, 0, stdout=f"{revision}\n", stderr="loader warning\n"
                )
            if argv[1] == "cat-file":
                return subprocess.CompletedProcess(
                    argv, 0, stdout=b"current\n", stderr=b"loader warning\n"
                )
            raise AssertionError(f"unexpected command: {argv}")

        with mock.patch.object(tooling.subprocess, "run", side_effect=git_result):
            sealed = self.seal()
        self.assertEqual(revision, sealed["revision"])

    def test_seal_binds_actual_committed_source(self) -> None:
        self.evidence()
        revision = self.git("rev-parse", "HEAD").stdout.strip()
        sealed = self.seal()
        self.assertEqual(revision, sealed["revision"])
        self.assertEqual(
            text_evidence_digest(self.root / "source.txt").to_json(),
            sealed["source_sha256"]["source.txt"],
        )

    def test_seal_rejects_fictitious_commit(self) -> None:
        self.evidence()
        with self.assertRaises(tooling.ContractError) as caught:
            self.seal("0" * 40)
        self.assertEqual("REPORT_REVISION", caught.exception.code)
        self.assertFalse(
            (self.root / "docs/evidence/TEST-001/sealed-evidence.json").exists()
        )

    def test_seal_rejects_malformed_revision_without_bound_reports(self) -> None:
        self.evidence()
        with self.assertRaises(tooling.ContractError) as caught:
            self.seal("not-a-full-git-sha")
        self.assertEqual("REPORT_REVISION", caught.exception.code)

    def test_verify_rejects_malformed_revision_without_bound_reports(self) -> None:
        evidence, evidence_path = self.evidence()
        evidence["revision"] = f"{'d' * 40}\nwarning: loader diagnostic"
        evidence_path.write_text(json.dumps(evidence), encoding="utf-8")
        result = tooling.verify(self.root, "TEST-001")
        self.assertEqual("FAIL", result["status"])
        self.assertEqual("REPORT_REVISION", result["tasks"][0]["issues"][0]["code"])

    def test_verify_rejects_missing_or_fictitious_commit(self) -> None:
        for case in ("missing", "forty-zero"):
            with self.subTest(case=case):
                evidence, evidence_path = self.evidence()
                if case == "missing":
                    evidence.pop("revision")
                else:
                    evidence["revision"] = "0" * 40
                evidence_path.write_text(json.dumps(evidence), encoding="utf-8")
                result = tooling.verify(self.root, "TEST-001")
                self.assertEqual("FAIL", result["status"])
                self.assertEqual(
                    "REPORT_REVISION", result["tasks"][0]["issues"][0]["code"]
                )

    def test_verify_rejects_non_commit_object(self) -> None:
        evidence, evidence_path = self.evidence()
        evidence["revision"] = self.git("hash-object", "source.txt").stdout.strip()
        evidence_path.write_text(json.dumps(evidence), encoding="utf-8")
        result = tooling.verify(self.root, "TEST-001")
        self.assertEqual("FAIL", result["status"])
        self.assertEqual("REPORT_REVISION", result["tasks"][0]["issues"][0]["code"])

    def test_verify_rejects_source_digest_unrelated_to_real_candidate_commit(
        self,
    ) -> None:
        evidence, evidence_path = self.evidence()
        original_revision = evidence["revision"]
        (self.root / "source.txt").write_text("unrelated\n", encoding="utf-8")
        self.git("add", "--force", "source.txt")
        self.git("commit", "--quiet", "-m", "unrelated candidate")
        candidate_revision = self.git("rev-parse", "HEAD").stdout.strip()
        self.assertNotEqual(original_revision, candidate_revision)
        (self.root / "source.txt").write_text("current\n", encoding="utf-8")
        evidence["revision"] = candidate_revision
        evidence_path.write_text(json.dumps(evidence), encoding="utf-8")
        result = tooling.verify(self.root, "TEST-001")
        self.assertEqual("FAIL", result["status"])
        self.assertEqual(
            "SOURCE_REVISION_MISMATCH",
            result["tasks"][0]["issues"][0]["code"],
        )

    def test_seal_converts_git_timeout_to_contract_error(self) -> None:
        self.evidence()
        error = subprocess.TimeoutExpired(cmd=["git"], timeout=10)
        with mock.patch.object(tooling.subprocess, "run", side_effect=error):
            with self.assertRaises(tooling.ContractError) as caught:
                self.seal()
        self.assertEqual("REPORT_REVISION", caught.exception.code)

    def test_seal_rejects_default_head_when_working_source_differs(self) -> None:
        self.evidence()
        (self.root / "source.txt").write_text("changed\n", encoding="utf-8")
        with self.assertRaises(tooling.ContractError) as caught:
            self.seal()
        self.assertEqual("SOURCE_REVISION_MISMATCH", caught.exception.code)

    def test_seal_accepts_canonical_line_ending_equivalence(self) -> None:
        self.evidence()
        (self.root / "source.txt").write_bytes(b"current\r\n")
        sealed = self.seal()
        self.assertEqual(
            text_evidence_digest(self.root / "source.txt").to_json(),
            sealed["source_sha256"]["source.txt"],
        )

    def test_seal_rejects_non_commit_object(self) -> None:
        self.evidence()
        blob = self.git("hash-object", "source.txt").stdout.strip()
        with self.assertRaises(tooling.ContractError) as caught:
            self.seal(blob)
        self.assertEqual("REPORT_REVISION", caught.exception.code)

    def test_seal_rejects_source_missing_from_candidate_tree(self) -> None:
        self.evidence()
        (self.root / "later.txt").write_text("later\n", encoding="utf-8")
        manifest = self.manifest()
        manifest["required_evidence"] = [
            "docs/evidence/TEST-001/evidence.json",
            "docs/evidence/TEST-001/report.json",
        ]
        manifest["source_paths"] = ["later.txt"]
        self.write_manifest(manifest)
        with self.assertRaises(tooling.ContractError) as caught:
            self.seal()
        self.assertEqual("SOURCE_REVISION", caught.exception.code)

    def test_revision_bound_report_must_match_candidate(self) -> None:
        evidence, evidence_path = self.evidence()
        manifest_path = self.root / "tools/tasks/TEST-001.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        report_relative = "docs/evidence/TEST-001/report.json"
        manifest["revision_bound_reports"] = [report_relative]
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
        report_path = self.root / report_relative
        report_path.write_text(
            json.dumps({"status": "PASS", "revision": "b" * 40}), encoding="utf-8"
        )
        evidence["reports"][0]["sha256"] = text_evidence_digest(report_path).to_json()
        evidence_path.write_text(json.dumps(evidence), encoding="utf-8")
        result = tooling.verify(self.root, "TEST-001")
        self.assertEqual("FAIL", result["status"])
        self.assertEqual("REPORT_REVISION", result["tasks"][0]["issues"][0]["code"])

    def test_seal_rejects_revision_bound_stale_report(self) -> None:
        self.evidence()
        manifest_path = self.root / "tools/tasks/TEST-001.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        report_relative = "docs/evidence/TEST-001/report.json"
        manifest["revision_bound_reports"] = [report_relative]
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
        report_path = self.root / report_relative
        report_path.write_text(
            json.dumps({"status": "PASS", "revision": "b" * 40}), encoding="utf-8"
        )
        revision = self.git("rev-parse", "HEAD").stdout.strip()
        with self.assertRaises(tooling.ContractError) as caught:
            self.seal(revision)
        self.assertEqual("REPORT_REVISION", caught.exception.code)

    def test_seal_accepts_matching_revision_bound_report(self) -> None:
        self.evidence()
        manifest_path = self.root / "tools/tasks/TEST-001.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        report_relative = "docs/evidence/TEST-001/report.json"
        manifest["revision_bound_reports"] = [report_relative]
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
        revision = self.git("rev-parse", "HEAD").stdout.strip()
        (self.root / report_relative).write_text(
            json.dumps({"status": "PASS", "revision": revision}), encoding="utf-8"
        )
        self.assertEqual(revision, self.seal(revision)["revision"])

    def test_skipped_report_cannot_impersonate_pass(self) -> None:
        evidence, evidence_path = self.evidence("SKIPPED")
        evidence["reports"][0]["sha256"] = text_evidence_digest(
            self.root / "docs/evidence/TEST-001/report.json"
        ).to_json()
        evidence_path.write_text(json.dumps(evidence), encoding="utf-8")
        report = tooling.verify(self.root, "TEST-001")
        self.assertEqual("FAIL", report["status"])
        self.assertEqual("REPORT_NOT_PASS", report["tasks"][0]["issues"][0]["code"])

    def test_escaping_evidence_report_is_rejected(self) -> None:
        evidence, evidence_path = self.evidence()
        evidence["reports"][0]["path"] = "../outside.json"
        evidence_path.write_text(json.dumps(evidence), encoding="utf-8")
        report = tooling.verify(self.root, "TEST-001")
        self.assertEqual("FAIL", report["status"])
        self.assertEqual("PATH_ESCAPE", report["tasks"][0]["issues"][0]["code"])

    def test_doctor_distinguishes_blocked_and_degraded(self) -> None:
        (self.root / "docs/product").mkdir(parents=True)
        (self.root / "docs/product/prd.md").write_text("prd", encoding="utf-8")
        (self.root / "scripts").mkdir()
        check = self.root / "scripts/check"
        check.write_text("#!/bin/sh\n", encoding="utf-8")
        check.chmod(0o755)
        missing_optional = lambda name: (
            None if name in {"but", "rp-rg"} else f"/mock-tools/{name}"
        )
        with mock.patch.object(tooling, "platform_identity", return_value={
            "system": "Linux", "machine": "x86_64", "libc": "glibc", "libc_version": "test"}), \
             mock.patch.object(tooling, "toolchain_identity", return_value={"cjc": "cjc", "cjpm": "cjpm"}):
            degraded = tooling.doctor(self.root, which=missing_optional)
            self.assertEqual("DEGRADED", degraded["status"])
            report_write = next(
                check for check in degraded["checks"]
                if check["id"] == "workspace-report-write"
            )
            self.assertEqual("PASS", report_write["status"])
            self.assertTrue((self.root / "build").is_dir())
            missing_required = lambda name: (
                None if name in {"but", "rp-rg", "cjc"} else f"/mock-tools/{name}"
            )
            blocked = tooling.doctor(self.root, which=missing_required)
            self.assertEqual("BLOCKED", blocked["status"])


if __name__ == "__main__":
    unittest.main()
