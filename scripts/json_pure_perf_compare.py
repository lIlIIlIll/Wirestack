#!/usr/bin/env python3
"""Run the Pure baseline/candidate performance qualification cell."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
import pathlib
import platform
import shutil
import statistics
import subprocess
import time


CASES = (
    "yjsonStringEncodeLargeInt64Map",
    "yjsonStringDecodeLargeInt64Map",
    "yjsonBytesDecodeLargeInt64Map",
    "yjsonStringEncodeDeepNestedProfiles",
    "yjsonStringDecodeDeepNestedProfiles",
    "yjsonBytesDecodeDeepNestedProfiles",
    "yjsonStringEncodePerson",
    "yjsonStringDecodePerson",
    "yjsonStringEncodeLargeProfileArray",
    "yjsonStringDecodeLargeProfileArray",
    "yjsonDocumentParseRecords64k",
    "yjsonDocumentStringifyRecords64k",
    "yjsonDocumentParseRecords1m",
    "yjsonDocumentStringifyRecords1m",
    "parseStringRecords64k",
    "parseBytesRecords64k",
    "parseStringRecords1m",
    "parseBytesRecords1m",
    "yjsonStringEncodeProfileBundle",
    "yjsonStringDecodeProfileBundle",
    "yjsonBytesEncodeProfileBundle",
    "yjsonBytesDecodeProfileBundle",
    "yjsonStringEncodeEscapedUnicodeString",
    "yjsonBytesEncodeEscapedUnicodeString",
    "decodePersonChunk4k",
    "decodeRecords64kChunk4k",
    "encodePersonMemory",
    "encodeRecords64kMemory",
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", required=True, type=pathlib.Path)
    parser.add_argument("--candidate", required=True, type=pathlib.Path)
    parser.add_argument("--corpus", required=True, type=pathlib.Path)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--rounds", type=int, default=11)
    parser.add_argument("--cpu", type=int)
    parser.add_argument("--idle-sample-seconds", type=int, default=30)
    parser.add_argument("--enforce", action="store_true")
    parser.add_argument(
        "--rebuild", action="store_true",
        help="clean and rebuild both benchmark binaries before measurement",
    )
    parser.add_argument("--case", action="append", choices=CASES,
                        help="run only this case; repeat for a diagnostic subset")
    parser.add_argument("--target-case", action="append", choices=CASES,
                        help="require this case to improve and win 5/11 rounds; repeat as needed")
    parser.add_argument("--target-improvement-percent", type=float, default=5.0)
    return parser.parse_args()


def cpu_times() -> dict[int, tuple[int, int]]:
    result: dict[int, tuple[int, int]] = {}
    for line in pathlib.Path("/proc/stat").read_text().splitlines():
        fields = line.split()
        if not fields or not fields[0].startswith("cpu") or not fields[0][3:].isdigit():
            continue
        values = [int(value) for value in fields[1:]]
        result[int(fields[0][3:])] = (sum(values), values[3] + values[4])
    return result


def topology(cpu: int) -> tuple[int, int, list[int]]:
    root = pathlib.Path(f"/sys/devices/system/cpu/cpu{cpu}/topology")
    socket = int((root / "physical_package_id").read_text())
    core = int((root / "core_id").read_text())
    siblings_text = (root / "thread_siblings_list").read_text().strip()
    siblings: list[int] = []
    for part in siblings_text.split(","):
        if "-" in part:
            start, end = (int(value) for value in part.split("-", 1))
            siblings.extend(range(start, end + 1))
        else:
            siblings.append(int(part))
    return socket, core, siblings


def choose_idle_cpu(seconds: int) -> dict[str, object]:
    before = cpu_times()
    time.sleep(seconds)
    after = cpu_times()
    utilization: dict[int, float] = {}
    for cpu, (total_after, idle_after) in after.items():
        total_before, idle_before = before[cpu]
        delta_total = total_after - total_before
        delta_idle = idle_after - idle_before
        utilization[cpu] = 100.0 if not delta_total else 100.0 * (delta_total - delta_idle) / delta_total
    groups: dict[tuple[int, int], list[int]] = {}
    for cpu in sorted(utilization):
        socket, core, _ = topology(cpu)
        groups.setdefault((socket, core), []).append(cpu)
    ranked = sorted(
        groups.items(),
        key=lambda entry: (
            max(utilization[cpu] for cpu in entry[1]),
            sum(utilization[cpu] for cpu in entry[1]),
            entry[0],
        ),
    )
    (socket, core), cpus = ranked[0]
    values = [utilization[cpu] for cpu in cpus]
    return {
        "sample_seconds": seconds,
        "selected_cpu": cpus[0],
        "selected_sibling": cpus[1] if len(cpus) > 1 else None,
        "socket": socket,
        "core": core,
        "cpus": cpus,
        "utilization_percent": values,
        "acceptable_both_threads_below_1_percent": max(values) < 1.0,
    }


def explicit_cpu(cpu: int) -> dict[str, object]:
    socket, core, siblings = topology(cpu)
    return {
        "sample_seconds": 0,
        "selected_cpu": cpu,
        "selected_sibling": next((value for value in siblings if value != cpu), None),
        "socket": socket,
        "core": core,
        "cpus": siblings,
        "utilization_percent": [],
        "acceptable_both_threads_below_1_percent": None,
    }


def binary(root: pathlib.Path) -> pathlib.Path:
    return root / "packages/benchmarks/target/release/unittest_bin/yjson_benchmarks"


def path_is_within(path: pathlib.Path, root: pathlib.Path) -> bool:
    try:
        path.relative_to(root)
        return True
    except ValueError:
        return False


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def manifest_digest(manifest: dict[str, str]) -> str:
    digest = hashlib.sha256()
    for name, value in sorted(manifest.items()):
        digest.update(name.encode("utf-8"))
        digest.update(b"\0")
        digest.update(value.encode("ascii"))
        digest.update(b"\n")
    return digest.hexdigest()


def files_manifest(root: pathlib.Path, paths: list[pathlib.Path]) -> dict[str, str]:
    result: dict[str, str] = {}
    for path in sorted(set(paths)):
        if not path.is_file():
            raise SystemExit(f"benchmark input file not found: {path}")
        result[str(path.relative_to(root))] = sha256_file(path)
    return result


def harness_manifest(root: pathlib.Path) -> dict[str, str]:
    package = root / "packages/benchmarks"
    paths = [
        root / "cjpm.toml",
        root / "cjpm.lock",
        package / "cjpm.toml",
        package / "cjpm.lock",
        package / "build.cj",
        root / "packages/yjson_all/cjpm.toml",
        root / "packages/yjson_all/cjpm.lock",
        root / "packages/yjson_macros/cjpm.toml",
        root / "packages/yjson_macros/cjpm.lock",
        root / "scripts/build_native_scanner.py",
        root / "native/yjson_scanner.c",
        root / "native/yjson_scanner.h",
        root / "native/yjson_compact.c",
        root / "native/yjson_compact.h",
        *sorted((package / "src").rglob("*.cj")),
    ]
    return files_manifest(root, paths)


def product_manifest(root: pathlib.Path) -> dict[str, str]:
    paths = [
        *sorted((root / "src").rglob("*.cj")),
        *sorted((root / "packages/yjson_macros/src").rglob("*.cj")),
        *sorted((root / "packages/yjson_all/src").rglob("*.cj")),
    ]
    return files_manifest(root, paths)


def git_output(root: pathlib.Path, *args: str) -> str:
    completed = subprocess.run(
        ["git", "-C", str(root), *args], check=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    )
    return completed.stdout.strip()


def source_identity(root: pathlib.Path) -> dict[str, object]:
    dirty = git_output(root, "status", "--porcelain=v1", "--untracked-files=all").splitlines()
    manifest = product_manifest(root)
    return {
        "commit": git_output(root, "rev-parse", "HEAD"),
        "tree": git_output(root, "rev-parse", "HEAD^{tree}"),
        "dirty": bool(dirty),
        "dirty_paths": dirty,
        "product_source_sha256": manifest_digest(manifest),
        "product_source_manifest": manifest,
    }


def verify_post_build_source_identity(
    name: str,
    before: dict[str, object],
    after: dict[str, object],
    enforce: bool,
) -> None:
    stable_keys = ("commit", "tree", "product_source_sha256", "product_source_manifest")
    changed = [key for key in stable_keys if before[key] != after[key]]
    if after["dirty"]:
        changed.append("dirty")
    if enforce and changed:
        raise SystemExit(
            f"--enforce detected post-build source drift for {name}: " + ", ".join(changed)
        )


def command_identity(command: str) -> dict[str, object]:
    resolved = shutil.which(command)
    if resolved is None:
        raise SystemExit(f"required build tool not found: {command}")
    path = pathlib.Path(resolved).resolve()
    completed = subprocess.run(
        [str(path), "--version"], check=True,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
    )
    return {
        "command": command,
        "path": str(path),
        "sha256": sha256_file(path),
        "version": completed.stdout.strip(),
    }


def toolchain_identity() -> dict[str, object]:
    cc = os.environ.get("CC", "clang")
    ar = os.environ.get("AR", "ar")
    return {
        "host": {"system": platform.system(), "machine": platform.machine()},
        "tools": {
            "cjc": command_identity("cjc"),
            "cjpm": command_identity("cjpm"),
            "cc": command_identity(cc),
            "ar": command_identity(ar),
        },
        "build_environment": {
            name: os.environ.get(name)
            for name in ("CC", "AR", "CANGJIE_HOME", "LD_LIBRARY_PATH")
        },
    }


def artifact_identity(root: pathlib.Path) -> dict[str, object]:
    path = binary(root)
    if path.is_symlink():
        raise SystemExit(f"benchmark binary must not be a symlink: {path}")
    if not path.is_file():
        raise SystemExit(f"benchmark binary not found: {path}")
    stat = path.stat()
    return {
        "path": str(path),
        "size_bytes": stat.st_size,
        "sha256": sha256_file(path),
    }


def rebuild_variant(name: str, root: pathlib.Path, output: pathlib.Path) -> None:
    package = root / "packages/benchmarks"
    log = output / f"build-{name}.log"
    with log.open("w", encoding="utf-8") as stream:
        subprocess.run(
            ["cjpm", "clean"], cwd=package, stdout=stream,
            stderr=subprocess.STDOUT, check=True,
        )
        subprocess.run(
            ["cjpm", "bench", "--no-color", "--no-run"],
            cwd=package, stdout=stream, stderr=subprocess.STDOUT, check=True,
        )


def verify_equal_harness(baseline: pathlib.Path, candidate: pathlib.Path) -> str:
    baseline_manifest = harness_manifest(baseline)
    candidate_manifest = harness_manifest(candidate)
    if baseline_manifest != candidate_manifest:
        names = sorted(set(baseline_manifest) | set(candidate_manifest))
        differences = [name for name in names
                       if baseline_manifest.get(name) != candidate_manifest.get(name)]
        raise SystemExit("baseline/candidate benchmark harness differs: " + ", ".join(differences))
    return manifest_digest(baseline_manifest)


def run_variant(
    name: str,
    root: pathlib.Path,
    corpus: pathlib.Path,
    output: pathlib.Path,
    cpu: int,
    round_number: int,
    case: str,
) -> float:
    report = output / f"round-{round_number:02d}-{case}-{name}"
    log = output / f"round-{round_number:02d}-{case}-{name}.log"
    env = os.environ.copy()
    env["cjHeapSize"] = "128MB"
    env["YJSON_CROSSLANG_CORPUS_DIR"] = str(corpus)
    command = [
        "taskset", "-c", str(cpu), str(binary(root)),
        "--bench", "--no-color", "--no-progress",
        f"--filter=*.{case}", f"--report-path={report}",
    ]
    with log.open("w", encoding="utf-8") as stream:
        subprocess.run(command, env=env, stdout=stream, stderr=subprocess.STDOUT, check=True)
    return read_case_report(report, case)


def read_case_report(report: pathlib.Path, case: str) -> float:
    values: list[float] = []
    for path in report.rglob("bench-*.csv"):
        with path.open(newline="", encoding="utf-8") as stream:
            for row in csv.DictReader(stream):
                if row["Case"] == case:
                    values.append(float(row["Median"]))
    if len(values) != 1:
        raise RuntimeError(f"expected one {case} result in {report}, found {len(values)}")
    return values[0]


def summarize(samples: dict[str, list[float]]) -> dict[str, dict[str, float]]:
    result: dict[str, dict[str, float]] = {}
    for case, values in samples.items():
        mean = statistics.mean(values)
        result[case] = {
            "median_ns": statistics.median(values),
            "mean_ns": mean,
            "cv_percent": 0.0 if mean == 0.0 else statistics.stdev(values) / mean * 100.0,
        }
    return result


def write_markdown(summary: dict[str, object], path: pathlib.Path) -> None:
    baseline = summary["baseline"]
    candidate = summary["candidate"]
    comparisons = summary["comparisons"]
    lines = [
        "| Case | Baseline median | Candidate median | C/B | Improvement | Wins | Baseline CV | Candidate CV |",
        "|---|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for case in summary["cases"]:
        base = baseline[case]
        cand = candidate[case]
        item = comparisons[case]
        lines.append(
            f"| `{case}` | {base['median_ns'] / 1000.0:.3f} us | "
            f"{cand['median_ns'] / 1000.0:.3f} us | {item['ratio']:.3f}x | "
            f"{item['improvement_percent']:.1f}% | {item['candidate_wins']}/{summary['rounds']} | "
            f"{base['cv_percent']:.2f}% | {cand['cv_percent']:.2f}% |"
        )
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    args = parse_args()
    args.baseline = args.baseline.resolve()
    args.candidate = args.candidate.resolve()
    args.corpus = args.corpus.resolve()
    args.output = args.output.resolve()
    cases = tuple(args.case) if args.case else CASES
    target_cases = tuple(args.target_case) if args.target_case else ()
    if args.rounds < 2:
        raise SystemExit("--rounds must be at least 2")
    if args.enforce and args.rounds != 11:
        raise SystemExit("--enforce requires --rounds 11")
    if args.enforce and not args.rebuild:
        raise SystemExit("--enforce requires --rebuild to bind binaries to source")
    if args.target_improvement_percent < 0.0:
        raise SystemExit("--target-improvement-percent must be non-negative")
    missing_targets = [case for case in target_cases if case not in cases]
    if missing_targets:
        raise SystemExit("target cases are not selected: " + ", ".join(missing_targets))
    if args.baseline == args.candidate:
        raise SystemExit("baseline and candidate must be different source directories")
    for root in (args.baseline, args.candidate):
        if path_is_within(args.output, root):
            raise SystemExit("output directory must be outside both source directories")
    harness_digest = verify_equal_harness(args.baseline, args.candidate)
    sources = {
        "baseline": source_identity(args.baseline),
        "candidate": source_identity(args.candidate),
    }
    if args.enforce:
        dirty = [name for name, identity in sources.items() if identity["dirty"]]
        if dirty:
            raise SystemExit("--enforce requires clean source trees: " + ", ".join(dirty))
    corpus_paths = [args.corpus / name for name in (
        "person.json", "records-64k.json", "records-1m.json"
    )]
    corpus_manifest = files_manifest(args.corpus, corpus_paths)
    toolchain = toolchain_identity()
    args.output.mkdir(parents=True, exist_ok=False)
    if args.rebuild:
        rebuild_variant("baseline", args.baseline, args.output)
        rebuild_variant("candidate", args.candidate, args.output)
    post_build_sources = {
        "baseline": source_identity(args.baseline),
        "candidate": source_identity(args.candidate),
    }
    for name in ("baseline", "candidate"):
        verify_post_build_source_identity(
            name, sources[name], post_build_sources[name], args.enforce
        )
    artifacts = {
        "baseline": artifact_identity(args.baseline),
        "candidate": artifact_identity(args.candidate),
    }
    provenance = {
        "runner": {
            "path": str(pathlib.Path(__file__).resolve()),
            "sha256": sha256_file(pathlib.Path(__file__).resolve()),
        },
        "harness_sha256": harness_digest,
        "sources": sources,
        "post_build_sources": post_build_sources,
        "toolchain": toolchain,
        "artifacts": artifacts,
        "corpus": {
            "path": str(args.corpus),
            "sha256": manifest_digest(corpus_manifest),
            "manifest": corpus_manifest,
        },
        "invocation": {
            "rounds": args.rounds,
            "cases": list(cases),
            "target_cases": list(target_cases),
            "target_improvement_percent": args.target_improvement_percent,
            "cpu": args.cpu,
            "idle_sample_seconds": args.idle_sample_seconds,
            "enforce": args.enforce,
            "rebuild": args.rebuild,
            "heap": "128MB",
        },
    }
    (args.output / "provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
    selection = explicit_cpu(args.cpu) if args.cpu is not None else choose_idle_cpu(args.idle_sample_seconds)
    (args.output / "cpu-selection.json").write_text(json.dumps(selection, indent=2) + "\n")
    if args.cpu is None and not selection["acceptable_both_threads_below_1_percent"]:
        raise SystemExit("no physical CPU pair stayed below 1% utilization during idle selection")
    cpu = int(selection["selected_cpu"])
    sibling = selection["selected_sibling"]
    monitor = None
    monitor_path = args.output / "cpu-pair-monitor.csv"
    if sibling is not None:
        monitor_script = pathlib.Path(__file__).with_name("monitor_cpu_pair.py")
        if monitor_script.is_file():
            monitor = subprocess.Popen([str(monitor_script), f"{cpu},{sibling}", str(monitor_path)])
    raw = {
        name: {case: [] for case in cases}
        for name in ("baseline", "candidate")
    }
    try:
        for round_number in range(1, args.rounds + 1):
            order = ("baseline", "candidate") if round_number % 2 else ("candidate", "baseline")
            for case in cases:
                for name in order:
                    root = args.baseline if name == "baseline" else args.candidate
                    raw[name][case].append(run_variant(
                        name, root, args.corpus, args.output, cpu, round_number, case
                    ))
    finally:
        if monitor is not None:
            monitor.terminate()
            monitor.wait()
    baseline = summarize(raw["baseline"])
    candidate = summarize(raw["candidate"])
    comparisons: dict[str, dict[str, float | int]] = {}
    for case in cases:
        base = baseline[case]["median_ns"]
        cand = candidate[case]["median_ns"]
        comparisons[case] = {
            "ratio": cand / base,
            "improvement_percent": (1.0 - cand / base) * 100.0,
            "candidate_wins": sum(
                cand_value < base_value
                for base_value, cand_value in zip(raw["baseline"][case], raw["candidate"][case])
            ),
        }
    summary: dict[str, object] = {
        "rounds": args.rounds,
        "heap": "128MB",
        "harness_sha256": harness_digest,
        "provenance": provenance,
        "cpu": selection,
        "cases": list(cases),
        "target_cases": list(target_cases),
        "target_improvement_percent": args.target_improvement_percent,
        "raw_median_ns": raw,
        "baseline": baseline,
        "candidate": candidate,
        "comparisons": comparisons,
    }
    regression_passed = all(
        comparisons[case]["ratio"] <= 1.05 for case in cases
    )
    target_passed = all(
        comparisons[case]["improvement_percent"] >= args.target_improvement_percent
        and comparisons[case]["candidate_wins"] >= 5
        for case in target_cases
    )
    stability_passed = all(
        baseline[case]["cv_percent"] <= 5.0 and candidate[case]["cv_percent"] <= 5.0
        for case in cases
    )
    summary["gates"] = {
        "all_ratios_at_most_1_05": regression_passed,
        "targets_meet_improvement_and_5_of_11_wins": target_passed,
        "both_cv_at_most_5_percent": stability_passed,
        "passed": regression_passed and target_passed and stability_passed,
    }
    (args.output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    write_markdown(summary, args.output / "summary.md")
    print((args.output / "summary.md").read_text(), end="")
    if args.enforce and not summary["gates"]["passed"]:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
