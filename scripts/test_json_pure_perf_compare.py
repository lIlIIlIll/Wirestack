#!/usr/bin/env python3

import importlib.util
import pathlib
import subprocess
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
            "packages/yjson_macros/src/json_codec.cj": "macro codec\n",
            "packages/yjson_macros/src/json_literal.cj": "macro literal\n",
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

    def test_product_digest_ignores_unmeasured_literal_macro(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            self.make_tree(root)
            initial = MODULE.manifest_digest(MODULE.product_manifest(root))
            literal = root / "packages/yjson_macros/src/json_literal.cj"
            literal.write_text("changed literal\n", encoding="utf-8")
            self.assertEqual(
                MODULE.manifest_digest(MODULE.product_manifest(root)), initial
            )
            codec = root / "packages/yjson_macros/src/json_codec.cj"
            codec.write_text("changed codec\n", encoding="utf-8")
            self.assertNotEqual(
                MODULE.manifest_digest(MODULE.product_manifest(root)), initial
            )

    def test_standalone_macro_dependency_is_canonicalized(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            data = (
                "[dependencies]\n"
                f'yjson_macros = {{ {MODULE.STANDALONE_MACRO_GIT} }}\n'
            ).encode("utf-8")
            normalized = MODULE.canonical_benchmark_input_bytes(
                root, "packages/benchmarks/cjpm.toml", data
            ).decode("utf-8")
            self.assertIn('yjson_macros = { path = "../yjson_macros" }', normalized)
            self.assertNotIn("commitId", normalized)

    def test_legacy_standalone_macro_dependency_is_canonicalized(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            data = (
                "[dependencies]\n"
                f'yjson_macros = {{ {MODULE.LEGACY_STANDALONE_MACRO_GIT} }}\n'
            ).encode("utf-8")
            normalized = MODULE.canonical_benchmark_input_bytes(
                root, "packages/benchmarks/cjpm.toml", data
            ).decode("utf-8")
            self.assertIn('yjson_macros = { path = "../yjson_macros" }', normalized)
            self.assertNotIn("commitId", normalized)

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

    def test_enforce_rejects_tracked_build_time_mutation(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            self.make_tree(root)
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            subprocess.run(["git", "-C", str(root), "config", "user.name", "Fixture"], check=True)
            subprocess.run(
                ["git", "-C", str(root), "config", "user.email", "fixture@example.invalid"],
                check=True,
            )
            subprocess.run(["git", "-C", str(root), "add", "."], check=True)
            subprocess.run(
                ["git", "-C", str(root), "-c", "core.hooksPath=/dev/null", "commit", "-q",
                 "-m", "test(provenance): create fixture"],
                check=True,
            )
            before = MODULE.source_identity(root)
            (root / "cjpm.toml").write_text("mutated during build\n", encoding="utf-8")
            after = MODULE.source_identity(root)
            with self.assertRaisesRegex(SystemExit, "post-build source drift"):
                MODULE.verify_post_build_source_identity("candidate", before, after, True)


class PurePerfGatePolicyTest(unittest.TestCase):
    def setUp(self) -> None:
        self.cases = ("target", "ordinary")
        self.comparisons = {
            "target": {
                "ratio": 0.99,
                "improvement_percent": 1.0,
                "candidate_wins": 1,
            },
            "ordinary": {
                "ratio": 1.0,
                "improvement_percent": 0.0,
                "candidate_wins": 5,
            },
        }
        self.baseline = {case: {"cv_percent": 1.0} for case in self.cases}
        self.candidate = {case: {"cv_percent": 1.0} for case in self.cases}

    def test_release_mode_does_not_require_target_improvement(self) -> None:
        gates = MODULE.evaluate_gates(
            self.cases,
            self.comparisons,
            self.baseline,
            self.candidate,
            "release",
            (),
            None,
        )
        self.assertFalse(gates["target_gate_required"])
        self.assertIsNone(gates["targets_meet_improvement_and_5_of_11_wins"])
        self.assertTrue(gates["passed"])

    def test_optimization_mode_requires_target_improvement(self) -> None:
        gates = MODULE.evaluate_gates(
            self.cases,
            self.comparisons,
            self.baseline,
            self.candidate,
            "optimization",
            ("target",),
            5.0,
        )
        self.assertTrue(gates["target_gate_required"])
        self.assertFalse(gates["targets_meet_improvement_and_5_of_11_wins"])
        self.assertFalse(gates["passed"])

    def test_release_mode_still_rejects_regression(self) -> None:
        self.comparisons["ordinary"]["ratio"] = 1.06
        gates = MODULE.evaluate_gates(
            self.cases,
            self.comparisons,
            self.baseline,
            self.candidate,
            "release",
            (),
            None,
        )
        self.assertFalse(gates["passed"])

    def test_target_options_require_optimization_mode(self) -> None:
        with self.assertRaisesRegex(
            SystemExit, "--target-case requires --gate-mode optimization"
        ):
            MODULE.resolve_target_improvement_percent("release", ("target",), None)
        with self.assertRaisesRegex(
            SystemExit, "optimization requires at least one --target-case"
        ):
            MODULE.resolve_target_improvement_percent("optimization", (), None)


if __name__ == "__main__":
    unittest.main()
