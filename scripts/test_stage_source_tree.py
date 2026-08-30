#!/usr/bin/env python3

import pathlib
import os
import sys
import tempfile
import unittest


sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

from stage_source_tree import assert_source_only, stage_source_tree


class StageSourceTreeTest(unittest.TestCase):
    def test_copies_sources_and_excludes_generated_state(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            source = root / "source"
            destination = root / "stage"
            (source / "src").mkdir(parents=True)
            (source / "src" / "library.cj").write_text("package example\n", encoding="utf-8")
            (source / "packages" / "demo" / "target").mkdir(parents=True)
            (source / "packages" / "demo" / "target" / "generated.cjo").write_bytes(b"object")
            (source / "packages" / "demo" / "build-script-cache").mkdir()
            (source / "packages" / "demo" / "build-script-cache" / "build-script").write_bytes(b"binary")
            (source / "benchmarks" / "results").mkdir(parents=True)
            (source / "benchmarks" / "results" / "stale.json").write_text("{}", encoding="utf-8")
            (source / "native").mkdir()
            (source / "native" / "stale.o").write_bytes(b"object")

            copied = stage_source_tree(source, destination)

            self.assertEqual(copied, 1)
            self.assertEqual((destination / "src" / "library.cj").read_text(encoding="utf-8"),
                             "package example\n")
            self.assertFalse((destination / "packages" / "demo" / "target").exists())
            self.assertFalse((destination / "packages" / "demo" / "build-script-cache").exists())
            self.assertFalse((destination / "benchmarks" / "results").exists())
            self.assertFalse((destination / "native" / "stale.o").exists())
            assert_source_only(destination)

    def test_rejects_nonempty_destination(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            source = root / "source"
            destination = root / "stage"
            source.mkdir()
            destination.mkdir()
            (destination / "existing").write_text("keep", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "destination is not empty"):
                stage_source_tree(source, destination)

    def test_verifier_rejects_generated_state(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            stage = pathlib.Path(temporary)
            (stage / "nested" / "build-script-cache").mkdir(parents=True)
            with self.assertRaisesRegex(ValueError, "build-script-cache"):
                assert_source_only(stage)

    def test_rejects_adversarial_generated_artifacts(self) -> None:
        samples = {
            "native-tool": b"\x7fELFpayload",
            "tool.exe": b"MZpayload",
            "library.jar": b"PK\x03\x04payload",
            "nested.zip": b"PK\x03\x04payload",
            "coverage.profraw": b"profile",
            "coverage.lcov": b"TN:\n",
            "nested.tar.gz": b"archive",
        }
        with tempfile.TemporaryDirectory() as temporary:
            stage = pathlib.Path(temporary)
            for name, content in samples.items():
                path = stage / name
                path.write_bytes(content)
                if name == "native-tool":
                    os.chmod(path, 0o755)
            with self.assertRaises(ValueError) as error:
                assert_source_only(stage)
            for name in samples:
                self.assertIn(name, str(error.exception))

    def test_allows_text_scripts_but_rejects_unknown_executable(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            stage = pathlib.Path(temporary)
            script = stage / "tool"
            script.write_text("#!/usr/bin/env python3\nprint('ok')\n", encoding="utf-8")
            os.chmod(script, 0o755)
            assert_source_only(stage)
            script.write_text("opaque executable\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "tool"):
                assert_source_only(stage)


if __name__ == "__main__":
    unittest.main()
