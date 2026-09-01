from __future__ import annotations

import json
import shutil
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

    def tearDown(self) -> None:
        self.directory.cleanup()

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
            "revision": "test",
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

    def test_evidence_source_drift_is_stale(self) -> None:
        self.evidence()
        self.assertEqual("PASS", tooling.verify(self.root, "TEST-001")["status"])
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
        actual = shutil.which
        missing_optional = lambda name: None if name in {"but", "rp-rg"} else actual(name)
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
            missing_required = lambda name: None if name == "cjc" else actual(name)
            blocked = tooling.doctor(self.root, which=missing_required)
            self.assertEqual("BLOCKED", blocked["status"])


if __name__ == "__main__":
    unittest.main()
