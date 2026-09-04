#!/usr/bin/env python3
"""Fetch pinned official JSON suites and run the public yjson adapter."""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
from pathlib import Path


SUITES = {
    "json-schema": (
        "json-schema-org/JSON-Schema-Test-Suite",
        "b01af8c8d50244a2eb4dd3e01073e24823aa8691",
        "76915a25b6333f77cc37f2a9ff714f8feb9435b588ed2a7e48f6236257afa6d7",
    ),
    "jsonpath": (
        "jsonpath-standard/jsonpath-compliance-test-suite",
        "7be7c1fc28057c91e8eefaf197060fba7ed43acd",
        "e4dd491e865f756b4e060d338217d329c1423e7e40a6987bf803b88c230f57e5",
    ),
    "json-patch": (
        "json-patch/json-patch-tests",
        "2a928f9044aad35c74e2788d498bcf2c6b91adea",
        "4b7d9e50bcd6be33d8c36818084c572b3e641f38608ba88522159a0a9fd700c4",
    ),
}


def prefetch_hint(cache: Path) -> str:
    commands = [
        (
            f"curl -fL https://github.com/{owner_repo}/archive/{commit}.tar.gz "
            f"-o {cache}/{name}-{commit}.tar.gz && "
            f"echo '{sha256}  {cache}/{name}-{commit}.tar.gz' | sha256sum -c -"
        )
        for name, (owner_repo, commit, sha256) in SUITES.items()
    ]
    expected = "\n".join(
        f"  {cache}/{name}-{commit}.tar.gz  ({sha256[:12]})"
        for name, (owner_repo, commit, sha256) in SUITES.items()
    )
    return (
        "offline mode requires every pinned suite to be present in the cache. "
        "Prefetch into the cache directory with:\n"
        + "\n".join(commands)
        + "\nExpected sha256 digests:\n"
        + expected
    )


def fetch_suite(cache: Path, name: str, offline: bool) -> Path:
    owner_repo, commit, sha256 = SUITES[name]
    destination = cache / f"{name}-{commit}"
    marker = destination / ".yjson-suite-commit"
    if marker.is_file() and marker.read_text(encoding="utf-8").strip() == commit:
        return destination
    archive = cache / f"{name}-{commit}.tar.gz"
    if offline:
        if archive.is_file():
            digest = hashlib.sha256(archive.read_bytes()).hexdigest()
            if digest != sha256:
                raise RuntimeError(
                    f"cached {name} archive sha256 mismatch: "
                    f"expected {sha256}, got {digest}\n{prefetch_hint(cache)}"
                )
            return extract_suite(cache, name, archive, destination, marker, commit)
        raise RuntimeError(
            f"pinned {name} suite is absent from {cache}\n{prefetch_hint(cache)}"
        )
    cache.mkdir(parents=True, exist_ok=True)
    url = f"https://github.com/{owner_repo}/archive/{commit}.tar.gz"
    print(f"fetch {name} {commit}", flush=True)
    urllib.request.urlretrieve(url, archive)
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    if digest != sha256:
        archive.unlink(missing_ok=True)
        raise RuntimeError(
            f"pinned {name} archive sha256 mismatch: expected {sha256}, got {digest}"
        )
    return extract_suite(cache, name, archive, destination, marker, commit)


def prefetch(cache: Path) -> None:
    """Download and SHA-256 verify every pinned suite archive into the cache.

    Archives are kept as cache artifacts; an offline run later consumes them
    via fetch_suite(..., offline=True).
    """

    cache.mkdir(parents=True, exist_ok=True)
    for name, (owner_repo, commit, sha256) in SUITES.items():
        archive = cache / f"{name}-{commit}.tar.gz"
        if archive.is_file():
            digest = hashlib.sha256(archive.read_bytes()).hexdigest()
            if digest == sha256:
                print(f"verified {name} {commit}", flush=True)
                continue
            archive.unlink(missing_ok=True)
        url = f"https://github.com/{owner_repo}/archive/{commit}.tar.gz"
        print(f"fetch {name} {commit}", flush=True)
        urllib.request.urlretrieve(url, archive)
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        if digest != sha256:
            archive.unlink(missing_ok=True)
            raise RuntimeError(
                f"pinned {name} archive sha256 mismatch: expected {sha256}, got {digest}"
            )


def extract_suite(
    cache: Path, name: str, archive: Path, destination: Path, marker: Path, commit: str
) -> Path:
    extraction = Path(tempfile.mkdtemp(prefix=f"yjson-{name}-", dir=cache))
    try:
        with tarfile.open(archive, "r:gz") as bundle:
            bundle.extractall(extraction, filter="data")
        roots = list(extraction.iterdir())
        if len(roots) != 1 or not roots[0].is_dir():
            raise RuntimeError(f"unexpected {name} archive layout")
        if destination.exists():
            shutil.rmtree(destination)
        roots[0].rename(destination)
        marker.write_text(commit + "\n", encoding="utf-8")
    finally:
        shutil.rmtree(extraction, ignore_errors=True)
        archive.unlink(missing_ok=True)
    return destination


def load_json(path: Path):
    with path.open("r", encoding="utf-8") as stream:
        return json.load(stream)


def schema_manifest(root: Path, include_optional: bool) -> dict:
    files = []
    test_root = root / "tests" / "draft2020-12"
    for path in sorted(test_root.glob("*.json")):
        files.append({"source": path.name, "groups": load_json(path)})
    if include_optional:
        optional_root = test_root / "optional"
        excluded = {"cross-draft.json", "dependencies-compatibility.json"}
        for path in sorted(optional_root.rglob("*.json")):
            if path.name in excluded:
                continue
            relative = path.relative_to(test_root).as_posix()
            files.append({
                "source": relative,
                "groups": load_json(path),
                "format_assertion": relative.startswith("optional/format/") or relative == "optional/format-assertion.json",
            })
    remotes = {}
    remote_root = root / "remotes"
    for path in sorted(remote_root.rglob("*.json")):
        relative = path.relative_to(remote_root).as_posix()
        remotes[f"http://localhost:1234/{relative}"] = load_json(path)
    return {"files": files, "remotes": remotes, "install_format_plugin": include_optional}


def json_patch_manifest(root: Path) -> list:
    tests = []
    for filename in ("tests.json", "spec_tests.json"):
        for test in load_json(root / filename):
            if test.get("disabled", False):
                continue
            copied = dict(test)
            copied["source"] = filename
            tests.append(copied)
    return tests


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cache", type=Path, default=Path("/tmp/yjson-standards-suites"))
    parser.add_argument(
        "--offline",
        action="store_true",
        help="only use cached suites; fail with a prefetch hint when a pinned suite is missing",
    )
    parser.add_argument(
        "--prefetch",
        action="store_true",
        help="download and SHA-256 verify every pinned suite archive into the cache, then exit",
    )
    parser.add_argument("--keep-manifest", type=Path)
    parser.add_argument("--schema-root", type=Path)
    parser.add_argument("--jsonpath-root", type=Path)
    parser.add_argument("--json-patch-root", type=Path)
    parser.add_argument("--report", type=Path)
    parser.add_argument("--quiet-failures", action="store_true")
    parser.add_argument("--include-schema-optional", action="store_true")
    parser.add_argument("--override-compile-option", default="")
    args = parser.parse_args()

    if args.prefetch:
        prefetch(args.cache)
        return 0

    supplied = {
        "json-schema": args.schema_root,
        "jsonpath": args.jsonpath_root,
        "json-patch": args.json_patch_root,
    }
    roots = {
        name: path.resolve() if path is not None else fetch_suite(args.cache, name, args.offline)
        for name, path in supplied.items()
    }
    manifest = {
        "schema": schema_manifest(roots["json-schema"], args.include_schema_optional),
        "jsonpath": load_json(roots["jsonpath"] / "cts.json")["tests"],
        "jsonpatch": json_patch_manifest(roots["json-patch"]),
    }
    expected = (2263 if args.include_schema_optional else 1299, 703, 108)
    actual = (
        sum(len(group["tests"]) for file in manifest["schema"]["files"] for group in file["groups"]),
        len(manifest["jsonpath"]),
        len(manifest["jsonpatch"]),
    )
    if actual != expected:
        raise RuntimeError(f"suite cardinality changed: expected={expected}, actual={actual}")

    temporary = None
    if args.keep_manifest:
        manifest_path = args.keep_manifest.resolve()
        manifest_path.parent.mkdir(parents=True, exist_ok=True)
    else:
        temporary = tempfile.TemporaryDirectory(prefix="yjson-conformance-")
        manifest_path = Path(temporary.name) / "manifest.json"
    with manifest_path.open("w", encoding="utf-8") as stream:
        json.dump(manifest, stream, ensure_ascii=False, separators=(",", ":"))

    repo = Path(__file__).resolve().parent.parent
    command = ["cjpm", "run", "--", str(manifest_path)]
    print(f"run schema={actual[0]} jsonpath={actual[1]} jsonpatch={actual[2]}", flush=True)
    project = repo / "packages" / "standards_conformance"
    project_manifest = project / "cjpm.toml"
    original_manifest = None
    if args.override_compile_option:
        original_manifest = project_manifest.read_text(encoding="utf-8")
        marker = 'override-compile-option = ""'
        if original_manifest.count(marker) != 1:
            raise RuntimeError("unexpected standards conformance manifest")
        project_manifest.write_text(
            original_manifest.replace(
                marker,
                f'override-compile-option = "{args.override_compile_option}"',
            ),
            encoding="utf-8",
        )
    try:
        completed = subprocess.run(
            command,
            cwd=project,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
    finally:
        if original_manifest is not None:
            project_manifest.write_text(original_manifest, encoding="utf-8")
    if args.report:
        args.report.write_text(completed.stdout, encoding="utf-8")
    if args.quiet_failures:
        for line in completed.stdout.splitlines():
            if line.startswith("SUMMARY\t"):
                print(line)
    else:
        sys.stdout.write(completed.stdout)
    summaries = [line for line in completed.stdout.splitlines() if line.startswith("SUMMARY\t")]
    if len(summaries) != 1:
        if args.quiet_failures and completed.stdout:
            # Quiet mode normally keeps the conformance log concise. If the
            # adapter never starts, retain its compiler/runtime diagnostics so
            # hosted CI failures remain actionable.
            sys.stderr.write(completed.stdout)
            if not completed.stdout.endswith("\n"):
                sys.stderr.write("\n")
        print("conformance adapter did not emit exactly one SUMMARY line", file=sys.stderr)
        result = 1
    else:
        fields = dict(field.split("=", 1) for field in summaries[0].split("\t")[1:])
        result = 0 if fields.get("failed") == "0" else 1
    if temporary is not None:
        temporary.cleanup()
    return result if completed.returncode == 0 else completed.returncode


if __name__ == "__main__":
    sys.exit(main())
