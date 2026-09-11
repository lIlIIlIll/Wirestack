#!/usr/bin/env python3
"""Regression tests for documentation retained in generated Doc IR."""
from copy import deepcopy
import unittest

from check_api_documentation import validate


def fixture():
    doc = {"summary": "Read a value.", "tags": [{"name": "return", "description": "Value."}]}
    owner = {"id": "owner", "name": "Example", "qualifiedName": "yjson.Example",
             "ownerId": None, "visibility": "public", "kind": "class",
             "parameters": [], "documentation": deepcopy(doc)}
    member = {"id": "method", "name": "read", "qualifiedName": "yjson.Example.read",
              "ownerId": "owner", "visibility": "public", "kind": "function",
              "parameters": [{"name": "text", "documentation": "Input JSON."}],
              "returnType": {"spelling": "String"}, "documentation": deepcopy(doc)}
    return {"schemaVersion": "cjdoc.doc-ir/8", "project": {"name": "yjson"},
            "declarations": [owner, member]}


class DocumentationContractTest(unittest.TestCase):
    def check(self, document):
        return validate(document, {"Example": {"read": 1}})

    def test_accepts_bound_comments(self):
        report = self.check(fixture())
        self.assertEqual(report["requiredDeclarations"], 2)
        self.assertEqual(report["documentedRequiredParameters"], 1)

    def test_rejects_comment_not_bound_by_cjdoc(self):
        document = fixture()
        document["declarations"][1]["documentation"] = None
        with self.assertRaisesRegex(ValueError, "missing bound documentation summary"):
            self.check(document)

    def test_rejects_whitespace_summary(self):
        document = fixture()
        document["declarations"][0]["documentation"]["summary"] = " \n"
        with self.assertRaisesRegex(ValueError, "summary"):
            self.check(document)

    def test_rejects_missing_bound_parameter(self):
        document = fixture()
        document["declarations"][1]["parameters"][0]["documentation"] = None
        with self.assertRaisesRegex(ValueError, "@param text"):
            self.check(document)

    def test_rejects_missing_return(self):
        document = fixture()
        document["declarations"][1]["documentation"]["tags"] = []
        with self.assertRaisesRegex(ValueError, "@return"):
            self.check(document)

    def test_checks_every_overload_and_new_member(self):
        document = fixture()
        extra = deepcopy(document["declarations"][1])
        extra["id"] = "another-method"
        extra["documentation"] = None
        document["declarations"].append(extra)
        with self.assertRaisesRegex(ValueError, "summary"):
            self.check(document)

    def test_rejects_disappearing_overload(self):
        with self.assertRaisesRegex(ValueError, "expected at least 2"):
            validate(fixture(), {"Example": {"read": 2}})

    def test_rejects_missing_type(self):
        with self.assertRaisesRegex(ValueError, "exactly one public type"):
            validate(fixture(), {"Missing": {"read": 1}})

    def test_unit_function_does_not_require_return_tag(self):
        document = fixture()
        document["declarations"][1]["returnType"]["spelling"] = "Unit"
        document["declarations"][1]["documentation"]["tags"] = []
        self.check(document)

    def test_rejects_empty_contract(self):
        with self.assertRaisesRegex(ValueError, "nonempty"):
            validate(fixture(), {})

    def test_rejects_wrong_schema(self):
        document = fixture()
        document["schemaVersion"] = "other"
        with self.assertRaisesRegex(ValueError, "Doc IR v8"):
            self.check(document)


if __name__ == "__main__":
    unittest.main()
