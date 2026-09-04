from __future__ import annotations

import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from tools.docs import m7_033_docs as docs


class M7033DocsTests(unittest.TestCase):
    def test_path_escape_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory(prefix="wirestack-m7-033-") as directory:
            with self.assertRaises(docs.DocsError) as caught:
                docs._safe_path(Path(directory), "../outside")
        self.assertEqual("PATH_ESCAPE", caught.exception.code)

    def test_unknown_doc_ir_schema_is_rejected(self) -> None:
        value = {
            "schemaVersion": "future",
            "generator": {"name": "cjdoc", "version": docs.EXPECTED_CJDOC_VERSION},
            "status": "complete",
            "diagnostics": [],
            "declarations": [],
        }
        with self.assertRaises(docs.DocsError) as caught:
            docs.validate_doc_ir(value)
        self.assertEqual("DOC_IR_SCHEMA", caught.exception.code)

    def test_partial_doc_ir_is_never_pass(self) -> None:
        value = {
            "schemaVersion": docs.DOC_IR_SCHEMA,
            "generator": {"name": "cjdoc", "version": docs.EXPECTED_CJDOC_VERSION},
            "status": "partial",
            "diagnostics": [],
            "declarations": [],
        }
        with self.assertRaises(docs.DocsError) as caught:
            docs.validate_doc_ir(value)
        self.assertEqual("DOC_IR_PARTIAL", caught.exception.code)

    def test_doc_ir_diagnostics_are_not_hidden_by_success_status(self) -> None:
        value = {
            "schemaVersion": docs.DOC_IR_SCHEMA,
            "generator": {"name": "cjdoc", "version": docs.EXPECTED_CJDOC_VERSION},
            "status": "complete",
            "diagnostics": [{"severity": "warning", "code": "CJDOC3027"}],
            "declarations": [],
        }
        with self.assertRaises(docs.DocsError) as caught:
            docs.validate_doc_ir(value)
        self.assertEqual("DOC_IR_DIAGNOSTICS", caught.exception.code)

    def test_unknown_api_schema_is_rejected(self) -> None:
        with self.assertRaises(docs.DocsError) as caught:
            docs.validate_api_surface({"schemaVersion": "future"})
        self.assertEqual("API_SCHEMA", caught.exception.code)

    def test_skipped_or_partial_coverage_cannot_impersonate_pass(self) -> None:
        value = {
            "schemaVersion": docs.COVERAGE_SCHEMA,
            "audience": "external",
            "symbols": {"total": 2, "documented": 1, "percent": 100},
            "parameters": {"total": 0, "documented": 0, "percent": 100},
        }
        with self.assertRaises(docs.DocsError) as caught:
            docs.validate_coverage(value)
        self.assertEqual("COVERAGE_INCOMPLETE", caught.exception.code)

    def test_version_mismatch_is_blocked_without_parsing_exception_text(self) -> None:
        completed = subprocess.CompletedProcess(
            ["cjdoc", "--version"], 0, b"cjdoc 0.7.1\n", b""
        )
        with mock.patch.object(docs, "_find_cjdoc", return_value="cjdoc"), \
                mock.patch.object(docs.subprocess, "run", return_value=completed):
            with self.assertRaises(docs.DocsError) as caught:
                docs.resolve_cjdoc(Path("."))
        self.assertEqual("CJDOC_VERSION", caught.exception.code)

    def test_public_source_view_excludes_tests_and_internal_package(self) -> None:
        paths = docs.public_source_paths(docs.ROOT)
        self.assertTrue(paths)
        self.assertTrue(all("/internal/" not in str(path) for path in paths))
        self.assertTrue(all(not path.name.endswith("_test.cj") for path in paths))

    def test_atomic_report_preserves_previous_file_when_replace_fails(self) -> None:
        with tempfile.TemporaryDirectory(prefix="wirestack-m7-033-") as directory:
            path = Path(directory) / "report.json"
            path.write_text('{"status":"OLD"}\n', encoding="utf-8")
            with mock.patch.object(docs.os, "replace", side_effect=OSError("injected")):
                with self.assertRaises(OSError):
                    docs.atomic_json(path, {"status": "PASS"})
            self.assertEqual('{"status":"OLD"}\n', path.read_text(encoding="utf-8"))
            self.assertFalse(list(path.parent.glob(".*.tmp")))

    def test_report_is_machine_readable_and_bounded(self) -> None:
        with tempfile.TemporaryDirectory(prefix="wirestack-m7-033-") as directory:
            path = Path(directory) / "report.json"
            docs.atomic_json(path, {"status": "PASS", "stdout": "x" * 20_000})
            payload = json.loads(path.read_text(encoding="utf-8"))
            self.assertEqual("PASS", payload["status"])

    def test_getting_started_is_linux_scoped_and_actionable(self) -> None:
        guide = (docs.ROOT / "docs/guides/getting-started-linux.md").read_text(encoding="utf-8")
        for token in (
            "scripts/check-m7-027-linux-examples --json",
            "HttpClient.builder()",
            "HttpServer.builder()",
            "OperationContext",
            "AWS-LC 5.5.0",
            "cjdoc 0.7.2",
        ):
            self.assertIn(token, guide)
        self.assertNotIn("已支持 Windows", guide)
        self.assertNotIn("已支持 Android", guide)

    def test_pages_workflow_pins_cjdoc_and_keeps_long_gates_out(self) -> None:
        workflow = (docs.ROOT / ".github/workflows/m7-033-docs.yml").read_text(encoding="utf-8")
        self.assertIn('CJDOC_VERSION: 0.7.2', workflow)
        self.assertIn('cjdoc-${CJDOC_VERSION}-linux-x64.tar.gz', workflow)
        self.assertIn("actions/deploy-pages@v4", workflow)
        self.assertIn("search-index.js", workflow)
        self.assertIn('select(startswith("packages/"))', workflow)
        self.assertNotIn("86400", workflow)

    def test_repository_build_gate_installs_the_same_pinned_cjdoc(self) -> None:
        workflow = (docs.ROOT / ".github/workflows/clean-cangjie-build.yml").read_text(encoding="utf-8")
        self.assertIn('CJDOC_VERSION: 0.7.2', workflow)
        self.assertIn('cjdoc-${CJDOC_VERSION}-linux-x64.tar.gz', workflow)
        self.assertIn('echo "CJDOC_BIN=$binary" >> "$GITHUB_ENV"', workflow)


if __name__ == "__main__":
    unittest.main()
