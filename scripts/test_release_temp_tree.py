#!/usr/bin/env python3

import pathlib
import sys
import tempfile
import unittest


sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

from release_temp_tree import validate_manifest_closure


class ReleaseTempTreeTest(unittest.TestCase):
    def fixture(self, root: pathlib.Path) -> list[pathlib.Path]:
        (root / "src").mkdir()
        (root / "src" / "test_core.cj").write_text("package fixture\n", encoding="utf-8")
        (root / "scripts").mkdir()
        (root / "scripts" / "helper.py").write_text("VALUE = 1\n", encoding="utf-8")
        (root / "scripts" / "driver.py").write_text(
            "from helper import VALUE\n"
            "# The gate also executes scripts/helper.py.\n",
            encoding="utf-8",
        )
        return [
            pathlib.Path("src/test_core.cj"),
            pathlib.Path("scripts/driver.py"),
            pathlib.Path("scripts/helper.py"),
        ]

    def test_accepts_dependency_closed_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            validate_manifest_closure(root, self.fixture(root))

    def test_rejects_missing_core_test(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            paths = self.fixture(root)
            (root / "src" / "test_limits.cj").write_text("package fixture\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "test_limits.cj"):
                validate_manifest_closure(root, paths)

    def test_rejects_missing_executed_script(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            paths = self.fixture(root)
            paths.remove(pathlib.Path("scripts/helper.py"))
            with self.assertRaisesRegex(ValueError, "scripts/helper.py"):
                validate_manifest_closure(root, paths)


if __name__ == "__main__":
    unittest.main()
