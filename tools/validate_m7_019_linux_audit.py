#!/usr/bin/env python3
"""Validate the fail-closed M7-019 Linux requirement audit."""

from __future__ import annotations

from tools import evidence_digest

import argparse
import json
import re
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_AUDIT = ROOT / "docs/evidence/M7-019/linux_x86_64/audit.data"

P0_IDS = [
    "TR-BUF-001",
    *[f"TR-CTX-{index:03d}" for index in range(1, 6)],
    *[f"TR-STREAM-{index:03d}" for index in range(1, 8)],
    "TR-LISTEN-001",
    *[f"DNS-{index:03d}" for index in range(1, 5)],
    *[f"CONN-{index:03d}" for index in range(1, 6)],
    *[f"TLS-PROV-{index:03d}" for index in range(1, 5)],
    "PLATFORM-LINUX-HTTPS-CLIENT",
    "PLATFORM-LINUX-TLS-HTTP-SERVER",
    "HTTP-PROXY-P0",
    "HTTP1-P0",
    "HTTP2-P0",
]
INVARIANT_IDS = [f"INV-{index:02d}" for index in range(1, 16)]
RELEASE_IDS = [f"REL-{index:02d}" for index in range(1, 23)]
ALLOWED_STATUSES = {"PASS", "GAP", "NOT_APPLICABLE_TO_LINUX_PROFILE"}
DIGEST_RE = re.compile(r"[0-9a-f]{64}")

EXPECTED_GAPS = {
    "TLS-PROV-004": "M7-025",
    "REL-04": "M7-021",
    "REL-13": "M7-024",
    "REL-14": "M7-023",
    "REL-15": "M7-029",
    "REL-16": "M7-025",
    "REL-19": "M7-022",
}
EXPECTED_NOT_APPLICABLE = {"REL-03"}


class AuditError(ValueError):
    """Raised when the audit is incomplete or internally inconsistent."""


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise AuditError(message)


def _validate_items(
    section: str, items: Any, expected_ids: list[str], repo_root: Path,
    *, verify_current_sources: bool,
) -> list[dict[str, Any]]:
    _require(isinstance(items, list), f"{section} must be a list")
    ids = [item.get("id") for item in items if isinstance(item, dict)]
    _require(len(ids) == len(items), f"{section} contains a non-object item")
    _require(ids == expected_ids, f"{section} IDs or order differ from the PRD inventory")

    for item in items:
        item_id = item["id"]
        status = item.get("status")
        _require(status in ALLOWED_STATUSES, f"{item_id}: invalid status {status!r}")
        _require(bool(item.get("source")), f"{item_id}: missing PRD source")
        _require(bool(item.get("requirement")), f"{item_id}: missing requirement text")
        _require(bool(item.get("note")), f"{item_id}: missing audit note")
        evidence = item.get("evidence")
        _require(isinstance(evidence, list) and evidence, f"{item_id}: missing evidence")
        for relative in evidence:
            _require(isinstance(relative, str) and relative, f"{item_id}: evidence path is not text")
            candidate = Path(relative)
            _require(
                not candidate.is_absolute() and ".." not in candidate.parts
                and candidate.as_posix() == relative,
                f"{item_id}: invalid evidence path {relative}",
            )
            if verify_current_sources:
                _require(
                    (repo_root / relative).exists(),
                    f"{item_id}: missing evidence path {relative}",
                )

        expected_owner = EXPECTED_GAPS.get(item_id)
        if expected_owner is not None:
            _require(status == "GAP", f"{item_id}: required release gap was weakened")
            _require(
                item.get("blocking_task") == expected_owner,
                f"{item_id}: expected blocker owner {expected_owner}",
            )
        else:
            _require("blocking_task" not in item, f"{item_id}: unexpected blocking task")

        if item_id in EXPECTED_NOT_APPLICABLE:
            _require(
                status == "NOT_APPLICABLE_TO_LINUX_PROFILE",
                f"{item_id}: non-Linux criterion must not be reported as PASS",
            )
        elif expected_owner is None:
            _require(status == "PASS", f"{item_id}: unexpected non-PASS status")
    return items


def validate_audit(
    path: Path = DEFAULT_AUDIT,
    repo_root: Path = ROOT,
    *,
    verify_current_sources: bool = True,
) -> dict[str, Any]:
    try:
        audit = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise AuditError(f"cannot load audit: {error}") from error

    _require(audit.get("schema_version") == 1, "schema_version must be 1")
    _require(audit.get("task_id") == "M7-019", "task_id must be M7-019")
    _require(audit.get("platform") == "linux-x86_64-glibc", "unexpected platform")
    _require(
        audit.get("decision") == "AUDIT_COMPLETE_RELEASE_BLOCKED",
        "audit must remain release-blocking while evidence gaps exist",
    )

    source_hashes = audit.get("source_sha256")
    _require(isinstance(source_hashes, dict), "source_sha256 must be an object")
    for relative in ("docs/product/prd.md", "docs/planning/implementation-backlog.md"):
        digest = source_hashes.get(relative)
        _require(
            isinstance(digest, str) and DIGEST_RE.fullmatch(digest) is not None,
            f"source hash is invalid for {relative}",
        )
        if verify_current_sources:
            _require(
                digest == evidence_digest.text_evidence_sha256(repo_root / relative),
                f"source hash is stale for {relative}",
            )

    p0 = _validate_items(
        "p0_requirements", audit.get("p0_requirements"), P0_IDS, repo_root,
        verify_current_sources=verify_current_sources,
    )
    invariants = _validate_items(
        "lifecycle_invariants", audit.get("lifecycle_invariants"), INVARIANT_IDS,
        repo_root, verify_current_sources=verify_current_sources,
    )
    release = _validate_items(
        "release_acceptance", audit.get("release_acceptance"), RELEASE_IDS,
        repo_root, verify_current_sources=verify_current_sources,
    )
    all_items = p0 + invariants + release

    blockers = audit.get("blockers")
    _require(isinstance(blockers, list), "blockers must be a list")
    expected_blockers = [
        {"requirement_id": item["id"], "task_id": item["blocking_task"]}
        for item in all_items
        if item["status"] == "GAP"
    ]
    _require(blockers == expected_blockers, "blocker list does not exactly match GAP items")

    expected_summary = {}
    for name, items in (
        ("p0_requirements", p0),
        ("lifecycle_invariants", invariants),
        ("release_acceptance", release),
    ):
        expected_summary[name] = {
            "total": len(items),
            "pass": sum(item["status"] == "PASS" for item in items),
            "gap": sum(item["status"] == "GAP" for item in items),
            "not_applicable": sum(
                item["status"] == "NOT_APPLICABLE_TO_LINUX_PROFILE" for item in items
            ),
        }
    _require(audit.get("summary") == expected_summary, "summary does not match audit items")

    non_claims = audit.get("non_claims")
    _require(isinstance(non_claims, list), "non_claims must be a list")
    required_fragments = ("global M7", "runtime/std", "musl")
    for fragment in required_fragments:
        _require(
            any(fragment in claim for claim in non_claims),
            f"non_claims must explicitly cover {fragment}",
        )
    return audit


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("audit", nargs="?", type=Path, default=DEFAULT_AUDIT)
    args = parser.parse_args()
    try:
        audit = validate_audit(args.audit)
    except AuditError as error:
        print(f"M7-019 audit: FAIL: {error}")
        return 1
    summary = audit["summary"]
    print(
        "M7-019 audit: PASS "
        f"(P0 {summary['p0_requirements']}, "
        f"invariants {summary['lifecycle_invariants']}, "
        f"release {summary['release_acceptance']})"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
