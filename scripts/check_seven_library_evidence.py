#!/usr/bin/env python3
"""Verify the current seven-library benchmark evidence and source freshness."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import os
import pathlib
import re
import subprocess
import sys
import tarfile
import tempfile
from typing import Any

from json_pure_perf_compare import harness_manifest, manifest_digest, product_manifest


ROOT = pathlib.Path(__file__).resolve().parents[1]
DEFAULT_MARKER = "benchmarks/results/full-seven-library/current-main.json"
MARKER_KEYS = {
    "schema_version",
    "evidence_dir",
    "result_doc",
    "measured_commit",
    "product_source_sha256",
    "effective_harness_sha256",
    "formal_archives",
    "harness_archive",
    "checksum_files",
}
ARCHIVE_KEYS = {"file", "root"}
SHA256_RE = re.compile(r"[0-9a-f]{64}\Z")
COMMIT_RE = re.compile(r"[0-9a-f]{40}\Z")
MARKDOWN_LINK_RE = re.compile(r"\]\(([^\s)]+)(?:\s+[^)]*)?\)")
HTML_HREF_RE = re.compile(r"\bhref=[\"']([^\"']+)[\"']")
LIBRARIES = (
    "yjson",
    "stdx_json",
    "cangjieJSON",
    "json4cj",
    "cjfast_json",
    "jackson",
    "fastjson2",
)
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
WORKLOAD_LABELS = {
    "address_encode": "Address encode",
    "address_decode": "Address decode",
    "person_encode": "Person encode",
    "person_decode": "Person decode",
    "large_array_encode": "Large Array encode",
    "large_array_decode": "Large Array decode",
    "large_map_encode": "Large Map encode",
    "large_map_decode": "Large Map decode",
    "deep_nested_encode": "Deep Nested encode",
    "deep_nested_decode": "Deep Nested decode",
}
EXPECTED_CELLS = {
    (str(round_number), workload, library)
    for round_number in range(1, 12)
    for workload in WORKLOADS
    for library in LIBRARIES
}
STABLE_METADATA_KEYS = (
    "host",
    "platform",
    "heap",
    "runs",
    "schedule",
    "jmh",
    "cangjie_bench",
    "api_policy",
    "canonical_decode_payload_bytes",
    "versions",
    "source_sha256",
    "lscpu",
    "api_paths",
    "product_source_sha256",
    "effective_harness_sha256",
    "measured_overlay_sha256",
)


class EvidenceError(ValueError):
    """The checked-in performance evidence is incomplete, stale, or unsafe."""


def sha256(path: pathlib.Path) -> str:
    digest_value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest_value.update(chunk)
    return digest_value.hexdigest()


def reject_duplicate_json_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise EvidenceError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def read_json_object(path: pathlib.Path, label: str) -> dict[str, Any]:
    try:
        value = json.loads(
            path.read_text(encoding="utf-8"), object_pairs_hook=reject_duplicate_json_keys
        )
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise EvidenceError(f"invalid {label}: {path}: {error}") from error
    if not isinstance(value, dict):
        raise EvidenceError(f"{label} must be a JSON object: {path}")
    return value


def relative_parts(value: object, label: str) -> tuple[str, ...]:
    if not isinstance(value, str) or not value:
        raise EvidenceError(f"{label} must be a non-empty relative POSIX path")
    if "\\" in value or value.startswith("/"):
        raise EvidenceError(f"unsafe {label}: {value!r}")
    parts = tuple(value.split("/"))
    if any(part in ("", ".", "..") for part in parts):
        raise EvidenceError(f"unsafe {label}: {value!r}")
    return parts


def repo_path(
    root: pathlib.Path,
    value: object,
    label: str,
    required_prefix: tuple[str, ...] | None = None,
) -> pathlib.Path:
    parts = relative_parts(value, label)
    if required_prefix is not None and parts[: len(required_prefix)] != required_prefix:
        raise EvidenceError(
            f"{label} must be below {'/'.join(required_prefix)}: {value!r}"
        )
    candidate = root.joinpath(*parts)
    try:
        resolved = candidate.resolve(strict=False)
    except OSError as error:
        raise EvidenceError(f"cannot resolve {label}: {value!r}: {error}") from error
    if resolved != candidate.absolute():
        raise EvidenceError(f"{label} traverses a symbolic link: {value!r}")
    try:
        resolved.relative_to(root)
    except ValueError as error:
        raise EvidenceError(f"{label} escapes the repository: {value!r}") from error
    return candidate


def basename(value: object, label: str, suffix: str | None = None) -> str:
    parts = relative_parts(value, label)
    if len(parts) != 1:
        raise EvidenceError(f"{label} must be a basename: {value!r}")
    name = parts[0]
    if suffix is not None and not name.endswith(suffix):
        raise EvidenceError(f"{label} must end with {suffix}: {name!r}")
    return name


def digest(value: object, label: str) -> str:
    if not isinstance(value, str) or SHA256_RE.fullmatch(value) is None:
        raise EvidenceError(f"{label} must be a lowercase SHA-256 digest")
    return value


def parse_archive(value: object, label: str) -> dict[str, str]:
    if not isinstance(value, dict) or set(value) != ARCHIVE_KEYS:
        raise EvidenceError(f"{label} must contain exactly: file, root")
    archive_file = basename(value["file"], f"{label}.file", ".tar.gz")
    archive_root = basename(value["root"], f"{label}.root")
    return {"file": archive_file, "root": archive_root}


def read_marker(root: pathlib.Path, marker_path: pathlib.Path) -> dict[str, Any]:
    marker = read_json_object(marker_path, "seven-library marker")
    if set(marker) != MARKER_KEYS:
        missing = sorted(MARKER_KEYS - set(marker))
        unexpected = sorted(set(marker) - MARKER_KEYS)
        raise EvidenceError(
            f"marker schema mismatch; missing={missing}, unexpected={unexpected}"
        )
    if type(marker["schema_version"]) is not int or marker["schema_version"] != 1:
        raise EvidenceError("marker schema_version must be integer 1")

    evidence_parts = relative_parts(marker["evidence_dir"], "evidence_dir")
    if evidence_parts[:3] != ("benchmarks", "results", "full-seven-library"):
        raise EvidenceError("evidence_dir must be below benchmarks/results/full-seven-library")
    if len(evidence_parts) != 4 or evidence_parts[-1] == "current-main.json":
        raise EvidenceError("evidence_dir must name one immutable evidence directory")
    repo_path(root, marker["evidence_dir"], "evidence_dir")

    result_parts = relative_parts(marker["result_doc"], "result_doc")
    if result_parts[:3] != ("docs", "performance", "results") or len(result_parts) != 4:
        raise EvidenceError("result_doc must name one file below docs/performance/results")
    if not result_parts[-1].endswith(".md"):
        raise EvidenceError("result_doc must be a Markdown file")
    repo_path(root, marker["result_doc"], "result_doc")

    if not isinstance(marker["measured_commit"], str) or COMMIT_RE.fullmatch(
        marker["measured_commit"]
    ) is None:
        raise EvidenceError("measured_commit must be a full lowercase 40-hex commit")
    digest(marker["product_source_sha256"], "product_source_sha256")
    digest(marker["effective_harness_sha256"], "effective_harness_sha256")

    formal_values = marker["formal_archives"]
    if not isinstance(formal_values, list) or len(formal_values) != 2:
        raise EvidenceError("formal_archives must contain exactly two entries")
    formal = [
        parse_archive(value, f"formal_archives[{index}]")
        for index, value in enumerate(formal_values)
    ]
    if len({entry["file"] for entry in formal}) != 2 or len(
        {entry["root"] for entry in formal}
    ) != 2:
        raise EvidenceError("formal archive files and roots must be unique")
    harness = parse_archive(marker["harness_archive"], "harness_archive")

    checksum_values = marker["checksum_files"]
    if not isinstance(checksum_values, list) or not checksum_values:
        raise EvidenceError("checksum_files must be a non-empty array")
    checksums = [
        basename(value, f"checksum_files[{index}]")
        for index, value in enumerate(checksum_values)
    ]
    if checksums != sorted(set(checksums)):
        raise EvidenceError("checksum_files must be unique and sorted")
    required_archives = {entry["file"] for entry in formal} | {harness["file"]}
    if not required_archives.issubset(checksums):
        raise EvidenceError("checksum_files omits a formal or harness archive")
    if "README.md" in checksums or "checksums.txt" in checksums:
        raise EvidenceError("README.md and checksums.txt are not checksum payload entries")

    marker["formal_archives"] = formal
    marker["harness_archive"] = harness
    marker["checksum_files"] = checksums
    return marker


def verify_checksums(evidence: pathlib.Path, expected_files: list[str]) -> None:
    checksum_path = evidence / "checksums.txt"
    try:
        lines = checksum_path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as error:
        raise EvidenceError(f"cannot read checksum inventory: {error}") from error
    entries: dict[str, str] = {}
    for line_number, line in enumerate(lines, 1):
        fields = line.split()
        if len(fields) != 2:
            raise EvidenceError(f"invalid checksums.txt line {line_number}")
        expected, raw_name = fields
        name = raw_name[1:] if raw_name.startswith("*") else raw_name
        name = basename(name, f"checksums.txt line {line_number} filename")
        digest(expected, f"checksums.txt line {line_number} digest")
        if name in entries:
            raise EvidenceError(f"duplicate checksum entry: {name}")
        entries[name] = expected
    if sorted(entries) != expected_files:
        raise EvidenceError(
            "checksum inventory differs from marker: "
            f"marker={expected_files}, checksums.txt={sorted(entries)}"
        )
    for name, expected in entries.items():
        path = evidence / name
        if not path.is_file():
            raise EvidenceError(f"missing checksummed evidence file: {name}")
        if sha256(path) != expected:
            raise EvidenceError(f"seven-library checksum mismatch: {name}")

    expected_inventory = {"README.md", "checksums.txt", *expected_files}
    actual_inventory = {path.name for path in evidence.iterdir()}
    contains_non_file = any(not path.is_file() for path in evidence.iterdir())
    if actual_inventory != expected_inventory or contains_non_file:
        raise EvidenceError(
            "evidence directory inventory differs from marker: "
            f"expected={sorted(expected_inventory)}, actual={sorted(actual_inventory)}"
        )


def archive_member_parts(name: str, archive_name: str) -> tuple[str, ...]:
    if not name or "\\" in name or name.startswith("/"):
        raise EvidenceError(f"unsafe archive member in {archive_name}: {name!r}")
    stripped = name[:-1] if name.endswith("/") else name
    parts = tuple(stripped.split("/"))
    if not stripped or any(part in ("", ".", "..") for part in parts):
        raise EvidenceError(f"unsafe archive member in {archive_name}: {name!r}")
    return parts


def validate_archive(
    archive_path: pathlib.Path, expected_root: str | None = None
) -> list[tarfile.TarInfo]:
    try:
        with tarfile.open(archive_path, "r:gz") as archive:
            members = archive.getmembers()
    except (OSError, tarfile.TarError) as error:
        raise EvidenceError(f"invalid archive {archive_path.name}: {error}") from error
    if not members:
        raise EvidenceError(f"empty archive: {archive_path.name}")
    names: set[str] = set()
    roots: set[str] = set()
    for member in members:
        parts = archive_member_parts(member.name, archive_path.name)
        roots.add(parts[0])
        normalized_name = "/".join(parts)
        if normalized_name in names:
            raise EvidenceError(f"duplicate archive member in {archive_path.name}: {member.name}")
        names.add(normalized_name)
        if not (member.isdir() or member.isfile()):
            raise EvidenceError(f"unsupported archive member in {archive_path.name}: {member.name}")
    if expected_root is not None and roots != {expected_root}:
        raise EvidenceError(
            f"unexpected archive roots in {archive_path.name}: {sorted(roots)}"
        )
    return members


def safe_extract(
    archive_path: pathlib.Path, destination: pathlib.Path, expected_root: str
) -> pathlib.Path:
    validate_archive(archive_path, expected_root)
    destination.mkdir(parents=True, exist_ok=False)
    try:
        with tarfile.open(archive_path, "r:gz") as archive:
            archive.extractall(destination, filter="data")
    except (OSError, tarfile.TarError) as error:
        raise EvidenceError(f"cannot extract {archive_path.name}: {error}") from error
    root = destination / expected_root
    if not root.is_dir():
        raise EvidenceError(f"archive root is not a directory: {archive_path.name}")
    return root


def cpu_selection_is_formal(value: object) -> bool:
    if not isinstance(value, dict):
        return False
    sample_seconds = value.get("sample_seconds")
    utilization = value.get("utilization_percent")
    selected_cpu = value.get("selected_cpu")
    selected_sibling = value.get("selected_sibling")
    return (
        type(sample_seconds) is int
        and sample_seconds >= 30
        and type(selected_cpu) is int
        and type(selected_sibling) is int
        and selected_cpu != selected_sibling
        and value.get("acceptable_both_threads_below_1_percent") is True
        and isinstance(utilization, list)
        and len(utilization) == 2
        and all(
            type(item) in (int, float)
            and not isinstance(item, bool)
            and 0.0 <= item < 1.0
            for item in utilization
        )
    )


def read_metadata_and_validate(
    root: pathlib.Path, marker: dict[str, Any]
) -> dict[str, Any]:
    if not (root / "COMPLETE").is_file():
        raise EvidenceError(f"missing COMPLETE marker: {root.name}")
    metadata = read_json_object(root / "metadata.json", f"metadata for {root.name}")
    if type(metadata.get("runs")) is not int or metadata["runs"] != 11:
        raise EvidenceError(f"unexpected run count in {root.name}")
    if not cpu_selection_is_formal(metadata.get("cpu_selection")):
        raise EvidenceError(f"invalid or non-idle CPU selection in {root.name}")
    versions = metadata.get("versions")
    if not isinstance(versions, dict):
        raise EvidenceError(f"missing versions object in {root.name}")
    if versions.get("yjson_commit") != marker["measured_commit"]:
        raise EvidenceError(f"measured commit mismatch in {root.name}")
    for key in ("product_source_sha256", "effective_harness_sha256"):
        if metadata.get(key) != marker[key]:
            raise EvidenceError(f"{key} mismatch in {root.name}")
    digest(metadata.get("measured_overlay_sha256"), f"measured_overlay_sha256 in {root.name}")
    missing_stable = [key for key in STABLE_METADATA_KEYS if key not in metadata]
    if missing_stable:
        raise EvidenceError(f"metadata in {root.name} omits: {missing_stable}")

    try:
        with (root / "manifest.csv").open(newline="", encoding="utf-8") as stream:
            rows = list(csv.DictReader(stream))
    except (OSError, UnicodeError, csv.Error) as error:
        raise EvidenceError(f"cannot read manifest for {root.name}: {error}") from error
    required_columns = {"round", "workload_id", "library"}
    if not rows or not required_columns.issubset(rows[0]):
        raise EvidenceError(f"manifest columns are incomplete in {root.name}")
    cells = {(row["round"], row["workload_id"], row["library"]) for row in rows}
    if len(rows) != len(EXPECTED_CELLS) or len(cells) != len(rows) or cells != EXPECTED_CELLS:
        missing = len(EXPECTED_CELLS - cells)
        unexpected = len(cells - EXPECTED_CELLS)
        raise EvidenceError(
            f"expected exact 770-cell matrix in {root.name}; "
            f"rows={len(rows)}, unique={len(cells)}, missing={missing}, unexpected={unexpected}"
        )
    return metadata


def stable_identity(metadata: dict[str, Any], key: str) -> object:
    value = metadata[key]
    if key != "versions":
        return value
    versions = dict(value)
    cjpm = versions.get("cjpm")
    if isinstance(cjpm, str):
        versions["cjpm"] = cjpm.splitlines()[-1]
    return versions


def regenerate_and_compare_summary(
    formal_root: pathlib.Path, summarize: pathlib.Path, archive_name: str
) -> None:
    expected = {
        suffix: (formal_root / f"summary.{suffix}").read_bytes()
        for suffix in ("json", "csv", "md")
    }
    completed = subprocess.run(
        [sys.executable, "-I", str(summarize), str(formal_root), "--min-runs", "11"],
        cwd=summarize.parent,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
    )
    if completed.returncode != 0:
        raise EvidenceError(
            f"summary regeneration failed for {archive_name}: {completed.stderr.strip()}"
        )
    expected_json = formal_root / "summary.expected.json"
    expected_json.write_bytes(expected["json"])
    numeric_check = pathlib.Path(__file__).with_name("check_json_numeric_equivalence.py")
    completed = subprocess.run(
        [
            sys.executable,
            str(numeric_check),
            str(expected_json),
            str(formal_root / "summary.json"),
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
    )
    if completed.returncode != 0:
        raise EvidenceError(
            f"derived summary drift in {archive_name}: summary.json: {completed.stderr.strip()}"
        )
    for suffix in ("csv", "md"):
        if (formal_root / f"summary.{suffix}").read_bytes() != expected[suffix]:
            raise EvidenceError(f"derived summary drift in {archive_name}: summary.{suffix}")


def finite_number(value: object, label: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise EvidenceError(f"{label} must be numeric")
    result = float(value)
    if not math.isfinite(result) or result < 0.0:
        raise EvidenceError(f"{label} must be finite and non-negative")
    return result


def canonical_summary_rows(formal_root: pathlib.Path, include_max_cv: bool) -> list[str]:
    try:
        summary = json.loads((formal_root / "summary.json").read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise EvidenceError(f"invalid regenerated summary in {formal_root.name}: {error}") from error
    if not isinstance(summary, list) or len(summary) != len(WORKLOADS):
        raise EvidenceError(f"summary in {formal_root.name} must contain 10 workloads")
    by_workload: dict[str, dict[str, Any]] = {}
    for item in summary:
        if not isinstance(item, dict) or not isinstance(item.get("workload_id"), str):
            raise EvidenceError(f"invalid summary workload in {formal_root.name}")
        workload = item["workload_id"]
        if workload in by_workload:
            raise EvidenceError(f"duplicate summary workload in {formal_root.name}: {workload}")
        by_workload[workload] = item
    if set(by_workload) != set(WORKLOADS):
        raise EvidenceError(f"summary workload inventory differs in {formal_root.name}")

    rows: list[str] = []
    for workload in WORKLOADS:
        libraries = by_workload[workload].get("libraries")
        if not isinstance(libraries, dict) or set(libraries) != set(LIBRARIES):
            raise EvidenceError(
                f"summary library inventory differs in {formal_root.name}: {workload}"
            )
        medians: list[str] = []
        cvs: list[float] = []
        for library in LIBRARIES:
            metrics = libraries[library]
            if not isinstance(metrics, dict):
                raise EvidenceError(
                    f"invalid summary metrics in {formal_root.name}: {workload}/{library}"
                )
            median_ns = finite_number(
                metrics.get("median_ns"),
                f"{formal_root.name} {workload}/{library} median_ns",
            )
            cv_percent = finite_number(
                metrics.get("cv_percent"),
                f"{formal_root.name} {workload}/{library} cv_percent",
            )
            medians.append(f"{median_ns / 1000.0:.3f}")
            cvs.append(cv_percent)
        cells = [WORKLOAD_LABELS[workload], *medians]
        if include_max_cv:
            cells.append(f"{max(cvs):.2f}%")
        rows.append("| " + " | ".join(cells) + " |")
    return rows


def markdown_section(text: str, heading: str, path: pathlib.Path) -> str:
    pattern = re.compile(
        rf"^## {re.escape(heading)}\s*$\n(?P<body>.*?)(?=^##\s|\Z)",
        re.MULTILINE | re.DOTALL,
    )
    matches = list(pattern.finditer(text))
    if len(matches) != 1:
        raise EvidenceError(f"{path} must contain exactly one '## {heading}' section")
    return matches[0].group("body")


def verify_report_rows(
    root_readme: pathlib.Path,
    result_doc: pathlib.Path,
    result_batch_rows: list[list[str]],
    readme_batch_rows: list[str],
) -> None:
    readme_text = root_readme.read_text(encoding="utf-8")
    result_text = result_doc.read_text(encoding="utf-8")
    label_set = set(WORKLOAD_LABELS.values())

    def actual_rows(text: str, heading: str, path: pathlib.Path) -> list[str]:
        section = markdown_section(text, heading, path)
        rows: list[str] = []
        for line in section.splitlines():
            stripped = line.strip()
            if not stripped.startswith("|"):
                continue
            cells = [cell.strip() for cell in stripped.strip("|").split("|")]
            if cells and cells[0] in label_set:
                rows.append(stripped)
        return rows

    readme_rows = actual_rows(readme_text, "性能", root_readme)
    if readme_rows != readme_batch_rows:
        raise EvidenceError("README current performance table differs from formal batch 2")
    for heading, expected in (
        ("第一批", result_batch_rows[0]),
        ("第二批", result_batch_rows[1]),
    ):
        rows = actual_rows(result_text, heading, result_doc)
        if rows != expected:
            raise EvidenceError(f"result document {heading} table differs from formal evidence")


def markdown_targets(path: pathlib.Path) -> set[str]:
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        raise EvidenceError(f"cannot read documentation file {path}: {error}") from error
    return set(MARKDOWN_LINK_RE.findall(text)) | set(HTML_HREF_RE.findall(text))


def require_link(path: pathlib.Path, expected: str) -> None:
    if expected not in markdown_targets(path):
        raise EvidenceError(f"{path} does not link to current evidence target {expected!r}")


def verify_documentation_bindings(
    root: pathlib.Path,
    evidence: pathlib.Path,
    result_doc: pathlib.Path,
    marker: dict[str, Any],
) -> None:
    root_readme = root / "README.md"
    performance_index = root / "docs/performance/README.md"
    evidence_readme = evidence / "README.md"
    require_link(root_readme, marker["result_doc"])
    require_link(
        performance_index,
        pathlib.PurePosixPath(os.path.relpath(result_doc, performance_index.parent)).as_posix(),
    )
    require_link(
        evidence_readme,
        pathlib.PurePosixPath(os.path.relpath(result_doc, evidence)).as_posix(),
    )
    require_link(
        result_doc,
        pathlib.PurePosixPath(os.path.relpath(evidence_readme, result_doc.parent)).as_posix(),
    )
    commit = marker["measured_commit"]
    for path in (evidence_readme, result_doc):
        if commit not in path.read_text(encoding="utf-8"):
            raise EvidenceError(f"{path} is not bound to measured commit {commit}")


def verify_current_checkout(root: pathlib.Path, marker: dict[str, Any]) -> None:
    try:
        product_digest = manifest_digest(product_manifest(root))
        harness_digest = manifest_digest(harness_manifest(root))
    except SystemExit as error:
        raise EvidenceError(f"cannot compute current performance input identity: {error}") from error
    if product_digest != marker["product_source_sha256"]:
        raise EvidenceError(
            "current product source differs from measured evidence: "
            f"expected={marker['product_source_sha256']}, actual={product_digest}"
        )
    if harness_digest != marker["effective_harness_sha256"]:
        raise EvidenceError(
            "current benchmark harness differs from measured evidence: "
            f"expected={marker['effective_harness_sha256']}, actual={harness_digest}"
        )
    completed = subprocess.run(
        [
            "git",
            "-C",
            str(root),
            "merge-base",
            "--is-ancestor",
            marker["measured_commit"],
            "HEAD",
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if completed.returncode == 1:
        raise EvidenceError("measured_commit is not an ancestor of the current checkout")
    if completed.returncode != 0:
        raise EvidenceError(
            "cannot verify measured_commit ancestry; use a complete checkout: "
            + completed.stderr.strip()
        )


def verify(root: pathlib.Path, marker_relative: str, integrity_only: bool) -> None:
    root = root.resolve(strict=True)
    marker_path = repo_path(root, marker_relative, "marker path")
    if not marker_path.is_file():
        raise EvidenceError(f"missing seven-library marker: {marker_relative}")
    marker = read_marker(root, marker_path)
    evidence = repo_path(
        root,
        marker["evidence_dir"],
        "evidence_dir",
        ("benchmarks", "results", "full-seven-library"),
    )
    result_doc = repo_path(
        root,
        marker["result_doc"],
        "result_doc",
        ("docs", "performance", "results"),
    )
    if not evidence.is_dir() or not result_doc.is_file():
        raise EvidenceError("marker refers to a missing evidence directory or result document")

    verify_checksums(evidence, marker["checksum_files"])
    for name in marker["checksum_files"]:
        if name.endswith(".tar.gz"):
            validate_archive(evidence / name)
    verify_documentation_bindings(root, evidence, result_doc, marker)

    with tempfile.TemporaryDirectory(prefix="yjson-seven-library-evidence-") as temporary:
        scratch = pathlib.Path(temporary)
        harness_info = marker["harness_archive"]
        harness_root = safe_extract(
            evidence / harness_info["file"], scratch / "harness", harness_info["root"]
        )
        summarize = harness_root / "summarize_full.py"
        if not summarize.is_file():
            raise EvidenceError("harness archive omits summarize_full.py")
        identities: list[dict[str, Any]] = []
        result_batch_rows: list[list[str]] = []
        readme_batch_rows: list[str] | None = None
        for index, archive_info in enumerate(marker["formal_archives"]):
            formal_root = safe_extract(
                evidence / archive_info["file"],
                scratch / f"formal-{index}",
                archive_info["root"],
            )
            identities.append(read_metadata_and_validate(formal_root, marker))
            regenerate_and_compare_summary(formal_root, summarize, archive_info["file"])
            result_batch_rows.append(
                canonical_summary_rows(formal_root, include_max_cv=True)
            )
            if index == 1:
                readme_batch_rows = canonical_summary_rows(
                    formal_root, include_max_cv=False
                )

        for key in STABLE_METADATA_KEYS:
            if stable_identity(identities[0], key) != stable_identity(identities[1], key):
                raise EvidenceError(f"formal archive identity mismatch: {key}")
        if readme_batch_rows is None:
            raise EvidenceError("formal batch 2 is missing")
        verify_report_rows(
            root / "README.md", result_doc, result_batch_rows, readme_batch_rows
        )

    if not integrity_only:
        verify_current_checkout(root, marker)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        type=pathlib.Path,
        default=ROOT,
        help="repository root (default: checker repository)",
    )
    parser.add_argument(
        "--marker",
        default=DEFAULT_MARKER,
        help=f"repository-relative marker path (default: {DEFAULT_MARKER})",
    )
    parser.add_argument(
        "--integrity-only",
        action="store_true",
        help="skip current checkout digests and ancestry; keep all evidence and docs checks",
    )
    args = parser.parse_args(argv)
    try:
        verify(args.root, args.marker, args.integrity_only)
    except (EvidenceError, OSError) as error:
        print(f"seven-library evidence failed: {error}", file=sys.stderr)
        return 1
    mode = "integrity" if args.integrity_only else "strict freshness"
    print(f"seven-library evidence passed: {mode}, checksums, manifests, identities, and summaries")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
