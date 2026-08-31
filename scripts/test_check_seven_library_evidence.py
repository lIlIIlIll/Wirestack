#!/usr/bin/env python3
"""Regression tests for the current seven-library evidence checker."""

from __future__ import annotations

import contextlib
import csv
import io
import json
import os
import pathlib
import subprocess
import tarfile
import tempfile
import unittest

import check_seven_library_evidence as checker


def write(path: pathlib.Path, text: str = "fixture\n") -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def git(root: pathlib.Path, *args: str, input_text: str | None = None) -> str:
    completed = subprocess.run(
        ["git", "-C", str(root), *args],
        input=input_text,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=True,
    )
    return completed.stdout.strip()


class EvidenceFixture:
    def __init__(self, root: pathlib.Path) -> None:
        self.root = root
        self.evidence_relative = (
            "benchmarks/results/full-seven-library/2099-01-01-main-fixture"
        )
        self.result_relative = (
            "docs/performance/results/2099-01-01-main-seven-library.md"
        )
        self.evidence = root / self.evidence_relative
        self.result = root / self.result_relative
        self.marker_path = root / checker.DEFAULT_MARKER
        self.formal = (
            {"file": "formal-main-11-1.tar.gz", "root": "formal-main-11-1"},
            {"file": "formal-main-11-2.tar.gz", "root": "formal-main-11-2"},
        )
        self.harness = {"file": "harness-source.tar.gz", "root": "harness"}
        self._create_sources()
        git(root, "init", "-q")
        git(root, "config", "user.name", "Evidence Test")
        git(root, "config", "user.email", "evidence@example.invalid")
        git(root, "add", ".")
        git(root, "commit", "-q", "-m", "test: measured source")
        self.measured_commit = git(root, "rev-parse", "HEAD")
        self.product_digest = checker.manifest_digest(checker.product_manifest(root))
        self.harness_digest = checker.manifest_digest(checker.harness_manifest(root))
        self.candidate = checker.release_candidate_binding(
            root, self.product_digest, self.harness_digest
        )
        self.write_evidence()
        git(root, "add", "-f", ".")
        git(root, "commit", "-q", "-m", "test: bind performance evidence")

    def _create_sources(self) -> None:
        write(
            self.root / "cjpm.toml",
            """[package]
cjc-version = "1.1.0"
name = "yjson"
version = "0.1.0"

[dependencies]

[test-dependencies]
yjson_macros = { path = "packages/yjson_macros" }
""",
        )
        write(self.root / "cjpm.lock", "version = 0\n")
        write(
            self.root / "packages/yjson_macros/cjpm.toml",
            """[package]
cjc-version = "1.1.0"
name = "yjson_macros"
version = "0.1.0"

[dependencies]
yjson = { path = "../.." }
""",
        )
        write(self.root / "packages/yjson_macros/cjpm.lock", "version = 0\n")
        write(
            self.root / "release/release-graph.toml",
            """schema_version = 1
release_version = "0.1.0"
status = "migration"

[[packages]]
name = "yjson"
role = "core"
development_manifest = "cjpm.toml"
release_manifest = "release/package-manifests/yjson.toml"
source_root = "src"
stage_kind = "core"
stability = "stable"
leaf_bundle = true
dependencies = []
test_dependencies = ["yjson_macros"]

[[packages]]
name = "yjson_macros"
role = "macros"
development_manifest = "packages/yjson_macros/cjpm.toml"
release_manifest = "release/package-manifests/yjson_macros.toml"
source_root = "packages/yjson_macros/src"
stage_kind = "package"
stability = "stable"
leaf_bundle = false
dependencies = ["yjson"]
""",
        )
        write(
            self.root / "release/package-manifests/yjson.toml",
            """[package]
cjc-version = "1.1.0"
name = "yjson"
version = "0.1.0"

[dependencies]
""",
        )
        write(
            self.root / "release/package-manifests/yjson_macros.toml",
            """[package]
cjc-version = "1.1.0"
name = "yjson_macros"
version = "0.1.0"

[dependencies]
yjson = "0.1.0"
""",
        )
        paths = (
            "src/lib.cj",
            "packages/benchmarks/cjpm.toml",
            "packages/benchmarks/cjpm.lock",
            "packages/benchmarks/build.cj",
            "packages/benchmarks/src/bench.cj",
            "packages/yjson_macros/src/macros.cj",
            "scripts/build_native_scanner.py",
            "native/yjson_scanner.c",
            "native/yjson_scanner.h",
            "native/yjson_compact.c",
            "native/yjson_compact.h",
        )
        for index, relative in enumerate(paths):
            write(self.root / relative, f"fixture-{index}\n")

    def metadata(self, batch: int, **overrides: object) -> dict[str, object]:
        value: dict[str, object] = {
            "started_at_utc": f"2099-01-01T00:0{batch}:00+00:00",
            "host": "fixture-server",
            "platform": "Linux-fixture-x86_64",
            "cpu_selection": {
                "sample_seconds": 30,
                "selected_cpu": batch,
                "selected_sibling": batch + 48,
                "acceptable_both_threads_below_1_percent": True,
                "utilization_percent": [0.0, 0.0],
            },
            "heap": "128MB",
            "runs": 11,
            "schedule": "rotating and reversed",
            "jmh": "fixture",
            "cangjie_bench": "fixture",
            "api_policy": "fastest semantically equivalent public typed API",
            "canonical_decode_payload_bytes": {"Address": 47},
            "versions": {
                "yjson_commit": self.measured_commit,
                "cjpm": "Cangjie Project Manager: fixture",
            },
            "source_sha256": {"yjson": "a" * 64},
            "lscpu": "fixture CPU",
            "affinity_probe": f"Cpus_allowed_list:\t{batch}",
            "api_paths": {"yjson": "typed"},
            "product_source_sha256": self.product_digest,
            "effective_harness_sha256": self.harness_digest,
            "measured_overlay_sha256": "b" * 64,
        }
        value.update(overrides)
        return value

    def summary(self, batch: int) -> list[dict[str, object]]:
        result: list[dict[str, object]] = []
        for workload_index, workload in enumerate(checker.WORKLOADS):
            libraries: dict[str, object] = {}
            for library_index, library in enumerate(checker.LIBRARIES):
                libraries[library] = {
                    "median_ns": float(
                        (batch * 100 + workload_index * 10 + library_index + 1) * 1000
                    ),
                    "cv_percent": float(library_index + 1) + batch / 10.0,
                }
            result.append({"workload_id": workload, "libraries": libraries})
        return result

    def summary_rows(self, batch: int, include_max_cv: bool) -> list[str]:
        rows: list[str] = []
        for workload_index, workload in enumerate(checker.WORKLOADS):
            medians = [
                f"{batch * 100 + workload_index * 10 + library_index + 1:.3f}"
                for library_index in range(len(checker.LIBRARIES))
            ]
            cells = [checker.WORKLOAD_LABELS[workload], *medians]
            if include_max_cv:
                cells.append(f"{len(checker.LIBRARIES) + batch / 10.0:.2f}%")
            rows.append("| " + " | ".join(cells) + " |")
        return rows

    def _write_formal_archive(
        self, archive: dict[str, str], batch: int, **metadata_overrides: object
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary) / archive["root"]
            root.mkdir()
            write(root / "COMPLETE", "complete\n")
            write(
                root / "metadata.json",
                json.dumps(self.metadata(batch, **metadata_overrides), indent=2) + "\n",
            )
            with (root / "manifest.csv").open("w", newline="", encoding="utf-8") as stream:
                writer = csv.writer(stream)
                writer.writerow(("round", "workload_id", "library"))
                for round_number in range(1, 12):
                    for workload in checker.WORKLOADS:
                        for library in checker.LIBRARIES:
                            writer.writerow((round_number, workload, library))
            write(root / "summary.json", json.dumps(self.summary(batch), indent=2) + "\n")
            write(root / "summary.csv", "fixture\n")
            write(root / "summary.md", "fixture\n")
            with tarfile.open(self.evidence / archive["file"], "w:gz") as output:
                output.add(root, arcname=archive["root"])

    def _write_harness_archive(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary) / self.harness["root"]
            root.mkdir()
            write(
                root / "summarize_full.py",
                "#!/usr/bin/env python3\n"
                "import argparse\n"
                "p = argparse.ArgumentParser()\n"
                "p.add_argument('root')\n"
                "p.add_argument('--min-runs')\n"
                "p.parse_args()\n",
            )
            with tarfile.open(self.evidence / self.harness["file"], "w:gz") as output:
                output.add(root, arcname=self.harness["root"])

    def marker(self) -> dict[str, object]:
        checksum_files = sorted(
            [entry["file"] for entry in self.formal] + [self.harness["file"]]
        )
        return {
            "schema_version": 2,
            "evidence_dir": self.evidence_relative,
            "result_doc": self.result_relative,
            "measured_commit": self.measured_commit,
            "product_source_sha256": self.product_digest,
            "effective_harness_sha256": self.harness_digest,
            "formal_archives": list(self.formal),
            "harness_archive": self.harness,
            "checksum_files": checksum_files,
            "candidate": dict(self.candidate),
        }

    def write_marker(self, marker: dict[str, object] | None = None) -> None:
        value = self.marker() if marker is None else marker
        write(self.marker_path, json.dumps(value, indent=2) + "\n")

    def write_checksums(self) -> None:
        names = sorted([entry["file"] for entry in self.formal] + [self.harness["file"]])
        lines = [f"{checker.sha256(self.evidence / name)}  {name}" for name in names]
        write(self.evidence / "checksums.txt", "\n".join(lines) + "\n")

    def write_evidence(self, second_metadata: dict[str, object] | None = None) -> None:
        self.evidence.mkdir(parents=True, exist_ok=True)
        self._write_formal_archive(self.formal[0], 1)
        self._write_formal_archive(self.formal[1], 2, **(second_metadata or {}))
        self._write_harness_archive()
        evidence_to_result = pathlib.PurePosixPath(
            os.path.relpath(self.result, self.evidence)
        ).as_posix()
        result_to_evidence = pathlib.PurePosixPath(
            os.path.relpath(self.evidence / "README.md", self.result.parent)
        ).as_posix()
        write(
            self.evidence / "README.md",
            f"Measured `{self.measured_commit}`. [Result]({evidence_to_result})\n",
        )
        first_rows = "\n".join(self.summary_rows(1, include_max_cv=True))
        second_rows = "\n".join(self.summary_rows(2, include_max_cv=True))
        write(
            self.result,
            f"Measured `{self.measured_commit}`. [Evidence]({result_to_evidence})\n\n"
            f"## 第一批\n\n{first_rows}\n\n"
            f"## 第二批\n\n{second_rows}\n",
        )
        readme_rows = "\n".join(self.summary_rows(2, include_max_cv=False))
        write(
            self.root / "README.md",
            f"[Current]({self.result_relative})\n\n## 性能\n\n{readme_rows}\n",
        )
        performance_target = pathlib.PurePosixPath(
            os.path.relpath(self.result, self.root / "docs/performance")
        ).as_posix()
        write(
            self.root / "docs/performance/README.md",
            f"[Current]({performance_target})\n",
        )
        self.write_checksums()
        self.write_marker()


class SevenLibraryEvidenceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temporary.name)
        self.fixture = EvidenceFixture(self.root)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_valid_fixture_passes_strict_and_integrity_modes(self) -> None:
        checker.verify(self.root, checker.DEFAULT_MARKER, integrity_only=False)
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            status = checker.main(
                ["--root", str(self.root), "--integrity-only"]
            )
        self.assertEqual(status, 0)
        self.assertIn("integrity", output.getvalue())

    def test_print_current_candidate_is_canonical_and_read_only(self) -> None:
        marker_before = self.fixture.marker_path.read_bytes()
        status_before = git(self.root, "status", "--porcelain=v1", "--untracked-files=all")
        expected = {
            "schema_version": 2,
            "measured_commit": git(self.root, "rev-parse", "HEAD"),
            "product_source_sha256": self.fixture.product_digest,
            "effective_harness_sha256": self.fixture.harness_digest,
            "candidate": self.fixture.candidate,
        }
        outputs: list[str] = []
        for _ in range(2):
            output = io.StringIO()
            error = io.StringIO()
            with contextlib.redirect_stdout(output), contextlib.redirect_stderr(error):
                status = checker.main(
                    ["--root", str(self.root), "--print-current-candidate"]
                )
            self.assertEqual(status, 0)
            self.assertEqual(error.getvalue(), "")
            outputs.append(output.getvalue())
        self.assertEqual(outputs[0], outputs[1])
        self.assertEqual(outputs[0], json.dumps(expected, indent=2, sort_keys=True) + "\n")
        self.assertEqual(self.fixture.marker_path.read_bytes(), marker_before)
        self.assertEqual(
            git(self.root, "status", "--porcelain=v1", "--untracked-files=all"),
            status_before,
        )

    def test_print_current_candidate_rejects_a_dirty_checkout(self) -> None:
        write(self.root / "untracked-candidate-input.md", "dirty\n")
        output = io.StringIO()
        error = io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(error):
            status = checker.main(
                ["--root", str(self.root), "--print-current-candidate"]
            )
        self.assertEqual(status, 1)
        self.assertEqual(output.getvalue(), "")
        self.assertIn("clean candidate checkout", error.getvalue())

    def test_strict_mode_rejects_product_source_drift(self) -> None:
        write(self.root / "src/lib.cj", "mutated\n")
        with self.assertRaisesRegex(checker.EvidenceError, "current product source differs"):
            checker.verify(self.root, checker.DEFAULT_MARKER, integrity_only=False)
        checker.verify(self.root, checker.DEFAULT_MARKER, integrity_only=True)

    def test_strict_mode_rejects_harness_drift(self) -> None:
        write(self.root / "packages/benchmarks/src/bench.cj", "mutated\n")
        with self.assertRaisesRegex(checker.EvidenceError, "current benchmark harness differs"):
            checker.verify(self.root, checker.DEFAULT_MARKER, integrity_only=False)

    def test_docs_only_change_does_not_make_measurement_stale(self) -> None:
        with self.fixture.result.open("a", encoding="utf-8") as stream:
            stream.write("More explanation without changing performance inputs.\n")
        git(self.root, "add", self.fixture.result.relative_to(self.root).as_posix())
        git(self.root, "commit", "-q", "-m", "docs: clarify performance evidence")
        checker.verify(self.root, checker.DEFAULT_MARKER, integrity_only=False)

    def test_marker_rejects_path_traversal(self) -> None:
        marker = self.fixture.marker()
        marker["evidence_dir"] = "benchmarks/results/full-seven-library/../escape"
        self.fixture.write_marker(marker)
        with self.assertRaisesRegex(checker.EvidenceError, "unsafe evidence_dir"):
            checker.verify(self.root, checker.DEFAULT_MARKER, integrity_only=True)

    def test_schema_v1_is_historical_integrity_only(self) -> None:
        marker = self.fixture.marker()
        marker["schema_version"] = 1
        del marker["candidate"]
        self.fixture.write_marker(marker)
        write(self.root / "README.md", "current release no longer advertises this history\n")
        write(self.root / "docs/performance/README.md", "historical index moved on\n")
        self.assertEqual(
            checker.verify(self.root, checker.DEFAULT_MARKER, integrity_only=True),
            1,
        )
        with self.assertRaisesRegex(checker.EvidenceError, "historical-only"):
            checker.verify(self.root, checker.DEFAULT_MARKER, integrity_only=False)

    def test_candidate_identity_must_be_internally_consistent(self) -> None:
        marker = self.fixture.marker()
        marker["candidate"]["root_lock_sha256"] = "c" * 64
        self.fixture.write_marker(marker)
        with self.assertRaisesRegex(checker.EvidenceError, "identity_sha256 is inconsistent"):
            checker.verify(self.root, checker.DEFAULT_MARKER, integrity_only=True)

    def test_package_version_binding_is_current(self) -> None:
        marker = self.fixture.marker()
        marker["candidate"]["package_version"] = "0.2.0"
        marker["candidate"]["identity_sha256"] = checker.candidate_identity_sha256(
            marker["candidate"], self.fixture.product_digest, self.fixture.harness_digest
        )
        self.fixture.write_marker(marker)
        with self.assertRaisesRegex(checker.EvidenceError, "release candidate identity differs"):
            checker.verify(self.root, checker.DEFAULT_MARKER, integrity_only=False)

    def test_lockstep_release_manifest_drift_fails_closed(self) -> None:
        path = self.root / "release/package-manifests/yjson_macros.toml"
        with path.open("a", encoding="utf-8") as stream:
            stream.write("# drift\n")
        with self.assertRaisesRegex(checker.EvidenceError, "release candidate identity differs"):
            checker.verify(self.root, checker.DEFAULT_MARKER, integrity_only=False)

    def test_release_graph_drift_fails_closed(self) -> None:
        path = self.root / "release/release-graph.toml"
        with path.open("a", encoding="utf-8") as stream:
            stream.write("# drift\n")
        with self.assertRaisesRegex(checker.EvidenceError, "release candidate identity differs"):
            checker.verify(self.root, checker.DEFAULT_MARKER, integrity_only=False)

    def test_strict_mode_requires_a_clean_candidate(self) -> None:
        write(self.root / "untracked-candidate-note.md", "dirty\n")
        with self.assertRaisesRegex(checker.EvidenceError, "clean candidate checkout"):
            checker.verify(self.root, checker.DEFAULT_MARKER, integrity_only=False)

    def test_measured_commit_must_share_candidate_release_identity(self) -> None:
        graph_path = self.root / "release/release-graph.toml"
        with graph_path.open("a", encoding="utf-8") as stream:
            stream.write("# candidate-only change\n")
        git(self.root, "add", graph_path.relative_to(self.root).as_posix())
        git(self.root, "commit", "-q", "-m", "build: change candidate graph identity")
        marker = self.fixture.marker()
        marker["candidate"] = checker.release_candidate_binding(
            self.root, self.fixture.product_digest, self.fixture.harness_digest
        )
        self.fixture.write_marker(marker)
        git(self.root, "add", self.fixture.marker_path.relative_to(self.root).as_posix())
        git(self.root, "commit", "-q", "-m", "test: update candidate identity")
        with self.assertRaisesRegex(checker.EvidenceError, "measured commit release graph"):
            checker.verify(self.root, checker.DEFAULT_MARKER, integrity_only=False)

    def test_checksum_drift_fails_closed(self) -> None:
        with (self.fixture.evidence / self.fixture.formal[0]["file"]).open("ab") as stream:
            stream.write(b"drift")
        with self.assertRaisesRegex(checker.EvidenceError, "checksum mismatch"):
            checker.verify(self.root, checker.DEFAULT_MARKER, integrity_only=True)

    def test_two_batches_must_share_stable_identity(self) -> None:
        self.fixture.write_evidence(second_metadata={"api_policy": "different API"})
        with self.assertRaisesRegex(checker.EvidenceError, "identity mismatch: api_policy"):
            checker.verify(self.root, checker.DEFAULT_MARKER, integrity_only=True)

    def test_strict_mode_rejects_non_ancestor_measurement(self) -> None:
        tree = git(self.root, "rev-parse", "HEAD^{tree}")
        unrelated = git(self.root, "commit-tree", tree, input_text="unrelated\n")
        self.fixture.measured_commit = unrelated
        self.fixture.write_evidence()
        with self.assertRaisesRegex(checker.EvidenceError, "not an ancestor"):
            checker.verify(self.root, checker.DEFAULT_MARKER, integrity_only=False)

    def test_current_document_links_are_required_in_integrity_mode(self) -> None:
        write(self.root / "README.md", "stale link\n")
        with self.assertRaisesRegex(checker.EvidenceError, "does not link"):
            checker.verify(self.root, checker.DEFAULT_MARKER, integrity_only=True)

    def test_readme_number_drift_fails_closed(self) -> None:
        path = self.root / "README.md"
        text = path.read_text(encoding="utf-8")
        write(path, text.replace("| Address encode | 201.000", "| Address encode | 999.000", 1))
        with self.assertRaisesRegex(checker.EvidenceError, "README current performance table"):
            checker.verify(self.root, checker.DEFAULT_MARKER, integrity_only=True)

    def test_result_number_drift_fails_closed(self) -> None:
        text = self.fixture.result.read_text(encoding="utf-8")
        write(
            self.fixture.result,
            text.replace("| Address encode | 101.000", "| Address encode | 999.000", 1),
        )
        with self.assertRaisesRegex(checker.EvidenceError, "result document 第一批 table"):
            checker.verify(self.root, checker.DEFAULT_MARKER, integrity_only=True)


if __name__ == "__main__":
    unittest.main()
