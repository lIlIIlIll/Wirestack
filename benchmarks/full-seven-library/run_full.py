#!/usr/bin/env python3
"""Run the canonical seven-library benchmark matrix on an isolated workspace.

The runner selects one exact benchmark method per manifest cell and validates
the emitted report before recording the cell.  This prevents prefix-related
benchmark cases from being folded into the declared workload.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
import platform
import re
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

from summarize_full import load_cangjie_case, load_jmh_case


WORKLOADS = (
    ("address_encode", "Address", "encode", "Address", "EncodeAddress"),
    ("address_decode", "Address", "decode", "Address", "DecodeAddress"),
    ("person_encode", "Person", "encode", "Person", "EncodePerson"),
    ("person_decode", "Person", "decode", "Person", "DecodePerson"),
    (
        "large_array_encode",
        "Large Array",
        "encode",
        "ArrayList<ProfileRecord>[64]",
        "EncodeLargeProfileArray",
    ),
    (
        "large_array_decode",
        "Large Array",
        "decode",
        "ArrayList<ProfileRecord>[64]",
        "DecodeLargeProfileArray",
    ),
    (
        "large_map_encode",
        "Large Map",
        "encode",
        "HashMap<String, Int64>[64]",
        "EncodeLargeInt64Map",
    ),
    (
        "large_map_decode",
        "Large Map",
        "decode",
        "HashMap<String, Int64>[64]",
        "DecodeLargeInt64Map",
    ),
    (
        "deep_nested_encode",
        "Deep Nested",
        "encode",
        "ArrayList<HashMap<String, ArrayList<ProfileRecord>>>",
        "EncodeDeepNestedProfiles",
    ),
    (
        "deep_nested_decode",
        "Deep Nested",
        "decode",
        "ArrayList<HashMap<String, ArrayList<ProfileRecord>>>",
        "DecodeDeepNestedProfiles",
    ),
)

LIBRARIES = (
    "yjson",
    "stdx_json",
    "cangjieJSON",
    "json4cj",
    "cjfast_json",
    "jackson",
    "fastjson2",
)

CANGJIE = {
    "yjson": (
        "repo/packages/benchmarks",
        "ComprehensiveJsonCompareBenchmarks",
        "yjsonString",
    ),
    "stdx_json": (
        "repo/packages/benchmarks",
        "ComprehensiveJsonCompareBenchmarks",
        "stdxString",
    ),
    "cangjieJSON": (
        "harness/cjjson",
        "CangjieJsonOptimalBenchmarks",
        "cjjsonString",
    ),
    "json4cj": (
        "harness/json4cj",
        "Json4CjOptimalBenchmarks",
        "json4cjString",
    ),
    "cjfast_json": (
        "cjfast-json",
        "CjFastJsonComprehensiveBenchmarks",
        "cjfastString",
    ),
}

JAVA = {"jackson": "jackson", "fastjson2": "fastjson2"}


def source_digest(root: Path) -> str:
    digest = hashlib.sha256()
    paths: list[Path] = []
    for current, dirs, files in os.walk(root):
        dirs[:] = [
            directory
            for directory in dirs
            if directory not in {".git", "target", "build-script-cache"}
        ]
        for name in files:
            path = Path(current) / name
            if path.suffix in {".cj", ".toml", ".java", ".xml"}:
                paths.append(path)
    for path in sorted(paths):
        digest.update(path.relative_to(root).as_posix().encode())
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def file_digest(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def capture(command: list[str], cwd: Path, env: dict[str, str]) -> str:
    return subprocess.run(
        command,
        cwd=cwd,
        env=env,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    ).stdout.strip()


def order(items: tuple, round_id: int) -> list:
    offset = (round_id - 1) % len(items)
    rotated = list(items[offset:] + items[:offset])
    return rotated if round_id % 2 else list(reversed(rotated))


def cangjie_command(
    cpu: int,
    suite: str,
    source_case: str,
    report_dir: Path,
    round_id: int,
) -> list[str]:
    """Build a command selecting exactly one Cangjie benchmark case."""
    return [
        "taskset",
        "-c",
        str(cpu),
        "cjpm",
        "bench",
        "--skip-build",
        "--no-color",
        "--filter",
        f"{suite}.{source_case}",
        "--report-path",
        str(report_dir),
        "--report-format",
        "csv-raw",
        "--random-seed",
        str(round_id),
    ]


def java_command(cpu: int, source_case: str, report_file: Path) -> list[str]:
    """Build a command selecting exactly one JMH benchmark method."""
    return [
        "taskset",
        "-c",
        str(cpu),
        "java",
        "-jar",
        "target/json-optimal-bench-1.0.0-all.jar",
        "^" + re.escape(f"bench.OptimalJsonBench.{source_case}") + "$",
        "-wi",
        "3",
        "-w",
        "500ms",
        "-i",
        "1",
        "-r",
        "1s",
        "-f",
        "1",
        "-bm",
        "avgt",
        "-tu",
        "ns",
        "-rf",
        "json",
        "-rff",
        str(report_file),
    ]


def validate_report(library: str, report_dir: Path, source_case: str) -> None:
    if library in JAVA:
        load_jmh_case(report_dir, source_case)
    else:
        load_cangjie_case(report_dir, source_case)


def require_workspace_layout(workspace: Path) -> None:
    required = [
        workspace / "repo/packages/benchmarks",
        workspace / "harness/cjjson",
        workspace / "harness/json4cj",
        workspace / "cjfast-json",
        workspace / "harness/java",
        workspace / "json4cj",
        workspace / "cangjieJSON-upstream",
        workspace / "cpu-selection.json",
    ]
    missing = [str(path) for path in required if not path.exists()]
    if missing:
        raise ValueError("workspace omits required benchmark inputs: " + ", ".join(missing))


def metadata(
    workspace: Path,
    stdx_sdk_root: Path,
    cpu_selection: dict[str, object],
    env: dict[str, str],
    runs: int,
    cpu: int,
) -> dict[str, object]:
    stdx_static = stdx_sdk_root / "linux_x86_64_cjnative/static/stdx"
    return {
        "started_at_utc": datetime.now(timezone.utc).isoformat(),
        "host": platform.node(),
        "platform": platform.platform(),
        "cpu_selection": cpu_selection,
        "heap": "128MB",
        "runs": runs,
        "schedule": (
            "workload and seven-library order rotate; even rounds reverse workload order"
        ),
        "jmh": "1 fork per outer round, 3x500ms warmup, 1x1s measurement, avgt ns/op",
        "cangjie_bench": "200ms warmup, >=1s duration, >=12 batches, csv-raw",
        "case_selection": "exact fully-qualified benchmark method; report Case validated before manifest commit",
        "api_policy": (
            "fastest semantically equivalent public typed API; no DOM fallback when a direct "
            "typed path exists"
        ),
        "canonical_decode_payload_bytes": {
            "Address": 47,
            "Person": 176,
            "ArrayList<ProfileRecord>[64]": 3929,
            "HashMap<String, Int64>[64]": 1013,
            "ArrayList<HashMap<String, ArrayList<ProfileRecord>>>": 1929,
        },
        "versions": {
            "yjson_commit": capture(
                ["git", "rev-parse", "HEAD"], workspace / "repo", env
            ),
            "cangjieJSON_branch_commit": "910fd9c61858f33b242a0076c22b2e06c8073511",
            "cjfast_json_commit": capture(
                ["git", "rev-parse", "HEAD"], workspace / "cjfast-json", env
            ),
            "json4cj_source_tree_sha256": source_digest(workspace / "json4cj"),
            "cangjieJSON_source_tree_sha256": source_digest(
                workspace / "cangjieJSON-upstream"
            ),
            "cjc": capture(["cjc", "-v"], workspace / "repo", env),
            "cjpm": capture(["cjpm", "--version"], workspace / "repo", env),
            "java": capture(["java", "-version"], workspace / "harness/java", env),
            "jmh": "1.37",
            "jackson": "2.18.2",
            "fastjson2": "2.0.52",
            "stdx_json_ffi_sha256": file_digest(
                stdx_static / "libstdx.encoding.jsonFFI.a"
            ),
            "stdx_json_stream_ffi_sha256": file_digest(
                stdx_static / "libstdx.encoding.json.streamFFI.a"
            ),
        },
        "source_sha256": {
            "yjson": source_digest(workspace / "repo"),
            "cangjieJSON_harness": source_digest(workspace / "harness/cjjson"),
            "json4cj_harness": source_digest(workspace / "harness/json4cj"),
            "cjfast_json": source_digest(workspace / "cjfast-json"),
            "java_harness": source_digest(workspace / "harness/java"),
        },
        "lscpu": capture(["lscpu"], workspace, env),
        "affinity_probe": capture(
            [
                "taskset",
                "-c",
                str(cpu),
                "sh",
                "-c",
                "grep Cpus_allowed_list /proc/self/status",
            ],
            workspace,
            env,
        ),
        "api_paths": {
            "yjson": "cached typed JsonCodec via public YJson.toJson/fromJson",
            "stdx_json": (
                "typed JsonSerializable/JsonDeserializable direct JsonWriter/JsonReader"
            ),
            "cangjieJSON": (
                "@JsonAdapter generated toJson/fromJson (only public typed path; DOM-backed internally)"
            ),
            "json4cj": (
                "@Codable generated encode/decode via public JsonWriter/JsonReader; public "
                "BuiltinEncoders/Decoders for root containers"
            ),
            "cjfast_json": "@JsonAdapter generated toJson/fromJson",
            "jackson": "cached concrete/generic ObjectWriter/ObjectReader",
            "fastjson2": (
                "cached concrete/generic ObjectWriter/ObjectReader with per-operation "
                "JSONWriter/JSONReader"
            ),
        },
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--workspace", type=Path, required=True)
    parser.add_argument("--stdx-sdk-root", type=Path, required=True)
    parser.add_argument("--runs", type=int, default=11)
    parser.add_argument("--cpu", type=int, required=True)
    args = parser.parse_args(argv)
    if args.runs <= 0:
        parser.error("--runs must be positive")

    workspace = args.workspace.resolve()
    stdx_sdk_root = args.stdx_sdk_root.resolve()
    try:
        require_workspace_layout(workspace)
    except ValueError as error:
        parser.error(str(error))

    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error(f"output directory is not empty: {output}")
    raw = output / "raw"
    logs = output / "logs"
    raw.mkdir(parents=True)
    logs.mkdir(parents=True)

    env = os.environ.copy()
    env["cjHeapSize"] = "128MB"
    env["LC_ALL"] = "C"
    try:
        cpu_selection = json.loads(
            (workspace / "cpu-selection.json").read_text(encoding="utf-8")
        )
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        parser.error(f"invalid cpu-selection.json: {error}")
    if (
        args.cpu != cpu_selection.get("selected_cpu")
        or not cpu_selection.get("acceptable_both_threads_below_1_percent")
    ):
        parser.error("selected CPU does not match an acceptable 30-second idle-core sample")

    try:
        run_metadata = metadata(
            workspace, stdx_sdk_root, cpu_selection, env, args.runs, args.cpu
        )
    except (OSError, subprocess.CalledProcessError) as error:
        parser.error(f"cannot capture benchmark provenance: {error}")
    (output / "metadata.json").write_text(
        json.dumps(run_metadata, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )

    fields = [
        "round",
        "workload_position",
        "library_position",
        "library",
        "workload_id",
        "scenario",
        "operation",
        "payload",
        "source_case",
        "elapsed_seconds",
        "load1_before",
        "load1_after",
        "report_path",
        "log_path",
    ]
    with (output / "manifest.csv").open("w", newline="", encoding="utf-8") as stream:
        manifest = csv.DictWriter(stream, fieldnames=fields)
        manifest.writeheader()
        total = args.runs * len(WORKLOADS) * len(LIBRARIES)
        completed_count = 0
        for round_id in range(1, args.runs + 1):
            for workload_position, workload in enumerate(order(WORKLOADS, round_id), 1):
                workload_id, scenario, operation, payload, suffix = workload
                for library_position, library in enumerate(order(LIBRARIES, round_id), 1):
                    report_dir = raw / f"run-{round_id:02d}" / workload_id / library
                    report_dir.mkdir(parents=True)
                    log_path = logs / f"run-{round_id:02d}-{workload_id}-{library}.log"
                    if library in CANGJIE:
                        relative_cwd, suite, prefix = CANGJIE[library]
                        cwd = workspace / relative_cwd
                        source_case = prefix + suffix
                        command = cangjie_command(
                            args.cpu, suite, source_case, report_dir, round_id
                        )
                    else:
                        cwd = workspace / "harness/java"
                        source_case = JAVA[library] + suffix
                        command = java_command(
                            args.cpu, source_case, report_dir / "jmh.json"
                        )

                    before = os.getloadavg()[0]
                    started = time.monotonic()
                    command_env = env.copy()
                    if library == "cangjieJSON":
                        command_env["CANGJIE_STDX_PATH"] = str(stdx_sdk_root)
                    result = subprocess.run(
                        command,
                        cwd=cwd,
                        env=command_env,
                        text=True,
                        stdout=subprocess.PIPE,
                        stderr=subprocess.STDOUT,
                    )
                    elapsed = time.monotonic() - started
                    after = os.getloadavg()[0]
                    log_path.write_text(result.stdout, encoding="utf-8")
                    if result.returncode != 0:
                        print(
                            f"FAILED round={round_id} workload={workload_id} "
                            f"library={library} log={log_path}",
                            file=sys.stderr,
                            flush=True,
                        )
                        return result.returncode
                    try:
                        validate_report(library, report_dir, source_case)
                    except (OSError, UnicodeError, ValueError) as error:
                        with log_path.open("a", encoding="utf-8") as log:
                            log.write(f"\nREPORT VALIDATION FAILED: {error}\n")
                        print(
                            f"FAILED report binding round={round_id} workload={workload_id} "
                            f"library={library}: {error} log={log_path}",
                            file=sys.stderr,
                            flush=True,
                        )
                        return 1

                    manifest.writerow(
                        {
                            "round": round_id,
                            "workload_position": workload_position,
                            "library_position": library_position,
                            "library": library,
                            "workload_id": workload_id,
                            "scenario": scenario,
                            "operation": operation,
                            "payload": payload,
                            "source_case": source_case,
                            "elapsed_seconds": f"{elapsed:.6f}",
                            "load1_before": f"{before:.3f}",
                            "load1_after": f"{after:.3f}",
                            "report_path": report_dir.relative_to(output),
                            "log_path": log_path.relative_to(output),
                        }
                    )
                    stream.flush()
                    completed_count += 1
                    print(
                        f"[{completed_count}/{total}] round={round_id} "
                        f"{workload_id} {library} {elapsed:.2f}s",
                        flush=True,
                    )
    (output / "COMPLETE").write_text(
        datetime.now(timezone.utc).isoformat() + "\n", encoding="utf-8"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
