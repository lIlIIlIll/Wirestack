#!/usr/bin/env python3
"""Build and validate the M7-028 Linux security review package."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
from pathlib import Path
from typing import Any, Callable, Mapping, Sequence


ROOT = Path(__file__).resolve().parents[1]
TASK_ID = "M7-028"
SCHEMA_VERSION = 1
PROFILE = "linux-x86_64-glibc"
DEFAULT_INDEX = ROOT / "docs/security/review/linux-1.0/evidence-index.json"
DEFAULT_REPORT = ROOT / "docs/evidence/M7-028/linux_x86_64/review-package.json"
COMPATIBILITY_POLICY = "NO_BACKWARD_COMPATIBILITY_PRE_1_0"

DOCUMENTS = (
    ("review-scope", "docs/security/review/linux-1.0/README.md"),
    ("threat-model", "docs/security/threat-model.md"),
    ("threat-model-machine", "docs/security/threat-model.json"),
    ("architecture", "docs/security/review/linux-1.0/architecture.md"),
    ("provider", "docs/security/review/linux-1.0/provider-and-native-boundary.md"),
    ("c-abi", "docs/security/review/linux-1.0/provider-and-native-boundary.md"),
    ("parsers", "docs/security/review/linux-1.0/parsers-and-limits.md"),
    ("key-trust", "docs/security/review/linux-1.0/keys-trust-and-data.md"),
    ("known-limitations", "docs/security/review/linux-1.0/known-limitations.md"),
    ("reproduction", "docs/security/review/linux-1.0/reproduce.md"),
    ("environment", "docs/references/environment.md"),
)

EVIDENCE = (
    ("fuzz", "M7-023", "docs/evidence/M7-023/linux_glibc_x86_64/fuzz-report.json", "CURRENT_PASS", True),
    ("parser-replay", "M7-023", "docs/evidence/M7-023/linux_glibc_x86_64/replay-report.json", "CURRENT_PASS", True),
    ("public-api", "M7-032", "docs/evidence/M7-032/linux_x86_64/public-api.json", "CURRENT_PASS", True),
    ("clean-consumer", "M7-032", "docs/evidence/M7-032/linux_x86_64/clean-consumer.json", "CURRENT_PASS", True),
    ("installed-audit", "M7-019", "docs/evidence/M7-019/linux_x86_64/audit.data", "STALE_AFTER_M7_032", False),
    ("artifact-audit", "M7-020", "docs/evidence/M7-020/linux_x86_64/audit.data", "CURRENT_PASS", True),
    ("installation", "M7-021", "docs/evidence/M7-021/linux_x86_64/qualification.json", "CURRENT_PASS", True),
    ("performance", "M7-024", "docs/evidence/M7-024/linux_glibc_x86_64/performance-gate.json", "CURRENT_PASS", True),
    ("supply-chain-validation", "M7-025", "docs/evidence/M7-025/linux_x86_64/bundle.json", "CURRENT_PASS", True),
    ("sbom", "M7-025", "docs/evidence/M7-025/linux_x86_64/sbom.spdx.json", "CURRENT_BOUND_INPUT", False),
    ("provider-manifest", "M7-025", "docs/evidence/M7-025/linux_x86_64/provider-manifest.json", "CURRENT_BOUND_INPUT", False),
    ("build-fingerprint", "M7-025", "docs/evidence/M7-025/linux_x86_64/build-fingerprint.json", "CURRENT_BOUND_INPUT", False),
    ("api-history", "M7-026", "docs/evidence/M7-026/linux_x86_64/api-compatibility.json", "HISTORICAL_NON_GATING", False),
)

REQUIRED_TOPICS = frozenset({
    "threat-model", "architecture", "provider", "c-abi", "parsers",
    "key-trust", "fuzz", "sbom", "known-limitations", "reproduction",
    "environment",
})

SECRET_PATTERNS = (
    ("private-key", re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----")),
    ("authorization-value", re.compile(r"(?im)^\s*authorization\s*:\s*(?!<redacted>|REDACTED\s*$)\S+")),
    ("cookie-value", re.compile(r"(?im)^\s*(?:cookie|set-cookie)\s*:\s*(?!<redacted>|REDACTED\s*$)\S+")),
    ("captured-request-body", re.compile(r"(?im)^\s*captured[_ -]?request[_ -]?body\s*[:=]\s*\S+")),
)


class ReviewPackageError(RuntimeError):
    def __init__(self, code: str, detail: str):
        super().__init__(detail)
        self.code = code
        self.detail = detail


def require(condition: bool, code: str, detail: str) -> None:
    if not condition:
        raise ReviewPackageError(code, detail)


def canonical_json(value: Any) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def sha256_path(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as stream:
            for block in iter(lambda: stream.read(65536), b""):
                digest.update(block)
    except OSError as error:
        raise ReviewPackageError("FILE_MISSING", str(path)) from error
    return digest.hexdigest()


def safe_path(root: Path, relative: str) -> Path:
    candidate = Path(relative)
    require(not candidate.is_absolute(), "PATH_ESCAPE", relative)
    resolved_root = root.resolve()
    resolved = (resolved_root / candidate).resolve()
    require(resolved == resolved_root or resolved_root in resolved.parents, "PATH_ESCAPE", relative)
    require(resolved.is_file(), "FILE_MISSING", relative)
    return resolved


def load_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except OSError as error:
        raise ReviewPackageError("FILE_MISSING", str(path)) from error
    except json.JSONDecodeError as error:
        raise ReviewPackageError("JSON_INVALID", str(path)) from error
    require(isinstance(value, dict), "SCHEMA", "root must be an object")
    return value


def build_index(root: Path = ROOT) -> dict[str, Any]:
    documents = [
        {"topic": topic, "path": path, "sha256": sha256_path(safe_path(root, path))}
        for topic, path in DOCUMENTS
    ]
    evidence = [
        {
            "topic": topic,
            "sourceTask": task,
            "path": path,
            "sha256": sha256_path(safe_path(root, path)),
            "state": state,
            "gating": gating,
        }
        for topic, task, path, state, gating in EVIDENCE
    ]
    return {
        "schemaVersion": SCHEMA_VERSION,
        "taskId": TASK_ID,
        "platform": PROFILE,
        "compatibilityPolicy": COMPATIBILITY_POLICY,
        "documents": documents,
        "evidence": evidence,
    }


def exact_keys(value: Mapping[str, Any], expected: set[str], where: str) -> None:
    actual = set(value)
    require(actual == expected, "SCHEMA", f"{where} keys: {sorted(actual ^ expected)}")


def evidence_passes(path: Path) -> bool:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return False
    return any(payload.get(key) == "PASS" for key in ("status", "decision", "acceptance_status"))


def validate_index(root: Path, index: Mapping[str, Any]) -> dict[str, Any]:
    exact_keys(index, {"schemaVersion", "taskId", "platform", "compatibilityPolicy", "documents", "evidence"}, "index")
    require(index["schemaVersion"] == SCHEMA_VERSION, "SCHEMA_VERSION", str(index["schemaVersion"]))
    require(index["taskId"] == TASK_ID, "TASK_ID", str(index["taskId"]))
    require(index["platform"] == PROFILE, "PLATFORM", str(index["platform"]))
    require(index["compatibilityPolicy"] == COMPATIBILITY_POLICY, "COMPATIBILITY_GATE", str(index["compatibilityPolicy"]))
    require(isinstance(index["documents"], list), "SCHEMA", "documents must be a list")
    require(isinstance(index["evidence"], list), "SCHEMA", "evidence must be a list")

    topics: set[str] = set()
    scanned_files: set[Path] = set()
    for position, item in enumerate(index["documents"]):
        require(isinstance(item, dict), "SCHEMA", f"documents[{position}]")
        exact_keys(item, {"topic", "path", "sha256"}, f"documents[{position}]")
        path = safe_path(root, item["path"])
        require(sha256_path(path) == item["sha256"], "DIGEST_MISMATCH", item["path"])
        topics.add(item["topic"])
        scanned_files.add(path)

    state_counts: dict[str, int] = {}
    for position, item in enumerate(index["evidence"]):
        require(isinstance(item, dict), "SCHEMA", f"evidence[{position}]")
        exact_keys(item, {"topic", "sourceTask", "path", "sha256", "state", "gating"}, f"evidence[{position}]")
        path = safe_path(root, item["path"])
        require(sha256_path(path) == item["sha256"], "DIGEST_MISMATCH", item["path"])
        scanned_files.add(path)
        state = item["state"]
        require(state in {"CURRENT_PASS", "CURRENT_BOUND_INPUT", "STALE_AFTER_M7_032", "HISTORICAL_NON_GATING"}, "EVIDENCE_STATE", str(state))
        require(isinstance(item["gating"], bool), "SCHEMA", f"evidence[{position}].gating")
        if state == "CURRENT_PASS":
            require(item["gating"], "FALSE_PASS", item["path"])
            require(evidence_passes(path), "SKIPPED_AS_PASS", item["path"])
        else:
            require(not item["gating"], "FALSE_PASS", item["path"])
        if item["sourceTask"] == "M7-026":
            require(state == "HISTORICAL_NON_GATING" and not item["gating"], "COMPATIBILITY_GATE", item["path"])
        topics.add(item["topic"])
        state_counts[state] = state_counts.get(state, 0) + 1

    supply_chain = next(
        (item for item in index["evidence"] if item["topic"] == "supply-chain-validation"),
        None,
    )
    require(supply_chain is not None, "TOPIC_MISSING", "supply-chain-validation")
    require(
        supply_chain["state"] == "CURRENT_PASS" and supply_chain["gating"],
        "BOUND_INPUT_ATTESTATION",
        supply_chain["path"],
    )
    bundle = load_json(safe_path(root, supply_chain["path"]))
    documents = bundle.get("documents")
    require(isinstance(documents, dict), "BOUND_INPUT_ATTESTATION", supply_chain["path"])
    for item in index["evidence"]:
        if item["state"] != "CURRENT_BOUND_INPUT":
            continue
        document = documents.get(Path(item["path"]).name)
        require(
            isinstance(document, dict) and document.get("sha256") == item["sha256"],
            "BOUND_INPUT_MISMATCH",
            item["path"],
        )

    missing_topics = sorted(REQUIRED_TOPICS - topics)
    require(not missing_topics, "TOPIC_MISSING", ",".join(missing_topics))
    for path in sorted(scanned_files):
        text = path.read_text(encoding="utf-8")
        for category, pattern in SECRET_PATTERNS:
            require(pattern.search(text) is None, "SENSITIVE_DATA", f"{path.relative_to(root)}:{category}")
    return {
        "documentCount": len(index["documents"]),
        "evidenceCount": len(index["evidence"]),
        "stateCounts": state_counts,
    }


def build_report(index_path: Path, summary: Mapping[str, Any]) -> dict[str, Any]:
    return {
        "schemaVersion": SCHEMA_VERSION,
        "taskId": TASK_ID,
        "source_task": TASK_ID,
        "platform": PROFILE,
        "status": "PASS",
        "decision": "PASS",
        "acceptance_status": "PASS",
        "compatibilityPolicy": COMPATIBILITY_POLICY,
        "indexSha256": sha256_path(index_path),
        **summary,
        "checks": {
            "requiredTopics": "PASS",
            "digests": "PASS",
            "evidenceStates": "PASS",
            "sensitiveData": "PASS",
            "compatibilityGate": "DISABLED_PRE_1_0",
            "skippedAsPass": False,
        },
    }


def atomic_json(path: Path, value: Mapping[str, Any], replace: Callable[[Path, Path], None] | None = None) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    replacer = replace or (lambda source, destination: source.replace(destination))
    try:
        with temporary.open("wb") as stream:
            stream.write(canonical_json(value))
            stream.flush()
            os.fsync(stream.fileno())
        replacer(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()


def validate(
    root: Path = ROOT,
    index_path: Path = DEFAULT_INDEX,
    report_path: Path | None = None,
) -> dict[str, Any]:
    index = load_json(index_path)
    summary = validate_index(root, index)
    require(index == build_index(root), "INDEX_STALE", str(index_path))
    report = build_report(index_path, summary)
    if report_path is not None:
        require(load_json(report_path) == report, "REPORT_STALE", str(report_path))
    return report


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--index", type=Path, default=DEFAULT_INDEX)
    parser.add_argument("--report", type=Path, default=DEFAULT_REPORT)
    parser.add_argument("--write", action="store_true")
    parser.add_argument("--json", action="store_true")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    try:
        if args.write:
            atomic_json(args.index, build_index(args.root))
            atomic_json(args.report, validate(args.root, args.index))
        report = validate(args.root, args.index, args.report)
    except ReviewPackageError as error:
        payload = {"taskId": TASK_ID, "status": "FAIL", "code": error.code, "detail": error.detail[:512]}
        print(json.dumps(payload, sort_keys=True) if args.json else f"M7-028 security review package: FAIL [{error.code}] {error.detail[:512]}")
        return 1
    if args.json:
        print(json.dumps(report, sort_keys=True))
    else:
        print(f"M7-028 security review package: PASS\ndocuments={report['documentCount']}\nevidence={report['evidenceCount']}\nindex_sha256={report['indexSha256']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
