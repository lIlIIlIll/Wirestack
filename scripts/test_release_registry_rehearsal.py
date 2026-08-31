#!/usr/bin/env python3

import pathlib
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

from release_registry_rehearsal import (
    bundle_leaf,
    bundle_output_path,
    delegate_to_candidate,
    deterministic_archive,
    inspect_artifact,
    ensure_module_unchanged,
    module_source_digest,
    rewrite_readme_links,
    validate_candidate_tree,
)
from release_temp_tree import manifest_paths, release_identity, write_provenance


class ReleaseRegistryRehearsalTest(unittest.TestCase):
    def candidate(self, root: pathlib.Path, clean: bool = False) -> pathlib.Path:
        candidate = root / "release-candidate"
        (candidate / "release").mkdir(parents=True)
        (candidate / "scripts").mkdir()
        (candidate / "scripts" / "release_registry_rehearsal.py").write_text(
            "#!/usr/bin/env python3\n", encoding="utf-8")
        (candidate / "release" / "release-files.txt").write_text(
            "release/release-files.txt\n"
            "scripts/release_registry_rehearsal.py\n",
            encoding="utf-8",
        )
        if clean:
            identity = release_identity(
                candidate,
                manifest_paths(candidate / "release" / "release-files.txt"),
                False,
            )
            identity.update({
                "clean_enforced": True,
                "commit": "1" * 40,
                "tree": "2" * 40,
            })
            write_provenance(candidate, identity)
        return candidate

    def test_accepts_complete_manifest_candidate_without_git_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            validate_candidate_tree(self.candidate(pathlib.Path(temporary)))

    def test_rejects_git_checkout_as_candidate(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            candidate = self.candidate(pathlib.Path(temporary))
            (candidate / ".git").mkdir()
            with self.assertRaisesRegex(RuntimeError, "refuses a Git checkout"):
                validate_candidate_tree(candidate)

    def test_rejects_incomplete_candidate(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            candidate = self.candidate(pathlib.Path(temporary))
            (candidate / "scripts" / "release_registry_rehearsal.py").unlink()
            with self.assertRaisesRegex(RuntimeError, "candidate tree is incomplete"):
                validate_candidate_tree(candidate)

    def test_requires_and_verifies_clean_candidate_provenance(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            with self.assertRaisesRegex(RuntimeError, "clean provenance is missing"):
                validate_candidate_tree(self.candidate(root), require_clean=True)

        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            candidate = self.candidate(root, clean=True)
            validate_candidate_tree(candidate, require_clean=True)
            (candidate / "scripts" / "release_registry_rehearsal.py").write_text(
                "# mutated\n", encoding="utf-8")
            with self.assertRaisesRegex(RuntimeError, "payload_sha256"):
                validate_candidate_tree(candidate, require_clean=True)

    def test_rejects_extra_native_source_after_provenance(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            candidate = self.candidate(pathlib.Path(temporary), clean=True)
            native = candidate / "native"
            native.mkdir()
            (native / "injected.c").write_text("int injected;\n", encoding="utf-8")
            with self.assertRaisesRegex(RuntimeError, "unexpected candidate file: native/injected.c"):
                validate_candidate_tree(candidate, require_clean=True)

    def test_delegates_execution_to_candidate_runner(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            candidate = self.candidate(root)
            destination = root / "registry-rehearsal"
            completed = subprocess.CompletedProcess([], 0)
            with mock.patch("release_registry_rehearsal.subprocess.run", return_value=completed) as run:
                result = delegate_to_candidate(candidate, destination, ["--skip-consumers"])
            self.assertEqual(result, 0)
            command = run.call_args.args[0]
            self.assertEqual(pathlib.Path(command[1]),
                             candidate / "scripts" / "release_registry_rehearsal.py")
            self.assertIn("--candidate-execution", command)
            self.assertIn("--skip-consumers", command)
            self.assertEqual(run.call_args.kwargs["cwd"], candidate)

    def test_rejects_destination_inside_candidate(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            candidate = self.candidate(pathlib.Path(temporary))
            with self.assertRaisesRegex(RuntimeError, "outside the candidate tree"):
                delegate_to_candidate(candidate, candidate / "output", [])

    def test_deterministic_archive_is_byte_identical_and_zero_timestamp(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            module = root / "fixture"
            module.mkdir()
            (module / "cjpm.toml").write_text("[package]\n", encoding="utf-8")
            first = root / "first.cjp"
            second = root / "second.cjp"
            deterministic_archive(module, first, "0.1.0")
            deterministic_archive(module, second, "0.1.0")
            self.assertEqual(first.read_bytes(), second.read_bytes())
            self.assertEqual(first.read_bytes()[4:8], b"\0\0\0\0")

    def test_bundle_reproduction_output_name_does_not_define_cjpm_input(self) -> None:
        # Verification artifacts intentionally use a distinct filename. The
        # cjpm bundle input remains <package>-<version>.cjp inside target/.
        source = bundle_output_path(pathlib.Path("/tmp/yjson"), "0.1.0")
        verification = pathlib.Path("artifacts/.yjson-0.1.0.verify.cjp")
        self.assertNotEqual(source.name, verification.name)
        self.assertEqual(source, pathlib.Path("/tmp/yjson/target/yjson-0.1.0.cjp"))

    def test_bundle_removes_generated_lock_before_source_recheck(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            module = root / "yjson"
            module.mkdir()
            (module / "cjpm.toml").write_text("[package]\n", encoding="utf-8")

            def fake_run(_command, cwd, _env):
                (cwd / "cjpm.lock").write_text(
                    "version = 0\n\n[requires]\n", encoding="utf-8")
                (cwd / "target").mkdir()
                deterministic_archive(
                    cwd,
                    cwd / "target" / "yjson-0.1.0.cjp",
                    "0.1.0",
                )

            output = root / "artifact.cjp"
            with mock.patch("release_registry_rehearsal.run", side_effect=fake_run):
                bundle_leaf(module, output, {}, "", "0.1.0")
            self.assertFalse((module / "cjpm.lock").exists())
            self.assertTrue(output.is_file())

    def test_rewrites_repository_readme_link_to_exact_commit(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            candidate = pathlib.Path(temporary)
            source = candidate / "packages" / "fixture" / "README.md"
            source.parent.mkdir(parents=True)
            target = candidate / "docs" / "guide.md"
            target.parent.mkdir()
            target.write_text("# Guide\n", encoding="utf-8")
            module = candidate / "stage" / "fixture"
            module.mkdir(parents=True)
            rewritten = rewrite_readme_links(
                "[Guide](../../docs/guide.md)\n",
                source,
                module,
                candidate,
                "a" * 40,
            )
            self.assertIn(f"/blob/{'a' * 40}/docs/guide.md", rewritten)

    def test_artifact_inspection_rejects_broken_local_readme_link(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            module = root / "fixture"
            module.mkdir()
            (module / "cjpm.toml").write_text("[package]\n", encoding="utf-8")
            (module / "README.md").write_text("[Missing](docs/missing.md)\n", encoding="utf-8")
            archive = root / "fixture.cjp"
            deterministic_archive(module, archive, "0.1.0")
            with self.assertRaisesRegex(RuntimeError, "README link is broken"):
                inspect_artifact("fixture", archive, "0.1.0")

    def test_detects_package_source_mutation_during_artifact_build(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            module = pathlib.Path(temporary) / "fixture"
            module.mkdir()
            source = module / "cjpm.toml"
            source.write_text("[package]\n", encoding="utf-8")
            before = module_source_digest(module)
            (module / "target").mkdir()
            (module / "target" / "ignored.o").write_bytes(b"build output")
            ensure_module_unchanged(module, before)
            source.write_text("[package]\nname = \"changed\"\n", encoding="utf-8")
            with self.assertRaisesRegex(RuntimeError, "package source changed"):
                ensure_module_unchanged(module, before)


if __name__ == "__main__":
    unittest.main()
