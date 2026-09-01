#!/usr/bin/env python3
"""Prepare and validate the M7-029 independent security review record."""

from __future__ import annotations

if __package__ in {None, ""}:
    import sys
    from pathlib import Path
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tools import evidence_digest

import argparse
import datetime as dt
import json
import os
import re
import sys
from pathlib import Path
from typing import Any, Callable, Mapping, Sequence


ROOT = Path(__file__).resolve().parents[1]
TASK_ID = "M7-029"
SCHEMA_VERSION = 1
PROFILE = "linux-x86_64-glibc"
COMPATIBILITY_POLICY = "NO_BACKWARD_COMPATIBILITY_PRE_1_0"
PACKAGE_PATH = "docs/security/review/linux-1.0/evidence-index.json"
DEFAULT_REQUEST = ROOT / "docs/evidence/M7-029/review-request.json"
DEFAULT_REVIEW = ROOT / "docs/evidence/M7-029/independent-review.json"
DEFAULT_REPORT = ROOT / "docs/evidence/M7-029/linux_x86_64/review-validation.json"

REQUIRED_SCOPE = frozenset({
    "supply-chain", "certificate-identity", "private-keys", "tls-protocol",
    "lifecycle-cancellation", "dns-proxy-routing", "http1-smuggling",
    "http2-hpack", "resource-bounds", "pool-isolation", "sensitive-data",
    "native-c-abi", "linux-platform", "release-evidence",
})
ALLOWED_METHODS = frozenset({
    "source-review", "negative-testing", "boundary-analysis",
    "lifecycle-concurrency", "native-c-abi", "evidence-audit",
})
REQUIRED_METHODS = frozenset({"source-review", "native-c-abi", "evidence-audit"})
REVIEW_MODES = frozenset({"External", "ProcessIsolatedAgent"})
SEVERITIES = frozenset({"Critical", "High", "Medium", "Low", "Informational"})
STATUSES = frozenset({"Open", "Fixed", "NotApplicable", "RiskAccepted"})
SECRET_PATTERNS = (
    ("private-key", re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----")),
    ("authorization-value", re.compile(r"(?im)^\s*authorization\s*:\s*(?!<redacted>|REDACTED\s*$)\S+")),
    ("cookie-value", re.compile(r"(?im)^\s*(?:cookie|set-cookie)\s*:\s*(?!<redacted>|REDACTED\s*$)\S+")),
    ("captured-request-body", re.compile(r"(?im)^\s*captured[_ -]?request[_ -]?body\s*[:=]\s*\S+")),
)


class IndependentReviewError(RuntimeError):
    def __init__(self, code: str, detail: str):
        super().__init__(detail)
        self.code = code
        self.detail = detail


def require(condition: bool, code: str, detail: str) -> None:
    if not condition:
        raise IndependentReviewError(code, detail)


def canonical_json(value: Any) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def safe_path(root: Path, relative: str, must_exist: bool = True) -> Path:
    candidate = Path(relative)
    require(not candidate.is_absolute(), "PATH_ESCAPE", relative)
    base = root.resolve()
    resolved = (base / candidate).resolve()
    require(resolved == base or base in resolved.parents, "PATH_ESCAPE", relative)
    if must_exist:
        require(resolved.is_file(), "FILE_MISSING", relative)
    return resolved


def exact_keys(value: Mapping[str, Any], expected: set[str], where: str) -> None:
    require(set(value) == expected, "SCHEMA", f"{where} keys: {sorted(set(value) ^ expected)}")


def load_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except OSError as error:
        raise IndependentReviewError("FILE_MISSING", str(path)) from error
    except json.JSONDecodeError as error:
        raise IndependentReviewError("JSON_INVALID", str(path)) from error
    require(isinstance(value, dict), "SCHEMA", "root must be an object")
    return value


def build_request(root: Path = ROOT) -> dict[str, Any]:
    package = safe_path(root, PACKAGE_PATH)
    return {
        "schemaVersion": SCHEMA_VERSION,
        "taskId": TASK_ID,
        "platform": PROFILE,
        "packagePath": PACKAGE_PATH,
        "packageSha256": evidence_digest.text_evidence_sha256(package),
        "compatibilityPolicy": COMPATIBILITY_POLICY,
        "requiredScope": sorted(REQUIRED_SCOPE),
        "requiredMethods": sorted(REQUIRED_METHODS),
        "reportPath": "docs/evidence/M7-029/independent-review.json",
        "status": "AWAITING_INDEPENDENT_REVIEW",
    }


def validate_request(root: Path, request: Mapping[str, Any]) -> None:
    exact_keys(request, {
        "schemaVersion", "taskId", "platform", "packagePath", "packageSha256",
        "compatibilityPolicy", "requiredScope", "requiredMethods", "reportPath", "status",
    }, "request")
    require(request == build_request(root), "REQUEST_STALE", "review request does not match current package")


def nonempty(value: Any, code: str, where: str) -> str:
    require(isinstance(value, str) and bool(value.strip()), code, where)
    return value


def utc_timestamp(value: Any, where: str) -> dt.datetime:
    text = nonempty(value, "REVIEWER_DATE_INVALID", where)
    require(
        re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z", text) is not None,
        "REVIEWER_DATE_INVALID",
        where,
    )
    try:
        parsed = dt.datetime.fromisoformat(text[:-1] + "+00:00")
    except ValueError as error:
        raise IndependentReviewError("REVIEWER_DATE_INVALID", where) from error
    require(parsed.tzinfo == dt.timezone.utc, "REVIEWER_DATE_INVALID", where)
    return parsed


def validate_regression(root: Path, value: Mapping[str, Any], where: str) -> None:
    exact_keys(value, {"command", "status", "exitCode", "timedOut", "evidencePath", "sha256"}, where)
    nonempty(value["command"], "REGRESSION_MISSING", f"{where}.command")
    require(value["status"] == "PASS", "REGRESSION_NOT_PASS", where)
    require(value["exitCode"] == 0 and value["timedOut"] is False, "REGRESSION_NOT_PASS", where)
    path = safe_path(root, value["evidencePath"])
    require(
        evidence_digest.schema_text_sha256_equal(
            evidence_digest.text_evidence_sha256(path), value["sha256"],
        ),
        "DIGEST_MISMATCH", value["evidencePath"],
    )


def validate_finding(root: Path, value: Mapping[str, Any], position: int) -> tuple[str, str]:
    where = f"findings[{position}]"
    exact_keys(value, {
        "id", "title", "severity", "status", "location", "reproduction",
        "impact", "evidence", "fix", "regressions", "dispositionRationale",
    }, where)
    finding_id = nonempty(value["id"], "FINDING_INVALID", f"{where}.id")
    for key in ("title", "location", "reproduction", "impact", "evidence"):
        nonempty(value[key], "FINDING_INVALID", f"{where}.{key}")
    severity = nonempty(value["severity"], "SEVERITY_INVALID", f"{where}.severity")
    status = nonempty(value["status"], "STATUS_INVALID", f"{where}.status")
    require(severity in SEVERITIES, "SEVERITY_INVALID", f"{where}.severity")
    require(status in STATUSES, "STATUS_INVALID", f"{where}.status")
    require(isinstance(value["regressions"], list), "SCHEMA", f"{where}.regressions")
    if status == "Fixed":
        nonempty(value["fix"], "FIX_EVIDENCE_MISSING", f"{where}.fix")
        require(bool(value["regressions"]), "REGRESSION_MISSING", where)
        for index, regression in enumerate(value["regressions"]):
            require(isinstance(regression, dict), "SCHEMA", f"{where}.regressions[{index}]")
            validate_regression(root, regression, f"{where}.regressions[{index}]")
    else:
        require(value["fix"] is None, "SCHEMA", f"{where}.fix must be null")
        require(not value["regressions"], "SCHEMA", f"{where}.regressions must be empty")
    if status in {"NotApplicable", "RiskAccepted"}:
        nonempty(value["dispositionRationale"], "RATIONALE_MISSING", where)
    if severity in {"Critical", "High"}:
        require(status in {"Fixed", "NotApplicable"}, "RELEASE_BLOCKER", finding_id)
    return finding_id, status


def validate_review(root: Path, request: Mapping[str, Any], review: Mapping[str, Any]) -> dict[str, Any]:
    exact_keys(review, {
        "schemaVersion", "taskId", "target", "reviewer", "scope", "methods",
        "compatibilityPolicy", "findings", "conclusion",
    }, "review")
    require(review["schemaVersion"] == SCHEMA_VERSION, "SCHEMA_VERSION", str(review["schemaVersion"]))
    require(review["taskId"] == TASK_ID, "TASK_ID", str(review["taskId"]))
    require(review["compatibilityPolicy"] == COMPATIBILITY_POLICY, "COMPATIBILITY_GATE", str(review["compatibilityPolicy"]))
    require(review["conclusion"] == "PASS", "REVIEW_NOT_PASS", str(review["conclusion"]))

    target = review["target"]
    require(isinstance(target, dict), "SCHEMA", "target")
    exact_keys(target, {"packagePath", "packageSha256"}, "target")
    require(target["packagePath"] == request["packagePath"] and
        target["packageSha256"] == request["packageSha256"], "TARGET_MISMATCH", "M7-028 package")

    reviewer = review["reviewer"]
    require(isinstance(reviewer, dict), "SCHEMA", "reviewer")
    exact_keys(reviewer, {
        "identity", "affiliation", "reviewMode", "independent", "independenceStatement",
        "conflicts", "startedAtUtc", "completedAtUtc",
    }, "reviewer")
    nonempty(reviewer["identity"], "REVIEWER_MISSING", "reviewer.identity")
    nonempty(reviewer["affiliation"], "REVIEWER_MISSING", "reviewer.affiliation")
    require(reviewer["independent"] is True, "REVIEWER_NOT_INDEPENDENT", "reviewer.independent")
    require(reviewer["reviewMode"] in REVIEW_MODES, "REVIEW_MODE_INVALID", "reviewer.reviewMode")
    nonempty(reviewer["independenceStatement"], "REVIEWER_NOT_INDEPENDENT", "reviewer.independenceStatement")
    require(isinstance(reviewer["conflicts"], list), "SCHEMA", "reviewer.conflicts")
    conflicts = [nonempty(item, "SCHEMA", "reviewer.conflicts") for item in reviewer["conflicts"]]
    require(len(conflicts) == len(set(conflicts)), "SCHEMA", "reviewer.conflicts duplicates")
    if reviewer["reviewMode"] == "ProcessIsolatedAgent":
        require(bool(conflicts), "REVIEWER_NOT_INDEPENDENT", "process-isolated agent conflicts")
    started = utc_timestamp(reviewer["startedAtUtc"], "reviewer.startedAtUtc")
    completed = utc_timestamp(reviewer["completedAtUtc"], "reviewer.completedAtUtc")
    require(completed >= started, "REVIEWER_DATE_INVALID", "reviewer.completedAtUtc before startedAtUtc")

    require(isinstance(review["scope"], list), "SCHEMA", "scope")
    require(all(isinstance(item, str) for item in review["scope"]), "SCHEMA", "scope entries")
    scope = set(review["scope"])
    require(len(scope) == len(review["scope"]), "SCHEMA", "scope duplicates")
    require(scope == REQUIRED_SCOPE, "SCOPE_INCOMPLETE", ",".join(sorted(REQUIRED_SCOPE - scope)))
    require(isinstance(review["methods"], list), "SCHEMA", "methods")
    require(all(isinstance(item, str) for item in review["methods"]), "SCHEMA", "method entries")
    methods = set(review["methods"])
    require(len(methods) == len(review["methods"]), "SCHEMA", "method duplicates")
    require(methods <= ALLOWED_METHODS, "METHOD_INVALID", ",".join(sorted(methods - ALLOWED_METHODS)))
    require(REQUIRED_METHODS <= methods, "METHOD_INCOMPLETE", ",".join(sorted(REQUIRED_METHODS - methods)))
    require(isinstance(review["findings"], list), "SCHEMA", "findings")
    seen: set[str] = set()
    statuses: dict[str, int] = {}
    for index, finding in enumerate(review["findings"]):
        require(isinstance(finding, dict), "SCHEMA", f"findings[{index}]")
        finding_id, status = validate_finding(root, finding, index)
        require(finding_id not in seen, "FINDING_DUPLICATE", finding_id)
        seen.add(finding_id)
        statuses[status] = statuses.get(status, 0) + 1

    for text in string_values(review):
        for category, pattern in SECRET_PATTERNS:
            require(pattern.search(text) is None, "SENSITIVE_DATA", category)
    return {"findingCount": len(review["findings"]), "findingStatuses": statuses}


def string_values(value: Any):
    if isinstance(value, str):
        yield value
    elif isinstance(value, list):
        for item in value:
            yield from string_values(item)
    elif isinstance(value, dict):
        for item in value.values():
            yield from string_values(item)


def build_report(request: Mapping[str, Any], summary: Mapping[str, Any]) -> dict[str, Any]:
    return {
        "schemaVersion": SCHEMA_VERSION,
        "taskId": TASK_ID,
        "source_task": TASK_ID,
        "platform": PROFILE,
        "status": "PASS",
        "decision": "PASS",
        "acceptance_status": "PASS",
        "packageSha256": request["packageSha256"],
        "compatibilityPolicy": COMPATIBILITY_POLICY,
        **summary,
        "checks": {
            "independentReviewerAttestation": "PASS",
            "requiredScope": "PASS",
            "requiredMethods": "PASS",
            "unresolvedHighCritical": 0,
            "compatibilityGate": "DISABLED_PRE_1_0",
            "skippedAsPass": False,
        },
        "nonClaims": [
            "Schema validation records the reviewer's declared review mode and independence attestation; it cannot prove those facts by itself."
        ],
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


def validate(root: Path, request_path: Path, review_path: Path) -> dict[str, Any]:
    request = load_json(request_path)
    validate_request(root, request)
    if not review_path.is_file():
        raise IndependentReviewError("REVIEW_REQUIRED", str(review_path))
    review = load_json(review_path)
    return build_report(request, validate_review(root, request, review))


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--request", type=Path, default=DEFAULT_REQUEST)
    parser.add_argument("--review", type=Path, default=DEFAULT_REVIEW)
    parser.add_argument("--report", type=Path, default=DEFAULT_REPORT)
    parser.add_argument("--prepare", action="store_true")
    parser.add_argument("--json", action="store_true")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    try:
        if args.prepare:
            atomic_json(args.request, build_request(args.root))
        report = validate(args.root, args.request, args.review)
        atomic_json(args.report, report)
    except (IndependentReviewError, evidence_digest.DigestError) as error:
        status = "BLOCKED" if error.code == "REVIEW_REQUIRED" else "FAIL"
        payload = {"taskId": TASK_ID, "status": status, "code": error.code, "detail": error.detail[:512]}
        print(json.dumps(payload, sort_keys=True) if args.json else f"M7-029 independent review: {status} [{error.code}] {error.detail[:512]}")
        return 3 if status == "BLOCKED" else 1
    print(json.dumps(report, sort_keys=True) if args.json else f"M7-029 independent review: PASS\nfindings={report['findingCount']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
