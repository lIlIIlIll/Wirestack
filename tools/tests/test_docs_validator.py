import json
import tempfile
import unittest
from pathlib import Path

from tools import docs_validator


class DocsValidatorTest(unittest.TestCase):
    def fixture(self, files):
        temporary = tempfile.TemporaryDirectory()
        root = Path(temporary.name)
        for name, content in files.items():
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding="utf-8")
        self.addCleanup(temporary.cleanup)
        return root

    def test_links_anchor_and_fence_pass(self):
        root = self.fixture({"a.md": "# A\n[go](b.md#section)\n```text\nok\n```\n", "b.md": "# Section\n"})
        report = docs_validator.validate(root, ("a.md", "b.md"), enforce_repository_facts=False)
        self.assertEqual("PASS", report["status"])

    def test_missing_escape_anchor_and_fence_fail_closed(self):
        root = self.fixture({"a.md": "# A\n[missing](x.md) [escape](../x.md) [anchor](b.md#nope)\n```\n", "b.md": "# Yes\n"})
        report = docs_validator.validate(root, ("a.md", "b.md"), enforce_repository_facts=False)
        self.assertEqual("FAIL", report["status"])
        self.assertEqual(
            {"MISSING_LINK_TARGET", "PATH_ESCAPE", "MISSING_ANCHOR", "UNCLOSED_FENCE"},
            {item["code"] for item in report["issues"]},
        )

    def test_atomic_report_preserves_existing_target_on_failure(self):
        root = self.fixture({"report.json": "old\n"})
        target = root / "report.json"
        def fail_replace(_source, _target):
            raise OSError("injected")
        with self.assertRaises(OSError):
            docs_validator.atomic_json(target, {"status": "PASS"}, replace=fail_replace)
        self.assertEqual("old\n", target.read_text(encoding="utf-8"))
        docs_validator.atomic_json(target, {"status": "PASS"})
        self.assertEqual("PASS", json.loads(target.read_text())["status"])

    def test_report_is_bounded(self):
        root = self.fixture({"a.md": "# A\n" + "[x](missing.md)\n" * 200})
        report = docs_validator.validate(root, ("a.md",), enforce_repository_facts=False)
        self.assertLessEqual(len(report["issues"]), docs_validator.MAX_ISSUES)


if __name__ == "__main__":
    unittest.main()
