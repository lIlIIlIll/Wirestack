#!/usr/bin/env python3

import importlib.util
import pathlib
import tempfile
import unittest


SCRIPT = pathlib.Path(__file__).with_name("json_pure_perf_compare.py")
SPEC = importlib.util.spec_from_file_location("json_pure_perf_compare", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class PurePerfProvenanceTest(unittest.TestCase):
    def make_tree(self, root: pathlib.Path) -> None:
        files = {
            "cjpm.toml": "root manifest\n",
            "cjpm.lock": "root lock\n",
            "packages/benchmarks/cjpm.toml": "benchmark manifest\n",
            "packages/benchmarks/cjpm.lock": "benchmark lock\n",
            "packages/benchmarks/build.cj": "main() {}\n",
            "packages/benchmarks/src/bench.cj": "package bench\n",
            "packages/yjson_all/cjpm.toml": "aggregate manifest\n",
            "packages/yjson_all/cjpm.lock": "aggregate lock\n",
            "packages/yjson_macros/cjpm.toml": "macro manifest\n",
            "packages/yjson_macros/cjpm.lock": "macro lock\n",
            "scripts/build_native_scanner.py": "pass\n",
            "native/yjson_scanner.c": "void scanner(void) {}\n",
            "native/yjson_scanner.h": "void scanner(void);\n",
            "native/yjson_compact.c": "void compact(void) {}\n",
            "native/yjson_compact.h": "void compact(void);\n",
        }
        for relative, content in files.items():
            path = root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding="utf-8")

    def test_harness_digest_changes_for_every_declared_build_input(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            self.make_tree(root)
            initial = MODULE.manifest_digest(MODULE.harness_manifest(root))
            for relative in (
                "cjpm.toml",
                "cjpm.lock",
                "packages/benchmarks/cjpm.toml",
                "packages/benchmarks/cjpm.lock",
                "packages/benchmarks/build.cj",
                "scripts/build_native_scanner.py",
                "native/yjson_scanner.c",
            ):
                path = root / relative
                original = path.read_text(encoding="utf-8")
                path.write_text(original + "changed\n", encoding="utf-8")
                self.assertNotEqual(
                    MODULE.manifest_digest(MODULE.harness_manifest(root)), initial,
                    relative,
                )
                path.write_text(original, encoding="utf-8")

    def test_artifact_identity_rejects_symlink_and_hashes_regular_binary(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            path = MODULE.binary(root)
            path.parent.mkdir(parents=True)
            path.write_bytes(b"benchmark-binary")
            identity = MODULE.artifact_identity(root)
            self.assertEqual(identity["size_bytes"], 16)
            self.assertEqual(identity["sha256"], MODULE.sha256_file(path))
            path.unlink()
            target = root / "replacement"
            target.write_bytes(b"replacement")
            path.symlink_to(target)
            with self.assertRaises(SystemExit):
                MODULE.artifact_identity(root)


if __name__ == "__main__":
    unittest.main()
