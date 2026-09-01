#!/usr/bin/env python3
"""Typed SHA-256 domains for repository text evidence and binary artifacts."""

from __future__ import annotations

import argparse
import ast
import hashlib
import json
import os
import platform
import re
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Iterable, Mapping, Sequence

TEXT_EVIDENCE_DOMAIN = "text-utf8-lf-v1"
ARTIFACT_BYTE_DOMAIN = "artifact-bytes-v1"
DIGEST_KEYS = {"domain", "sha256"}
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")


class DigestError(ValueError):
    """Stable fail-closed error for digest domain and input violations."""

    def __init__(self, code: str, detail: str):
        super().__init__(detail)
        self.code = code
        self.detail = detail


def _validated_sha256(value: str) -> str:
    if not isinstance(value, str) or SHA256_RE.fullmatch(value) is None:
        raise DigestError("DIGEST_INVALID", "sha256 must be 64 lowercase hexadecimal characters")
    return value


@dataclass(frozen=True)
class TextEvidenceDigest:
    sha256: str

    def __post_init__(self) -> None:
        object.__setattr__(self, "sha256", _validated_sha256(self.sha256))

    def to_json(self) -> dict[str, str]:
        return {"domain": TEXT_EVIDENCE_DOMAIN, "sha256": self.sha256}


@dataclass(frozen=True)
class ArtifactByteDigest:
    sha256: str

    def __post_init__(self) -> None:
        object.__setattr__(self, "sha256", _validated_sha256(self.sha256))

    def to_json(self) -> dict[str, str]:
        return {"domain": ARTIFACT_BYTE_DOMAIN, "sha256": self.sha256}


def canonical_text_bytes(raw: bytes) -> bytes:
    try:
        text = raw.decode("utf-8", errors="strict")
    except UnicodeDecodeError as error:
        raise DigestError("TEXT_UTF8", "text evidence is not valid UTF-8") from error
    return text.replace("\r\n", "\n").replace("\r", "\n").encode("utf-8")


def text_evidence_digest_bytes(raw: bytes) -> TextEvidenceDigest:
    return TextEvidenceDigest(hashlib.sha256(canonical_text_bytes(raw)).hexdigest())


def text_evidence_digest(path: Path) -> TextEvidenceDigest:
    try:
        raw = path.read_bytes()
    except OSError as error:
        raise DigestError("DIGEST_READ", f"cannot read text evidence: {path}") from error
    return text_evidence_digest_bytes(raw)


def artifact_byte_digest_bytes(raw: bytes) -> ArtifactByteDigest:
    return ArtifactByteDigest(hashlib.sha256(raw).hexdigest())


def artifact_byte_digest(path: Path) -> ArtifactByteDigest:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(block)
    except OSError as error:
        raise DigestError("DIGEST_READ", f"cannot read binary artifact: {path}") from error
    return ArtifactByteDigest(digest.hexdigest())


def text_evidence_sha256(path: Path) -> str:
    """Return a text-domain value for task-local string schemas."""
    return text_evidence_digest(path).sha256


def text_evidence_bytes_sha256(raw: bytes) -> str:
    """Return a text-domain value for task-local string schemas."""
    return text_evidence_digest_bytes(raw).sha256


def artifact_byte_sha256(path: Path) -> str:
    """Return a byte-domain value for task-local string schemas."""
    return artifact_byte_digest(path).sha256


def artifact_bytes_sha256(raw: bytes) -> str:
    """Return a byte-domain value for task-local string schemas."""
    return artifact_byte_digest_bytes(raw).sha256


def text_evidence_inventory_sha256(root: Path, paths: Iterable[Path]) -> str:
    """Hash a sorted repository text inventory with path framing."""
    base = root.resolve()
    payload = bytearray()
    for path in sorted((value.resolve() for value in paths), key=lambda value: value.as_posix()):
        try:
            relative = path.relative_to(base).as_posix()
        except ValueError as error:
            raise DigestError("PATH_ESCAPE", f"text evidence path escapes repository: {path}") from error
        payload.extend(relative.encode("utf-8"))
        payload.extend(b"\0")
        try:
            payload.extend(canonical_text_bytes(path.read_bytes()))
        except OSError as error:
            raise DigestError("DIGEST_READ", f"cannot read text evidence: {path}") from error
        payload.extend(b"\0")
    return text_evidence_bytes_sha256(bytes(payload))


def _parse(raw: Any, expected_domain: str, factory: Callable[[str], Any], field: str) -> Any:
    if not isinstance(raw, dict):
        raise DigestError("DIGEST_TYPE", f"{field} must be a typed digest object")
    unknown = sorted(set(raw) - DIGEST_KEYS)
    if unknown or set(raw) != DIGEST_KEYS:
        raise DigestError("DIGEST_FIELDS", f"{field} must contain only domain and sha256")
    domain = raw.get("domain")
    if domain != expected_domain:
        raise DigestError("DIGEST_DOMAIN", f"{field} has unsupported or mismatched digest domain")
    return factory(raw.get("sha256"))


def parse_text_digest(raw: Any, field: str = "digest") -> TextEvidenceDigest:
    return _parse(raw, TEXT_EVIDENCE_DOMAIN, TextEvidenceDigest, field)


def parse_artifact_digest(raw: Any, field: str = "digest") -> ArtifactByteDigest:
    return _parse(raw, ARTIFACT_BYTE_DOMAIN, ArtifactByteDigest, field)


def atomic_json(path: Path, value: Mapping[str, Any], before_replace: Callable[[], None] | None = None) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    temporary = Path(name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as stream:
            json.dump(value, stream, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        if before_replace is not None:
            before_replace()
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def _revision(root: Path | None) -> str | None:
    if root is None:
        return os.environ.get("GITHUB_SHA")
    try:
        result = subprocess.run(
            ["git", "rev-parse", "HEAD"], cwd=root, capture_output=True,
            text=True, timeout=5, check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return os.environ.get("GITHUB_SHA")
    return result.stdout.strip() if result.returncode == 0 else os.environ.get("GITHUB_SHA")


def crlf_report(expected_platform: str | None = None, root: Path | None = None) -> dict[str, Any]:
    actual = f"{platform.system().lower()}-{platform.machine().lower()}"
    expected_prefix = expected_platform.split("-", 1)[0] if expected_platform else None
    issues: list[dict[str, str]] = []
    if expected_prefix and not actual.startswith(expected_prefix + "-"):
        issues.append({"code": "PLATFORM_MISMATCH", "detail": f"expected {expected_platform}, got {actual}"})
    variants = {
        "lf": b"alpha\nbeta\n",
        "crlf": b"alpha\r\nbeta\r\n",
        "bare_cr": b"alpha\rbeta\r",
    }
    text_digests = {name: text_evidence_digest_bytes(value).to_json() for name, value in variants.items()}
    byte_digests = {name: artifact_byte_digest_bytes(value).to_json() for name, value in variants.items()}
    if len({item["sha256"] for item in text_digests.values()}) != 1:
        issues.append({"code": "TEXT_LINE_ENDING_DRIFT", "detail": "canonical text digests differ"})
    if len({item["sha256"] for item in byte_digests.values()}) != len(variants):
        issues.append({"code": "BYTE_DOMAIN_COLLISION", "detail": "raw byte digests did not preserve line endings"})
    invalid_utf8 = "REJECTED"
    try:
        text_evidence_digest_bytes(b"valid\n\xff")
        invalid_utf8 = "ACCEPTED"
        issues.append({"code": "INVALID_UTF8_ACCEPTED", "detail": "invalid UTF-8 entered the text domain"})
    except DigestError as error:
        if error.code != "TEXT_UTF8":
            issues.append({"code": "INVALID_UTF8_ERROR", "detail": error.code})
    return {
        "schema_version": 1,
        "kind": "p1-014-crlf-fault-injection",
        "status": "PASS" if not issues else "FAIL",
        "platform": {"system": platform.system(), "machine": platform.machine(), "identity": actual},
        "expected_platform": expected_platform,
        "revision": _revision(root),
        "text_digests": text_digests,
        "byte_digests": byte_digests,
        "invalid_utf8": invalid_utf8,
        "gitattributes_dependency": False,
        "issues": issues,
    }


_CALL_DOMAINS = {
    "text_evidence_digest": "text-evidence",
    "text_evidence_digest_bytes": "text-evidence",
    "parse_text_digest": "text-evidence",
    "artifact_byte_digest": "artifact-bytes",
    "artifact_byte_digest_bytes": "artifact-bytes",
    "parse_artifact_digest": "artifact-bytes",
    "text_evidence_sha256": "text-evidence",
    "text_evidence_bytes_sha256": "text-evidence",
    "artifact_byte_sha256": "artifact-bytes",
    "artifact_bytes_sha256": "artifact-bytes",
    "text_evidence_inventory_sha256": "text-evidence",
    "sha256_path": "legacy-task-local",
    "canonical_text_sha256": "legacy-task-local-text",
    "repository_text_sha256": "legacy-task-local-text",
}


def _call_name(node: ast.Call) -> str | None:
    if isinstance(node.func, ast.Name):
        return node.func.id
    if isinstance(node.func, ast.Attribute):
        if (node.func.attr == "sha256" and isinstance(node.func.value, ast.Name)
                and node.func.value.id == "hashlib"):
            return "hashlib.sha256"
        return node.func.attr
    return None


def digest_inventory(root: Path) -> dict[str, Any]:
    entries: list[dict[str, Any]] = []
    issues: list[dict[str, str]] = []
    for base in (root / "tools", root / "scripts"):
        if not base.is_dir():
            continue
        for path in sorted(base.rglob("*.py")):
            if any(part in {"__pycache__", "build", "dist"} for part in path.parts):
                continue
            relative = path.relative_to(root).as_posix()
            try:
                tree = ast.parse(path.read_text(encoding="utf-8"), filename=relative)
            except (OSError, UnicodeDecodeError, SyntaxError) as error:
                issues.append({"code": "INVENTORY_PARSE", "detail": f"{relative}: {type(error).__name__}"})
                continue
            for node in ast.walk(tree):
                if not isinstance(node, ast.Call):
                    continue
                name = _call_name(node)
                if name not in _CALL_DOMAINS and name != "hashlib.sha256":
                    continue
                if name == "hashlib.sha256":
                    domain = "typed-implementation" if relative == "tools/evidence_digest.py" else "legacy-task-local"
                else:
                    domain = _CALL_DOMAINS[name]
                entries.append({"path": relative, "line": node.lineno, "symbol": name, "classification": domain})
                if domain.startswith("legacy"):
                    issues.append({"code": "UNTYPED_DIGEST", "detail": f"{relative}:{node.lineno}:{name}"})
    entries.sort(key=lambda item: (item["path"], item["line"], item["symbol"]))
    domain_counts: dict[str, int] = {}
    for entry in entries:
        classification = entry["classification"]
        domain_counts[classification] = domain_counts.get(classification, 0) + 1
    return {
        "schema_version": 1,
        "kind": "p1-014-digest-inventory",
        "status": "PASS" if not issues else "FAIL",
        "scope": "repository-wide typed digest callsite inventory",
        "entry_count": len(entries),
        "domain_counts": dict(sorted(domain_counts.items())),
        "entries": entries,
        "issues": issues,
    }


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    sub = result.add_subparsers(dest="command", required=True)
    crlf = sub.add_parser("crlf-report")
    crlf.add_argument("--expected-platform")
    crlf.add_argument("--output", type=Path, required=True)
    inventory = sub.add_parser("inventory")
    inventory.add_argument("--output", type=Path, required=True)
    return result


def main(argv: Sequence[str] | None = None) -> int:
    args = parser().parse_args(argv)
    root = args.root.resolve()
    report = crlf_report(args.expected_platform, root) if args.command == "crlf-report" else digest_inventory(root)
    output = args.output if args.output.is_absolute() else root / args.output
    atomic_json(output, report)
    summary = {
        "kind": report["kind"],
        "status": report["status"],
        "issues": report.get("issues", [])[:20],
        "output": str(output),
    }
    if "entry_count" in report:
        summary["entry_count"] = report["entry_count"]
    print(json.dumps(summary, sort_keys=True))
    return 0 if report["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
