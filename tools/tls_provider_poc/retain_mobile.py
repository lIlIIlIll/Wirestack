#!/usr/bin/env python3
"""Retain one validated GitHub-hosted mobile M0-016 result.

The hosted workflow deliberately writes into a disposable workspace.  This
tool is the review boundary between that workspace and the committed evidence
tree: it validates the result and license bundle first, copies them without
silently overwriting managed files, and updates exactly one matrix cell using
an atomic write.
"""
from __future__ import annotations

if __package__ in {None, ""}:
    import sys
    from pathlib import Path
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from tools import evidence_digest
from tools.tls_provider_poc import validate

import argparse
import json
import os
import shutil
import tempfile
from pathlib import Path
from typing import Any, Mapping, Sequence


ROOT = Path(__file__).resolve().parents[2]
MATRIX_RELATIVE = Path("docs/evidence/M0-016/platform-matrix.json")
RESULT_ROOT = Path("docs/evidence/M0-016/results")
LICENSE_ROOT = Path("docs/evidence/M0-016/license-bundles")
MOBILE_PLATFORMS = {"android-aarch64", "ios-aarch64"}
PROVIDERS = {"aws-lc", "mbedtls", "openssl"}


class RetentionError(RuntimeError):
    """Stable fail-closed error for hosted evidence ingestion."""

    def __init__(self, code: str, detail: str):
        super().__init__(detail)
        self.code = code
        self.detail = detail


def atomic_json(path: Path, value: Mapping[str, Any],
                before_replace: Any | None = None) -> None:
    """Publish bounded JSON atomically, with an optional race guard."""
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as stream:
            json.dump(value, stream, ensure_ascii=False, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        if before_replace is not None:
            before_replace()
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def require(condition: bool, code: str, detail: str) -> None:
    if not condition:
        raise RetentionError(code, detail)


def load_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise RetentionError("INPUT_INVALID", f"cannot read JSON input: {path}") from error
    require(isinstance(value, dict), "INPUT_INVALID", f"JSON root is not an object: {path}")
    return value


def inside(path: Path, root: Path, code: str) -> Path:
    resolved = path.resolve()
    root_resolved = root.resolve()
    require(resolved == root_resolved or root_resolved in resolved.parents,
            code, f"path escapes repository: {path}")
    return resolved


def relative_path(path: Path, root: Path) -> str:
    try:
        return path.resolve().relative_to(root.resolve()).as_posix()
    except ValueError as error:
        raise RetentionError("PATH_ESCAPE", f"path escapes repository: {path}") from error


def read_bytes(path: Path, code: str = "INPUT_INVALID") -> bytes:
    try:
        return path.read_bytes()
    except OSError as error:
        raise RetentionError(code, f"cannot read file: {path}") from error


def same_file(left: Path, right: Path) -> bool:
    return left.is_file() and right.is_file() and read_bytes(left) == read_bytes(right)


def assert_no_unsafe_entries(root: Path) -> None:
    require(not root.is_symlink(), "LICENSE_BUNDLE",
            "license bundle root must not be a symlink")
    root = root.resolve()
    require(root.is_dir(), "LICENSE_BUNDLE", "license bundle directory is missing")
    for current, directories, files in os.walk(root, topdown=True, followlinks=False):
        current_path = Path(current).resolve()
        require(current_path == root or root in current_path.parents,
                "PATH_ESCAPE", "license bundle traversal escaped source root")
        for name in [*directories, *files]:
            candidate = Path(current) / name
            require(not candidate.is_symlink(), "LICENSE_BUNDLE",
                    "license bundle must not contain symlinks")
            resolved = candidate.resolve()
            require(resolved == root or root in resolved.parents,
                    "PATH_ESCAPE", "license bundle entry escapes source root")


def assert_same_tree(left: Path, right: Path) -> None:
    """Compare two trees by relative names and exact bytes without following links."""
    assert_no_unsafe_entries(left)
    assert_no_unsafe_entries(right)
    left_entries = {
        path.relative_to(left).as_posix(): path
        for path in left.rglob("*")
        if not path.is_dir()
    }
    right_entries = {
        path.relative_to(right).as_posix(): path
        for path in right.rglob("*")
        if not path.is_dir()
    }
    require(set(left_entries) == set(right_entries), "DESTINATION_MISMATCH",
            "existing license bundle has different file inventory")
    for name in sorted(left_entries):
        require(same_file(left_entries[name], right_entries[name]),
                "DESTINATION_MISMATCH",
                f"existing license bundle differs at {name}")


def install_file(source: Path, destination: Path) -> bool:
    """Install a file atomically, preserving an identical existing file."""
    source_bytes = read_bytes(source)
    require(not destination.is_symlink(), "DESTINATION_MISMATCH",
            f"managed evidence path must not be a symlink: {destination}")
    if destination.exists():
        require(same_file(source, destination), "DESTINATION_MISMATCH",
                f"managed evidence file differs: {destination}")
        return False
    destination.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary_name = tempfile.mkstemp(
        prefix=f".{destination.name}.", suffix=".tmp", dir=destination.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(source_bytes)
            stream.flush()
            os.fsync(stream.fileno())
        # A hard-link publication fails if another writer won the race, so we
        # never overwrite a managed file after the initial existence check.
        try:
            os.link(temporary, destination)
        except FileExistsError:
            require(same_file(source, destination), "DESTINATION_MISMATCH",
                    f"managed evidence file differs: {destination}")
            return False
        return True
    finally:
        temporary.unlink(missing_ok=True)


def install_tree(source: Path, destination: Path) -> bool:
    """Install a license tree atomically, or verify an identical tree."""
    assert_no_unsafe_entries(source)
    require(not destination.is_symlink(), "DESTINATION_MISMATCH",
            f"managed evidence path must not be a symlink: {destination}")
    if destination.exists():
        assert_same_tree(source, destination)
        return False
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.parent / f".{destination.name}.tmp-{os.getpid()}"
    if temporary.exists():
        raise RetentionError("DESTINATION_BUSY", f"temporary destination exists: {temporary}")
    try:
        shutil.copytree(source, temporary, symlinks=False)
        os.replace(temporary, destination)
        return True
    except FileExistsError as error:
        raise RetentionError("DESTINATION_BUSY", f"destination appeared during publish: {destination}") from error
    finally:
        if temporary.exists():
            shutil.rmtree(temporary, ignore_errors=True)


def update_cell(matrix: Mapping[str, Any], *, platform: str, provider: str,
                result_relative: str, result_sha256: str,
                manifest_relative: str, manifest_sha256: str,
                reason: str) -> dict[str, Any]:
    value = json.loads(json.dumps(matrix))
    cells = value.get("cells")
    require(isinstance(cells, list), "MATRIX_INVALID", "matrix cells are missing")
    matching = [cell for cell in cells
                if isinstance(cell, dict) and cell.get("platform") == platform
                and cell.get("provider") == provider]
    require(len(matching) == 1, "MATRIX_INVALID",
            f"matrix must contain exactly one {platform}/{provider} cell")
    cell = matching[0]
    current_status = cell.get("status")
    desired = {
        "provider": provider,
        "platform": platform,
        "status": None,
        "reason": reason,
        "result": result_relative,
        "sha256": result_sha256,
        "license_bundle": {
            "manifest": manifest_relative,
            "sha256": manifest_sha256,
        },
    }
    if current_status in {"PASS", "PARTIAL", "FAIL"}:
        # Idempotent re-ingestion is safe only when the matrix already points
        # at this exact result and status.  A different retained result must
        # be reviewed explicitly rather than replaced by a helper.
        existing_bundle = cell.get("license_bundle")
        require(isinstance(existing_bundle, dict), "MATRIX_INVALID",
                "retained matrix cell has no license bundle object")
        require(cell.get("result") == result_relative and
                evidence_digest.schema_text_sha256_equal(
                    cell.get("sha256"), result_sha256) and
                existing_bundle.get("manifest") == manifest_relative and
                evidence_digest.schema_text_sha256_equal(
                    existing_bundle.get("sha256"), manifest_sha256),
                "MATRIX_ALREADY_RETAINED",
                f"matrix cell already retains different evidence: {platform}/{provider}")
        desired["status"] = current_status
        desired["reason"] = cell.get("reason") or reason
    else:
        require(current_status in {"BLOCKED", "NOT_RUN"}, "MATRIX_INVALID",
                f"unexpected matrix status: {current_status}")
        desired["status"] = None  # filled by caller after result validation
    index = cells.index(cell)
    value["cells"][index] = desired
    return value


def retain(*, repo: Path, matrix_path: Path, result_path: Path,
           license_bundle_path: Path, expected_revision: str) -> dict[str, Any]:
    repo = repo.resolve()
    matrix_path = inside(matrix_path, repo, "PATH_ESCAPE")
    result_path = result_path.resolve()
    license_bundle_path = license_bundle_path.resolve()
    require(result_path.is_file(), "INPUT_INVALID", "result JSON is missing")
    require(license_bundle_path.is_dir(), "INPUT_INVALID",
            "license bundle directory is missing")
    require(validate.COMMIT_RE.fullmatch(expected_revision) is not None,
            "STALE_REVISION", "expected revision must be an exact SHA")
    result = load_json(result_path)
    spec = load_json(repo / "tools/tls_provider_poc/providers.json")
    platform = result.get("platform")
    provider = result.get("provider")
    require(platform in MOBILE_PLATFORMS, "PLATFORM",
            "only required Android/iOS mobile cells may be retained; supplemental targets stay outside the matrix")
    require(provider in PROVIDERS, "PROVIDER", "unknown provider")
    try:
        validate.validate_result(result, spec, expected_revision)
    except validate.ValidationError as error:
        raise RetentionError("RESULT_INVALID", str(error)) from error
    require(result.get("status") in {"PASS", "PARTIAL"}, "RESULT_INCOMPLETE",
            "only PASS or PARTIAL mobile results may enter the retained matrix")
    manifest = license_bundle_path / "manifest.json"
    require(manifest.is_file(), "LICENSE_BUNDLE", "license bundle manifest is missing")
    try:
        validate.validate_license_bundle(result_path, result, manifest)
    except validate.ValidationError as error:
        raise RetentionError("LICENSE_BUNDLE", str(error)) from error
    assert_no_unsafe_entries(license_bundle_path)

    result_destination = inside(
        repo / RESULT_ROOT / platform / f"{provider}.json", repo, "PATH_ESCAPE")
    bundle_destination = inside(
        repo / LICENSE_ROOT / platform / provider, repo, "PATH_ESCAPE")
    manifest_destination = bundle_destination / "manifest.json"
    result_relative = relative_path(result_destination, repo)
    manifest_relative = relative_path(manifest_destination, repo)
    result_sha256 = evidence_digest.text_evidence_sha256(result_path)
    manifest_sha256 = evidence_digest.text_evidence_sha256(manifest)

    original_matrix_bytes = read_bytes(matrix_path, "MATRIX_INVALID")
    matrix = load_json(matrix_path)
    try:
        validate.validate_matrix(matrix, spec)
    except validate.ValidationError as error:
        raise RetentionError("MATRIX_INVALID", str(error)) from error
    updated = update_cell(
        matrix, platform=platform, provider=provider,
        result_relative=result_relative, result_sha256=result_sha256,
        manifest_relative=manifest_relative, manifest_sha256=manifest_sha256,
        reason=("GitHub-hosted native VM evidence validated at exact revision "
                f"{expected_revision} ({result['execution']['native_runtime']['kind']})."),
    )
    # Set the status only after the result was validated; update_cell keeps the
    # idempotent status when this cell has already been retained.
    for cell in updated["cells"]:
        if cell.get("platform") == platform and cell.get("provider") == provider:
            if cell["status"] is None:
                cell["status"] = result["status"]
            break

    install_file(result_path, result_destination)
    install_tree(license_bundle_path, bundle_destination)
    try:
        atomic_json(
            matrix_path, updated,
            before_replace=lambda: require(
                read_bytes(matrix_path, "MATRIX_INVALID") == original_matrix_bytes,
                "MATRIX_CHANGED", "matrix changed while retaining mobile evidence"),
        )
    except RetentionError:
        raise
    except (OSError, TypeError, ValueError) as error:
        raise RetentionError("MATRIX_WRITE", "unable to publish matrix atomically") from error

    # Validate the newly published pair using the same override used by the
    # matrix validator.  This catches a copy/layout bug before reporting PASS.
    retained_result = load_json(result_destination)
    try:
        validate.validate_license_bundle(
            result_destination, retained_result, manifest_destination)
    except validate.ValidationError as error:
        raise RetentionError("RETAINED_INVALID", str(error)) from error
    return {
        "schema_version": 1,
        "task_id": "M0-016",
        "status": "PASS",
        "platform": platform,
        "provider": provider,
        "repository_revision": expected_revision,
        "result": result_relative,
        "result_sha256": result_sha256,
        "license_manifest": manifest_relative,
        "license_manifest_sha256": manifest_sha256,
        "native_runtime": result["execution"]["native_runtime"]["kind"],
    }


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=ROOT)
    parser.add_argument("--matrix", type=Path)
    parser.add_argument("--result", type=Path, required=True)
    parser.add_argument("--license-bundle", type=Path, required=True)
    parser.add_argument("--expected-revision", required=True)
    parser.add_argument("--report", type=Path)
    args = parser.parse_args(argv)
    repo = args.repo.resolve()
    matrix = args.matrix or (repo / MATRIX_RELATIVE)
    try:
        report = retain(
            repo=repo,
            matrix_path=matrix,
            result_path=args.result,
            license_bundle_path=args.license_bundle,
            expected_revision=args.expected_revision.lower(),
        )
    except RetentionError as error:
        report = {
            "schema_version": 1,
            "task_id": "M0-016",
            "status": "FAIL",
            "code": error.code,
            "detail": error.detail[:2048],
        }
        print(json.dumps(report, sort_keys=True))
        if args.report:
            atomic_json(args.report, report)
        return 1
    print(json.dumps(report, sort_keys=True))
    if args.report:
        atomic_json(args.report, report)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
