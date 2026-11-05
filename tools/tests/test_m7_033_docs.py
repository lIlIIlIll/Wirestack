from __future__ import annotations

import json
import subprocess
import tempfile
import threading
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

    def test_command_output_redacts_repository_and_staging_paths(self) -> None:
        with tempfile.TemporaryDirectory(prefix="wirestack-m7-033-") as directory:
            project = Path(directory) / "wirestack"
            project.mkdir()
            output = f"generated {directory}/wirestack/output\nrepo {docs.ROOT}\n".encode()
            completed = subprocess.CompletedProcess(["cjdoc"], 0, output, b"")
            with mock.patch.object(docs.subprocess, "run", return_value=completed):
                result = docs._run(["cjdoc"], project, 1)
            self.assertEqual("PASS", result["status"])
            self.assertIn("<staging>/wirestack/output", result["stdout"])
            self.assertIn("repo <repo>", result["stdout"])
            self.assertNotIn(directory, result["stdout"])
            self.assertNotIn(str(docs.ROOT), result["stdout"])

    def test_atomic_report_preserves_previous_file_when_replace_fails(self) -> None:
        with tempfile.TemporaryDirectory(prefix="wirestack-m7-033-") as directory:
            path = Path(directory) / "report.json"
            path.write_text('{"status":"OLD"}\n', encoding="utf-8")
            with mock.patch.object(docs.os, "replace", side_effect=OSError("injected")):
                with self.assertRaises(OSError):
                    docs.atomic_json(path, {"status": "PASS"})
            self.assertEqual('{"status":"OLD"}\n', path.read_text(encoding="utf-8"))
            self.assertFalse(list(path.parent.glob(".*.tmp")))

    @staticmethod
    def _generate_fixture_layer(cjdoc, project, output, timeout, package, commands) -> None:
        artifacts = docs._artifact_paths(output)
        values = {
            "docs": {
                "schemaVersion": docs.DOC_IR_SCHEMA,
                "generator": {"name": "cjdoc", "version": docs.EXPECTED_CJDOC_VERSION},
                "status": "complete",
                "diagnostics": [],
                "declarations": [{"id": package}],
            },
            "api": {
                "schemaVersion": docs.API_SCHEMA,
                "audience": "external",
                "project": package,
                "declarations": [{"id": package}],
                "exposures": [],
            },
            "coverage": {
                "schemaVersion": docs.COVERAGE_SCHEMA,
                "audience": "external",
                "symbols": {"total": 1, "documented": 1, "percent": 100},
                "parameters": {"total": 0, "documented": 0, "percent": 100},
            },
        }
        for kind, value in values.items():
            artifacts[kind].parent.mkdir(parents=True, exist_ok=True)
            artifacts[kind].write_text(json.dumps(value), encoding="utf-8")
        artifacts["markdown"].parent.mkdir(parents=True, exist_ok=True)
        artifacts["markdown"].write_text(f"# {package}\n", encoding="utf-8")

    def test_public_views_overlap_without_exceeding_three_native_commands(self) -> None:
        first_wave = threading.Barrier(3, timeout=3)
        lock = threading.Lock()
        observed = {"active": 0, "peak": 0, "entered": 0}

        def check(cjdoc, project, timeout):
            with lock:
                observed["active"] += 1
                observed["peak"] = max(observed["peak"], observed["active"])
                observed["entered"] += 1
                join_first_wave = observed["entered"] <= 3
            try:
                if join_first_wave:
                    first_wave.wait()
                return {"status": "PASS", "returncode": 0}
            finally:
                with lock:
                    observed["active"] -= 1

        with tempfile.TemporaryDirectory(prefix="wirestack-docs-concurrency-") as directory:
            root = Path(directory)
            source = root / "src/package.cj"
            source.parent.mkdir()
            source.write_text("package wirestack\n", encoding="utf-8")
            with mock.patch.object(docs, "resolve_cjdoc", return_value=("cjdoc", "0.7.2")), \
                    mock.patch.object(docs, "public_source_paths", return_value=[source]), \
                    mock.patch.object(docs, "_copy_public_view"), \
                    mock.patch.object(docs, "_check", side_effect=check), \
                    mock.patch.object(docs, "_generate_layer", side_effect=self._generate_fixture_layer):
                report = docs.build_report(root)
        self.assertEqual("PASS", report["status"], report["issues"])
        self.assertEqual(3, observed["peak"])
        self.assertEqual(0, observed["active"])

    def test_html_rendering_can_progress_while_an_unrelated_view_is_pending(self) -> None:
        html_started = threading.Event()

        def generate(cjdoc, project, output, timeout, package, commands):
            if package == "wirestack":
                self.assertTrue(html_started.wait(3), "HTML waited for an unrelated view")
            self._generate_fixture_layer(cjdoc, project, output, timeout, package, commands)

        def render(cjdoc, project, doc_ir, output, timeout, fmt):
            artifacts = docs._artifact_paths(output)
            artifacts["html"].parent.mkdir(parents=True)
            artifacts["html"].write_text("<html>qualified view</html>\n", encoding="utf-8")
            artifacts["search"].write_text("const searchIndex = [];\n", encoding="utf-8")
            html_started.set()
            return {"status": "PASS", "returncode": 0}

        with tempfile.TemporaryDirectory(prefix="wirestack-docs-html-progress-") as directory:
            root = Path(directory)
            source = root / "src/package.cj"
            source.parent.mkdir()
            source.write_text("package wirestack\n", encoding="utf-8")
            with mock.patch.object(docs, "resolve_cjdoc", return_value=("cjdoc", "0.7.2")), \
                    mock.patch.object(docs, "public_source_paths", return_value=[source]), \
                    mock.patch.object(docs, "_copy_public_view"), \
                    mock.patch.object(docs, "_check", return_value={"status": "PASS", "returncode": 0}), \
                    mock.patch.object(docs, "_generate_layer", side_effect=generate), \
                    mock.patch.object(docs, "_render", side_effect=render):
                report = docs.build_report(root, include_html=True)
        self.assertEqual("PASS", report["status"], report["issues"])

    def test_failed_view_cannot_publish_successful_sibling_artifacts(self) -> None:
        sibling_staged = threading.Event()

        def generate(cjdoc, project, output, timeout, package, commands):
            self._generate_fixture_layer(cjdoc, project, output, timeout, package, commands)
            if package == "wirestack":
                sibling_staged.set()

        def check(cjdoc, project, timeout):
            if project.parent.name == "combined":
                self.assertTrue(sibling_staged.wait(3), "a successful sibling must already be staged")
                return {"status": "FAIL", "returncode": 1}
            return {"status": "PASS", "returncode": 0}

        with tempfile.TemporaryDirectory(prefix="wirestack-docs-publication-") as directory:
            root = Path(directory)
            source = root / "src/package.cj"
            source.parent.mkdir()
            source.write_text("package wirestack\n", encoding="utf-8")
            published = root / "docs/api/generated/docs.json"
            published.parent.mkdir(parents=True)
            published.write_bytes(b"previous qualified artifacts\n")
            with mock.patch.object(docs, "resolve_cjdoc", return_value=("cjdoc", "0.7.2")), \
                    mock.patch.object(docs, "public_source_paths", return_value=[source]), \
                    mock.patch.object(docs, "_copy_public_view"), \
                    mock.patch.object(docs, "_check", side_effect=check), \
                    mock.patch.object(docs, "_generate_layer", side_effect=generate):
                report = docs.build_report(root)
            self.assertEqual("FAIL", report["status"])
            self.assertEqual("CJDOC_CHECK", report["issues"][0]["code"])
            self.assertEqual(b"previous qualified artifacts\n", published.read_bytes())
            self.assertFalse((published.parent / "api-surface.json").exists())


if __name__ == "__main__":
    unittest.main()
