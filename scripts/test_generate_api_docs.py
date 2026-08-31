#!/usr/bin/env python3
"""Tests for cjdoc Doc IR release validation."""

from __future__ import annotations

from collections import Counter
import json
import pathlib
import tempfile
import unittest

from generate_api_docs import ApiDocsError, validate_doc_ir


class ApiDocsValidationTest(unittest.TestCase):
    def write_document(
        self,
        root: pathlib.Path,
        *,
        declarations: list[dict[str, object]] | None = None,
        unsupported: list[dict[str, object]] | None = None,
        diagnostics: list[dict[str, object]] | None = None,
    ) -> pathlib.Path:
        document = {
            "schemaVersion": "cjdoc.doc-ir/7",
            "generator": {"name": "cjdoc", "version": "0.6.0"},
            "project": {"name": "yjson_test", "kind": "package"},
            "configuration": {"audience": "external"},
            "packages": [{"name": "yjson_test"}],
            "declarations": declarations or [],
            "unsupportedDeclarations": unsupported or [],
            "diagnostics": diagnostics or [],
            "status": "complete",
        }
        path = root / "docs.json"
        path.write_text(json.dumps(document), encoding="utf-8")
        return path

    def validate(
        self,
        path: pathlib.Path,
        expected: Counter[tuple[str, str]] | None = None,
    ) -> dict[str, object]:
        return validate_doc_ir(
            path,
            package_name="yjson_test",
            generator_version="0.6.0",
            expected_unsupported=expected or Counter(),
        )

    def test_accepts_public_doc_ir(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = self.write_document(
                pathlib.Path(directory),
                declarations=[{"name": "Value", "visibility": "public"}],
            )
            report = self.validate(path)
            self.assertEqual(report["publicDeclarations"], 1)
            self.assertEqual(report["unsupported"], [])

    def test_accepts_exact_public_macro_limitation(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = self.write_document(
                pathlib.Path(directory),
                unsupported=[{"kind": "macro", "name": "JsonCodec"}],
                diagnostics=[{"severity": "warning", "code": "CJDOC1009"}],
            )
            report = self.validate(
                path, Counter({("macro", "JsonCodec"): 1}))
            self.assertEqual(report["unsupportedPublicMacros"], ["JsonCodec"])

    def test_rejects_unreviewed_unsupported_declaration(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = self.write_document(
                pathlib.Path(directory),
                declarations=[{"name": "Value", "visibility": "public"}],
                unsupported=[{"kind": "macroInvocation", "name": "Derive"}],
            )
            with self.assertRaisesRegex(ApiDocsError, "does not match cjdoc policy"):
                self.validate(path)

    def test_rejects_error_diagnostic(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = self.write_document(
                pathlib.Path(directory),
                declarations=[{"name": "Value", "visibility": "public"}],
                diagnostics=[{"severity": "error", "code": "CJDOC9999"}],
            )
            with self.assertRaisesRegex(ApiDocsError, "reported errors"):
                self.validate(path)


if __name__ == "__main__":
    unittest.main()
