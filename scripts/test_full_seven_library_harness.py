#!/usr/bin/env python3
"""Regression tests for exact benchmark Case and RSS binding."""

from __future__ import annotations

import csv
import importlib.util
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
HARNESS = ROOT / "benchmarks/full-seven-library"
sys.path.insert(0, str(HARNESS))


def load_module(name: str, path: pathlib.Path):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


SUMMARY = load_module("full_seven_library_summary", HARNESS / "summarize_full.py")

CJFAST_SUMMARY = load_module(
    "json_cjfast_perf_summary",
    ROOT / "scripts/json_cjfast_perf_summary.py",
)
RUNNER = load_module("full_seven_library_runner", HARNESS / "run_full.py")

CJFAST_RUNNER = load_module(
    "json_cjfast_perf_run",
    ROOT / "scripts/json_cjfast_perf_run.py",
)


def write_cangjie_csv(
    path: pathlib.Path,
    rows: list[tuple[str, int, float, str, str]],
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as stream:
        writer = csv.writer(stream)
        writer.writerow(["Case", "Args", "BatchSize", "Duration", "Unit", "Measurement"])
        for case, batch_size, duration, unit, measurement in rows:
            writer.writerow([case, "", batch_size, duration, unit, measurement])


class RunnerSelectionTest(unittest.TestCase):
    def test_cangjie_command_uses_exact_case_filter(self) -> None:
        command = RUNNER.cangjie_command(
            7,
            "ComprehensiveJsonCompareBenchmarks",
            "yjsonStringDecodePerson",
            pathlib.Path("/tmp/report"),
            3,
        )
        selected = command[command.index("--filter") + 1]
        self.assertEqual(
            selected,
            "ComprehensiveJsonCompareBenchmarks.yjsonStringDecodePerson",
        )
        self.assertNotIn("*", selected)

    def test_java_command_anchors_and_escapes_exact_case(self) -> None:
        command = RUNNER.java_command(
            7, "jacksonDecodePerson", pathlib.Path("/tmp/report/jmh.json")
        )
        self.assertIn(r"^bench\.OptimalJsonBench\.jacksonDecodePerson$", command)


class RssCaptureTest(unittest.TestCase):
    def test_gnu_time_rss_sidecar_is_parsed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "time-rss.txt"
            path.write_text(
                "\tMaximum resident set size (kbytes): 321\n",
                encoding="utf-8",
            )
            self.assertEqual(RUNNER.parse_max_rss(path), 321)

    def test_missing_gnu_time_rss_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "time-rss.txt"
            path.write_text("Elapsed (wall clock) time: 1.0\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "expected one GNU time RSS"):
                RUNNER.parse_max_rss(path)


class CjfastSummaryRssTest(unittest.TestCase):
    def test_rss_sidecar_is_bound_to_result_root(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            path = root / "rss/time-rss.txt"
            path.parent.mkdir()
            path.write_text(
                "\tMaximum resident set size (kbytes): 654\n",
                encoding="utf-8",
            )
            self.assertEqual(
                CJFAST_SUMMARY.load_max_rss(root, "rss/time-rss.txt"),
                654,
            )
            with self.assertRaisesRegex(ValueError, "unsafe RSS path"):
                CJFAST_SUMMARY.load_max_rss(root, "/tmp/time-rss.txt")

    def test_summary_preserves_peak_rss(self) -> None:
        result = CJFAST_SUMMARY.summarize(
            {1: [10.0], 2: [12.0]},
            {1: 100, 2: 120},
        )
        self.assertEqual(result["median_rss_kb"], 110)
        self.assertEqual(result["max_rss_kb"], 120)

    def test_load_report_filters_prefix_colliding_cases(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            write_cangjie_csv(
                root / "bench-suite.csv",
                [
                    ("exactCase", 1, 2000.0, "ns", "Duration"),
                    ("exactCaseBatchGuard", 1, 8000.0, "ns", "Duration"),
                ],
            )
            self.assertEqual(
                CJFAST_SUMMARY.load_report(root, "exactCase"),
                [2000.0],
            )

    def test_load_report_requires_the_manifest_case(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            write_cangjie_csv(
                root / "bench-suite.csv",
                [("exactCaseBatchGuard", 1, 8000.0, "ns", "Duration")],
            )
            with self.assertRaisesRegex(ValueError, "no duration samples found for Case"):
                CJFAST_SUMMARY.load_report(root, "exactCase")


class CjfastRunnerPolicyTest(unittest.TestCase):
    def test_timed_command_uses_exact_case_and_skip_build(self) -> None:
        command = CJFAST_RUNNER.cangjie_command(
            3,
            "ComprehensiveJsonCompareBenchmarks",
            "yjsonStringDecodePrettyPerson",
            pathlib.Path("/tmp/report"),
            1,
        )
        selected = command[command.index("--filter") + 1]
        self.assertEqual(
            selected,
            "ComprehensiveJsonCompareBenchmarks.yjsonStringDecodePrettyPerson",
        )
        self.assertIn("--skip-build", command)
        self.assertNotIn("*", selected)

    def test_build_command_is_unmeasured_and_does_not_select_a_case(self) -> None:
        command = CJFAST_RUNNER.build_command(3)
        self.assertIn("--no-run", command)
        self.assertNotIn("--filter", command)
        self.assertNotIn("/usr/bin/time", command)


class FixturePreflightContractTest(unittest.TestCase):
    def fixture_workspace(self, root: pathlib.Path, marked: bool = True) -> pathlib.Path:
        required_dirs = (
            "repo/packages/benchmarks",
            "harness/cjjson",
            "harness/json4cj",
            "cjfast-json",
            "harness/java",
            "json4cj",
            "cangjieJSON-upstream",
        )
        for relative in required_dirs:
            (root / relative).mkdir(parents=True, exist_ok=True)
        (root / "cpu-selection.json").write_text("{}\n", encoding="utf-8")
        for relative in RUNNER.PREFLIGHT_FIXTURES:
            path = root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(
                (RUNNER.PREFLIGHT_MARKER if marked else "missing") + "\n",
                encoding="utf-8",
            )
        return root

    def test_complete_fixture_preflight_contract_is_accepted(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            RUNNER.require_workspace_layout(
                self.fixture_workspace(pathlib.Path(directory))
            )

    def test_any_fixture_without_preflight_marker_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            workspace = self.fixture_workspace(pathlib.Path(directory))
            missing = workspace / RUNNER.PREFLIGHT_FIXTURES[2]
            missing.write_text("no assertions\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "omit the canonical encode/decode"):
                RUNNER.require_workspace_layout(workspace)

    def test_fixture_overlay_applies_and_freezes_java_wire_shape(self) -> None:
        archive = (
            ROOT
            / "benchmarks/results/full-seven-library/2026-08-30-main-d2f375c8274e"
            / "harness-source.tar.gz"
        )
        overlay = HARNESS / "fixture-preflight-overlay.patch"
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            subprocess.run(
                ["tar", "-xzf", str(archive), "-C", str(root)],
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
            )
            subprocess.run(
                ["patch", "-p1", "-i", str(overlay)],
                cwd=root,
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
            )
            java = (
                root / "harness/java/src/main/java/bench/OptimalJsonBench.java"
            ).read_text(encoding="utf-8")
            self.assertIn("YJSON_SEVEN_LIBRARY_PREFLIGHT_V1", java)
            self.assertIn(
                '@com.fasterxml.jackson.annotation.JsonPropertyOrder('
                '{"user_id", "name", "age", "tags", '
                '"scores", "address", "nick"})',
                java,
            )
            self.assertIn('@JSONField(name = "user_id", ordinal = 1)', java)
            self.assertIn(
                "@JSONField(ordinal = 7, serializeFeatures = "
                "JSONWriter.Feature.WriteNulls)",
                java,
            )


class CangjieReportBindingTest(unittest.TestCase):
    def test_repeated_measurements_for_one_case_are_valid(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            write_cangjie_csv(
                root / "bench-suite.csv",
                [
                    ("exactCase", 1, 2000.0, "ns", "Duration"),
                    ("exactCase", 4, 8000.0, "ns", "Duration"),
                ],
            )
            self.assertEqual(SUMMARY.load_cangjie_case(root, "exactCase"), [2000.0, 2000.0])

    def test_extra_case_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            write_cangjie_csv(
                root / "bench-suite.csv",
                [
                    ("exactCase", 1, 100.0, "ns", "Duration"),
                    ("exactCaseBatchGuard", 1, 100.0, "ns", "Duration"),
                ],
            )
            with self.assertRaisesRegex(ValueError, "extra Case"):
                SUMMARY.load_cangjie_case(root, "exactCase")

    def test_missing_case_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            write_cangjie_csv(
                root / "bench-suite.csv",
                [("differentCase", 1, 100.0, "ns", "Duration")],
            )
            with self.assertRaisesRegex(ValueError, "missing Case"):
                SUMMARY.load_cangjie_case(root, "exactCase")

    def test_duplicate_case_across_reports_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            row = [("exactCase", 1, 100.0, "ns", "Duration")]
            write_cangjie_csv(root / "first/bench-suite.csv", row)
            write_cangjie_csv(root / "second/bench-suite.csv", row)
            with self.assertRaisesRegex(ValueError, "duplicate Case"):
                SUMMARY.load_cangjie_case(root, "exactCase")

    def test_jmh_case_must_match_manifest_source_case(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root / "jmh.json").write_text(
                json.dumps(
                    [
                        {
                            "benchmark": "bench.OptimalJsonBench.jacksonDecodePersonBatchGuard",
                            "primaryMetric": {"score": 42.0, "scoreUnit": "ns/op"},
                        }
                    ]
                ),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(ValueError, "JMH Case mismatch"):
                SUMMARY.load_jmh_case(root, "jacksonDecodePerson")


class ManifestContaminationTest(unittest.TestCase):
    WORKLOADS = (
        "address_encode",
        "address_decode",
        "person_encode",
        "person_decode",
        "large_array_encode",
        "large_array_decode",
        "large_map_encode",
        "large_map_decode",
        "deep_nested_encode",
        "deep_nested_decode",
    )

    @staticmethod
    def source_case(workload: str, library: str) -> str:
        if workload == "person_decode" and library == "yjson":
            return "yjsonStringDecodePerson"
        if workload == "large_array_decode" and library == "yjson":
            return "yjsonStringDecodeLargeProfileArray"
        return f"{library}_{workload}"

    def rows(self) -> list[dict[str, str]]:
        rows: list[dict[str, str]] = []
        for round_number in range(1, 12):
            for workload in self.WORKLOADS:
                operation = "encode" if workload.endswith("_encode") else "decode"
                for library in SUMMARY.LIBRARIES:
                    rows.append(
                        {
                            "round": str(round_number),
                            "library": library,
                            "workload_id": workload,
                            "scenario": workload.rsplit("_", 1)[0],
                            "operation": operation,
                            "payload": f"canonical-{workload}",
                            "source_case": self.source_case(workload, library),
                            "report_path": f"raw/{round_number}/{workload}/{library}",
                            "max_rss_kb": "123",
                            "rss_path": f"raw/{round_number}/{workload}/{library}/time-rss.txt",
                        }
                    )
        return rows

    @staticmethod
    def materialize_rss(root: pathlib.Path, rows: list[dict[str, str]]) -> None:
        for row in rows:
            path = root / row["rss_path"]
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(
                "\tMaximum resident set size (kbytes): "
                f"{row['max_rss_kb']}\n",
                encoding="utf-8",
            )

    @staticmethod
    def inventory(expected_case: str, extras: tuple[str, ...] = ()) -> dict[str, object]:
        cases = (expected_case,) + extras
        return {
            "report_files": ("bench-suite.csv",),
            "case_files": {case: ("bench-suite.csv",) for case in cases},
            "values": {case: [100.0] for case in cases},
        }

    def test_two_prefix_collisions_reproduce_22_of_770_polluted_cells(self) -> None:
        rows = self.rows()
        self.assertEqual(len(rows), 770)

        def load(_root: pathlib.Path, row: dict[str, str]) -> list[float]:
            expected = row["source_case"]
            extras: tuple[str, ...] = ()
            if row["workload_id"] == "person_decode" and row["library"] == "yjson":
                extras = (
                    "yjsonStringDecodePersonBatchGuard",
                    "yjsonStringDecodePersonFastDecoderBatchGuard",
                )
            elif (
                row["workload_id"] == "large_array_decode"
                and row["library"] == "yjson"
            ):
                extras = ("yjsonStringDecodeLargeProfileArrayValue",)
            return SUMMARY.values_for_expected_case(self.inventory(expected, extras), expected)

        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            self.materialize_rss(root, rows)
            with self.assertRaisesRegex(ValueError, r"22/770 benchmark cells"):
                SUMMARY.collect_samples(root, rows, loader=load)

    def test_two_manifest_cells_cannot_share_one_report(self) -> None:
        rows = self.rows()[:2]
        rows[1]["report_path"] = rows[0]["report_path"]
        rows[1]["rss_path"] = rows[0]["rss_path"]

        def load(_root: pathlib.Path, _row: dict[str, str]) -> list[float]:
            return [100.0]

        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            self.materialize_rss(root, rows)
            with self.assertRaisesRegex(ValueError, "report_path .* is shared"):
                SUMMARY.collect_samples(root, rows, loader=load)


if __name__ == "__main__":
    unittest.main()
