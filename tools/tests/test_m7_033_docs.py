from __future__ import annotations

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


if __name__ == "__main__":
    unittest.main()
