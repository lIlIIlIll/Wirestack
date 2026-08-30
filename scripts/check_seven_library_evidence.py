#!/usr/bin/env python3
"""Verify the frozen seven-library benchmark archive and derived summaries."""

from __future__ import annotations

import csv
import hashlib
import json
import pathlib
import subprocess
import tarfile
import tempfile


ROOT = pathlib.Path(__file__).resolve().parents[1]
EVIDENCE = ROOT / "benchmarks/results/full-seven-library/2026-08-30"
RESULT_DOC = ROOT / "docs/performance/results/2026-08-30-current-dev-seven-library.md"
EXPECTED_ARCHIVES = ("formal-current-11-1.tar.gz", "formal-current-11-2.tar.gz")
EXPECTED_CHECKSUM_FILES = {*EXPECTED_ARCHIVES, "harness-source.tar.gz", "optimal-api-overlay-current.patch"}


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify_checksums() -> None:
    entries: dict[str, str] = {}
    for line in (EVIDENCE / "checksums.txt").read_text(encoding="utf-8").splitlines():
        digest, name = line.split(maxsplit=1)
        entries[name] = digest
    if set(entries) != EXPECTED_CHECKSUM_FILES:
        raise ValueError("seven-library checksum inventory is incomplete or has unexpected files")
    for name, expected in entries.items():
        if sha256(EVIDENCE / name) != expected:
            raise ValueError(f"seven-library checksum mismatch: {name}")


def safe_extract(
    archive_path: pathlib.Path,
    destination: pathlib.Path,
    expected_root: str,
    allowed_roots: set[str] | None = None,
) -> pathlib.Path:
    with tarfile.open(archive_path, "r:gz") as archive:
        members = archive.getmembers()
        for member in members:
            path = pathlib.PurePosixPath(member.name)
            if path.is_absolute() or ".." in path.parts or member.issym() or member.islnk():
                raise ValueError(f"unsafe archive member in {archive_path.name}: {member.name}")
        roots = {pathlib.PurePosixPath(member.name).parts[0] for member in members if member.name}
        allowed = allowed_roots if allowed_roots is not None else {expected_root}
        if roots != allowed:
            raise ValueError(f"unexpected archive roots in {archive_path.name}: {sorted(roots)}")
        archive.extractall(destination, filter="data")
    return destination / expected_root


def read_metadata_and_validate(root: pathlib.Path) -> dict[str, object]:
    if not (root / "COMPLETE").is_file():
        raise ValueError(f"missing COMPLETE marker: {root.name}")
    metadata = json.loads((root / "metadata.json").read_text(encoding="utf-8"))
    if metadata["runs"] != 11:
        raise ValueError(f"unexpected run count in {root.name}")
    with (root / "manifest.csv").open(newline="", encoding="utf-8") as stream:
        rows = list(csv.DictReader(stream))
    if len(rows) != 770:
        raise ValueError(f"expected 770 manifest cells in {root.name}, found {len(rows)}")
    if len({(row["round"], row["workload_id"], row["library"]) for row in rows}) != 770:
        raise ValueError(f"duplicate manifest cell in {root.name}")
    return metadata


def stable_identity(metadata: dict[str, object], key: str) -> object:
    value = metadata[key]
    if key != "versions":
        return value
    versions = dict(value)
    versions["cjpm"] = str(versions["cjpm"]).splitlines()[-1]
    return versions


def main() -> int:
    verify_checksums()
    readme = (EVIDENCE / "README.md").read_text(encoding="utf-8")
    result_doc = RESULT_DOC.read_text(encoding="utf-8")
    with tempfile.TemporaryDirectory() as temporary:
        scratch = pathlib.Path(temporary)
        harness_root = safe_extract(
            EVIDENCE / "harness-source.tar.gz",
            scratch / "harness",
            "harness",
            {"harness", "optimal-api-overlay-current.patch"},
        )
        summarize = harness_root / "summarize_full.py"
        identities: list[dict[str, object]] = []
        for index, name in enumerate(EXPECTED_ARCHIVES):
            expected_root = name.removesuffix(".tar.gz")
            extracted = safe_extract(
                EVIDENCE / name, scratch / f"formal-{index}", expected_root
            )
            identities.append(read_metadata_and_validate(extracted))
            expected = {
                suffix: (extracted / f"summary.{suffix}").read_bytes()
                for suffix in ("json", "csv", "md")
            }
            subprocess.run(
                ["python3", str(summarize), str(extracted), "--min-runs", "11"],
                check=True,
                stdout=subprocess.DEVNULL,
            )
            expected_json = extracted / "summary.expected.json"
            expected_json.write_bytes(expected["json"])
            subprocess.run(
                ["python3", str(ROOT / "scripts/check_json_numeric_equivalence.py"),
                 str(expected_json), str(extracted / "summary.json")],
                check=True,
            )
            for suffix in ("csv", "md"):
                if (extracted / f"summary.{suffix}").read_bytes() != expected[suffix]:
                    raise ValueError(f"derived summary drift in {name}: summary.{suffix}")

        stable_keys = ("versions", "source_sha256", "canonical_decode_payload_bytes", "api_policy")
        for key in stable_keys:
            if stable_identity(identities[0], key) != stable_identity(identities[1], key):
                raise ValueError(f"formal archive identity mismatch: {key}")
        commit = identities[0]["versions"]["yjson_commit"]
        if commit not in readme or commit not in result_doc:
            raise ValueError("archive yjson commit is not bound to README and result documentation")
    print("seven-library evidence passed: checksums, manifests, identities, and summaries")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
