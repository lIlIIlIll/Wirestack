from __future__ import annotations

import copy
import hashlib
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))

import m7_029_independent_security_review as review  # noqa: E402
import latest_cangjie_nightly as nightly  # noqa: E402
import build_native_dependencies  # noqa: E402


class M7029IndependentSecurityReviewTests(unittest.TestCase):
    def fixture(self) -> tuple[tempfile.TemporaryDirectory[str], Path, dict]:
        temporary = tempfile.TemporaryDirectory(prefix="wirestack-m7-029-")
        root = Path(temporary.name)
        package = root / review.PACKAGE_PATH
        package.parent.mkdir(parents=True, exist_ok=True)
        package.write_bytes((ROOT / review.PACKAGE_PATH).read_bytes())
        return temporary, root, review.build_request(root)

    @staticmethod
    def valid_report(request: dict) -> dict:
        return {
            "schemaVersion": 1,
            "taskId": "M7-029",
            "target": {
                "packagePath": request["packagePath"],
                "packageSha256": request["packageSha256"],
            },
            "reviewer": {
                "identity": "external-reviewer",
                "affiliation": "independent",
                "reviewMode": "External",
                "independent": True,
                "independenceStatement": "I did not implement the reviewed changes.",
                "conflicts": [],
                "startedAtUtc": "2026-08-29T00:00:00Z",
                "completedAtUtc": "2026-08-29T01:00:00Z",
            },
            "scope": sorted(review.REQUIRED_SCOPE),
            "methods": sorted(review.REQUIRED_METHODS),
            "compatibilityPolicy": review.COMPATIBILITY_POLICY,
            "findings": [],
            "conclusion": "PASS",
        }

    def test_complete_no_finding_report_passes(self) -> None:
        temporary, root, request = self.fixture()
        self.addCleanup(temporary.cleanup)
        summary = review.validate_review(root, request, self.valid_report(request))
        self.assertEqual(0, summary["findingCount"])

    def test_stale_target_and_incomplete_scope_fail(self) -> None:
        temporary, root, request = self.fixture()
        self.addCleanup(temporary.cleanup)
        value = self.valid_report(request)
        value["target"]["packageSha256"] = "0" * 64
        with self.assertRaises(review.IndependentReviewError) as caught:
            review.validate_review(root, request, value)
        self.assertEqual("TARGET_MISMATCH", caught.exception.code)

        value = self.valid_report(request)
        value["scope"] = value["scope"][:-1]
        with self.assertRaises(review.IndependentReviewError) as caught:
            review.validate_review(root, request, value)
        self.assertEqual("SCOPE_INCOMPLETE", caught.exception.code)

    def test_reviewer_independence_is_required(self) -> None:
        temporary, root, request = self.fixture()
        self.addCleanup(temporary.cleanup)
        value = self.valid_report(request)
        value["reviewer"]["independent"] = False
        with self.assertRaises(review.IndependentReviewError) as caught:
            review.validate_review(root, request, value)
        self.assertEqual("REVIEWER_NOT_INDEPENDENT", caught.exception.code)

    def test_process_isolated_agent_requires_conflict_disclosure(self) -> None:
        temporary, root, request = self.fixture()
        self.addCleanup(temporary.cleanup)
        value = self.valid_report(request)
        value["reviewer"]["reviewMode"] = "ProcessIsolatedAgent"
        value["reviewer"]["identity"] = "isolated-review-agent"
        value["reviewer"]["conflicts"] = [
            "Commissioned by the same repository owner through the implementation orchestrator."
        ]
        summary = review.validate_review(root, request, value)
        self.assertEqual(0, summary["findingCount"])

        value["reviewer"]["conflicts"] = []
        with self.assertRaises(review.IndependentReviewError) as caught:
            review.validate_review(root, request, value)
        self.assertEqual("REVIEWER_NOT_INDEPENDENT", caught.exception.code)

        value = self.valid_report(request)
        value["reviewer"]["reviewMode"] = "SameImplementationAgent"
        with self.assertRaises(review.IndependentReviewError) as caught:
            review.validate_review(root, request, value)
        self.assertEqual("REVIEW_MODE_INVALID", caught.exception.code)

    def test_provider_manifest_is_a_repository_input(self) -> None:
        manifest_path = ROOT / "native/tls/aws_lc/provider.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        self.assertEqual(1, manifest["schema_version"])
        self.assertEqual("aws-lc", manifest["provider_id"])
        self.assertEqual("5.5.0", manifest["provider_version"])
        self.assertEqual(
            "991e67ff4cf04df4dd89e407f8b920c6936cb56a",
            manifest["source"]["commit"],
        )
        visible = subprocess.run(
            ["git", "check-ignore", "-q", "native/tls/aws_lc/provider.json"],
            cwd=ROOT,
            check=False,
        )
        self.assertEqual(1, visible.returncode)

    def test_clean_cangjie_workflow_covers_the_release_critical_gates(self) -> None:
        workflow = (ROOT / ".github/workflows/clean-cangjie-build.yml").read_text(
            encoding="utf-8"
        )
        self.assertIn("name: Clean Cangjie Build", workflow)
        self.assertIn("pull_request:", workflow)
        self.assertIn("runs-on: ubuntu-latest", workflow)
        self.assertNotIn("self-hosted", workflow)
        self.assertIn(
            "actions/checkout@11d5960a326750d5838078e36cf38b85af677262",
            workflow,
        )
        self.assertIn(
            "Zxilly/setup-cangjie@f959b3d1078c92173ea67d398f293727639000f7",
            workflow,
        )
        self.assertIn(
            'python3 tools/latest_cangjie_nightly.py --github-output "$GITHUB_OUTPUT"',
            workflow,
        )
        self.assertIn("version: ${{ steps.cangjie-nightly.outputs.version }}", workflow)
        self.assertIn("sudo apt-get install --yes clang llvm cmake ninja-build", workflow)
        for command in (
            "scripts/repo-doctor --json",
            "scripts/check-code",
            "scripts/check-m7-027-linux-examples --json",
            "git diff --exit-code",
            "git status --porcelain --untracked-files=all",
        ):
            self.assertIn(command, workflow)
        self.assertIn('case "$doctor_exit" in', workflow)
        self.assertIn("0|6) ;;", workflow)
        self.assertIn('*) exit "$doctor_exit" ;;', workflow)
        self.assertNotIn("continue-on-error", workflow)
        self.assertNotIn("|| true", workflow)
        self.assertNotIn("scripts/verify-evidence --all", workflow)
        check = (ROOT / "scripts/check").read_text(encoding="utf-8")
        code_gate = (ROOT / "scripts/check-code").read_text(encoding="utf-8")
        self.assertIn("scripts/check-code", check)
        for command in (
            "tools/architecture_guard.py",
            "scripts/build-linux-resolver --quiet",
            "cjpm check",
            "cjpm build",
            "cjpm test --exclude-tags=Performance",
        ):
            self.assertIn(command, code_gate)

    def test_hosted_ci_nightly_resolution_fails_closed(self) -> None:
        version = "1.3.0-alpha.20260829010011"
        release = {
            "name": f"Nightly Build {version}",
            "tag_name": version,
            "assets": [{"name": f"cangjie-sdk-linux-x64-{version}.tar.gz"}],
        }
        self.assertEqual(version, nightly.resolve_release(release))

        for mutation in (
            {**release, "tag_name": "different"},
            {**release, "assets": []},
            {**release, "schema_version": 2, "name": "unknown"},
        ):
            with self.assertRaises(ValueError):
                nightly.resolve_release(mutation)

    def test_cjpm_build_hook_uses_fail_closed_platform_selection(self) -> None:
        build_script = (ROOT / "build.cj").read_text(encoding="utf-8")
        self.assertIn('join("build_native_dependencies.py")', build_script)
        self.assertIn("private func buildNativeDependencies(scriptPath: String): Int64", build_script)
        self.assertIn('"--cjpm-script-path", scriptPath', build_script)
        self.assertNotIn('join("build_linux_resolver.py")', build_script)
        self.assertNotIn('join("build_tls_provider.py")', build_script)
        for phase in (
            "pre-build", "pre-check", "pre-test", "pre-bench",
            "pre-run", "pre-install", "pre-publish",
        ):
            self.assertIn(
                f'case "{phase}" => buildNativeDependencies(args[0])',
                build_script,
            )

        self.assertEqual(
            ["tls-provider", "resolver"],
            build_native_dependencies.plan("Linux"),
        )
        self.assertEqual(["resolver"], build_native_dependencies.plan("Windows"))
        with self.assertRaisesRegex(ValueError, "unsupported"):
            build_native_dependencies.plan("Darwin")

    def test_reviewer_dates_conflicts_and_set_fields_are_strict(self) -> None:
        temporary, root, request = self.fixture()
        self.addCleanup(temporary.cleanup)

        value = self.valid_report(request)
        value["reviewer"]["startedAtUtc"] = "last Tuesday"
        with self.assertRaises(review.IndependentReviewError) as caught:
            review.validate_review(root, request, value)
        self.assertEqual("REVIEWER_DATE_INVALID", caught.exception.code)

        value = self.valid_report(request)
        value["reviewer"]["completedAtUtc"] = "2026-08-28T23:59:59Z"
        with self.assertRaises(review.IndependentReviewError) as caught:
            review.validate_review(root, request, value)
        self.assertEqual("REVIEWER_DATE_INVALID", caught.exception.code)

        value = self.valid_report(request)
        value["reviewer"]["conflicts"] = ["shared employer", "shared employer"]
        with self.assertRaises(review.IndependentReviewError) as caught:
            review.validate_review(root, request, value)
        self.assertEqual("SCHEMA", caught.exception.code)

        value = self.valid_report(request)
        value["scope"].append(value["scope"][0])
        with self.assertRaises(review.IndependentReviewError) as caught:
            review.validate_review(root, request, value)
        self.assertEqual("SCHEMA", caught.exception.code)

        value = self.valid_report(request)
        value["methods"].append(value["methods"][0])
        with self.assertRaises(review.IndependentReviewError) as caught:
            review.validate_review(root, request, value)
        self.assertEqual("SCHEMA", caught.exception.code)

    def test_duplicate_and_unknown_finding_fields_fail(self) -> None:
        temporary, root, request = self.fixture()
        self.addCleanup(temporary.cleanup)
        finding = self.open_finding("SEC-001", "Low")
        value = self.valid_report(request)
        value["findings"] = [finding, copy.deepcopy(finding)]
        with self.assertRaises(review.IndependentReviewError) as caught:
            review.validate_review(root, request, value)
        self.assertEqual("FINDING_DUPLICATE", caught.exception.code)

        value = self.valid_report(request)
        finding = self.open_finding("SEC-002", "Unknown")
        value["findings"] = [finding]
        with self.assertRaises(review.IndependentReviewError) as caught:
            review.validate_review(root, request, value)
        self.assertEqual("SEVERITY_INVALID", caught.exception.code)

    def test_open_high_and_critical_findings_block_release(self) -> None:
        for severity in ("High", "Critical"):
            temporary, root, request = self.fixture()
            self.addCleanup(temporary.cleanup)
            value = self.valid_report(request)
            value["findings"] = [self.open_finding("SEC-" + severity, severity)]
            with self.assertRaises(review.IndependentReviewError) as caught:
                review.validate_review(root, request, value)
            self.assertEqual("RELEASE_BLOCKER", caught.exception.code)

    def test_fixed_finding_requires_executed_digest_bound_regression(self) -> None:
        temporary, root, request = self.fixture()
        self.addCleanup(temporary.cleanup)
        value = self.valid_report(request)
        finding = self.open_finding("SEC-003", "High")
        finding["status"] = "Fixed"
        finding["fix"] = "commit-or-diff-id"
        value["findings"] = [finding]
        with self.assertRaises(review.IndependentReviewError) as caught:
            review.validate_review(root, request, value)
        self.assertEqual("REGRESSION_MISSING", caught.exception.code)

        evidence = root / "docs/evidence/M7-029/regression.log"
        evidence.parent.mkdir(parents=True, exist_ok=True)
        evidence.write_text("PASS\n", encoding="utf-8")
        finding["regressions"] = [{
            "command": "focused-regression",
            "status": "PASS",
            "exitCode": 0,
            "timedOut": False,
            "evidencePath": "docs/evidence/M7-029/regression.log",
            "sha256": hashlib.sha256(evidence.read_bytes()).hexdigest(),
        }]
        summary = review.validate_review(root, request, value)
        self.assertEqual({"Fixed": 1}, summary["findingStatuses"])

        finding["regressions"][0]["status"] = "SKIPPED"
        with self.assertRaises(review.IndependentReviewError) as caught:
            review.validate_review(root, request, value)
        self.assertEqual("REGRESSION_NOT_PASS", caught.exception.code)

    def test_sensitive_value_and_compatibility_gate_fail(self) -> None:
        temporary, root, request = self.fixture()
        self.addCleanup(temporary.cleanup)
        value = self.valid_report(request)
        value["reviewer"]["independenceStatement"] = "Authorization: Bearer synthetic-secret"
        with self.assertRaises(review.IndependentReviewError) as caught:
            review.validate_review(root, request, value)
        self.assertEqual("SENSITIVE_DATA", caught.exception.code)
        self.assertNotIn("synthetic-secret", caught.exception.detail)

        value = self.valid_report(request)
        value["compatibilityPolicy"] = "REQUIRED"
        with self.assertRaises(review.IndependentReviewError) as caught:
            review.validate_review(root, request, value)
        self.assertEqual("COMPATIBILITY_GATE", caught.exception.code)

    def test_missing_review_is_blocked_and_atomic_failure_preserves_file(self) -> None:
        temporary, root, request = self.fixture()
        self.addCleanup(temporary.cleanup)
        request_path = root / "request.json"
        review.atomic_json(request_path, request)
        with self.assertRaises(review.IndependentReviewError) as caught:
            review.validate(root, request_path, root / "missing-review.json")
        self.assertEqual("REVIEW_REQUIRED", caught.exception.code)

        report_path = root / "report.json"
        report_path.write_bytes(b"previous\n")

        def fail_replace(source: Path, destination: Path) -> None:
            raise review.IndependentReviewError("INJECTED", source.name)

        with self.assertRaises(review.IndependentReviewError):
            review.atomic_json(report_path, {"status": "PASS"}, replace=fail_replace)
        self.assertEqual(b"previous\n", report_path.read_bytes())
        self.assertFalse(report_path.with_name("report.json.tmp").exists())

    @staticmethod
    def open_finding(finding_id: str, severity: str) -> dict:
        return {
            "id": finding_id,
            "title": "Finding",
            "severity": severity,
            "status": "Open",
            "location": "src/example.cj:1",
            "reproduction": "Run the bounded reproduction.",
            "impact": "Documented impact.",
            "evidence": "Observed result.",
            "fix": None,
            "regressions": [],
            "dispositionRationale": "",
        }


if __name__ == "__main__":
    unittest.main()
