#!/usr/bin/env python3
"""Fail-closed validator for M0-016 provider specifications and evidence."""
from __future__ import annotations
import argparse, hashlib, json, re, sys
from pathlib import Path
from typing import Any, Mapping, Sequence

CAPABILITY_STATUSES = {"PASS", "FAIL", "BLOCKED", "NOT_RUN"}
MATRIX_STATUSES = {"PASS", "PARTIAL", "FAIL", "BLOCKED", "NOT_RUN"}
RESULT_STATUSES = {"PASS", "PARTIAL", "FAIL", "BLOCKED"}
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
REQUIRED_PROVIDER_IDS = {"aws-lc", "mbedtls", "openssl"}

class ValidationError(RuntimeError):
    pass

def require(value: bool, message: str) -> None:
    if not value:
        raise ValidationError(message)

def load(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ValidationError(str(error)) from error
    require(isinstance(value, dict), f"{path}: root must be an object")
    return value

def sha256_path(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

def validate_spec(spec: Mapping[str, Any]) -> None:
    require(spec.get("schema_version") == 1, "unsupported provider spec schema")
    require(spec.get("task_id") == "M0-016", "provider spec task_id must be M0-016")
    providers = spec.get("providers")
    require(isinstance(providers, list) and len(providers) == 3, "exactly three providers required")
    ids = set()
    for provider in providers:
        require(isinstance(provider, dict), "provider must be an object")
        pid = provider.get("id")
        require(isinstance(pid, str), "provider id missing")
        require(pid not in ids, f"duplicate provider: {pid}")
        ids.add(pid)
        require(provider.get("source_kind") in {"git", "archive"}, f"{pid}: source_kind")
        require(isinstance(provider.get("url"), str) and provider["url"].startswith("https://"), f"{pid}: https URL required")
        require(isinstance(provider.get("license_expression"), str) and provider["license_expression"], f"{pid}: license missing")
        require(COMMIT_RE.fullmatch(str(provider.get("commit", ""))) is not None,
                f"{pid}: exact commit required")
        if provider["source_kind"] == "archive":
            require(SHA256_RE.fullmatch(str(provider.get("sha256", ""))) is not None,
                    f"{pid}: archive sha256 required")
    require(ids == REQUIRED_PROVIDER_IDS, f"provider set mismatch: {ids}")
    caps = spec.get("required_capabilities")
    platforms = spec.get("required_platforms")
    require(isinstance(caps, list) and len(caps) >= 14 and len(caps) == len(set(caps)), "required capabilities invalid")
    require(isinstance(platforms, list) and len(platforms) >= 7 and len(platforms) == len(set(platforms)), "required platforms invalid")

def validate_result(result: Mapping[str, Any], spec: Mapping[str, Any],
                    expected_revision: str | None = None) -> None:
    validate_spec(spec)
    schema_version = result.get("schema_version")
    require(schema_version in {1, 2, 3}, "unsupported result schema")
    require(result.get("task_id") == "M0-016", "result task_id")
    require(result.get("provider") in REQUIRED_PROVIDER_IDS, "result provider")
    require(result.get("platform") in set(spec["required_platforms"]), "result platform")
    require(result.get("status") in RESULT_STATUSES, "result status")
    if result.get("platform") == "windows-x86_64" and result.get("status") in {"PASS", "PARTIAL"}:
        execution = result.get("execution")
        require(isinstance(execution, dict), "Windows result requires execution metadata")
        require(execution.get("runner_os") == "Windows", "Windows result requires native Windows runner")
        require(str(execution.get("runner_arch", "")).upper() in {"X64", "AMD64"},
                "Windows result requires native x86_64 runner")
        require(COMMIT_RE.fullmatch(str(execution.get("repository_revision", ""))) is not None,
                "Windows result requires exact repository revision")
        require(isinstance(execution.get("image_os"), str) and execution["image_os"],
                "Windows result requires hosted image identity")
        require(isinstance(execution.get("image_version"), str) and execution["image_version"],
                "Windows result requires hosted image version")
    if expected_revision is not None:
        require(COMMIT_RE.fullmatch(expected_revision) is not None, "expected revision must be an exact commit")
        execution = result.get("execution")
        require(isinstance(execution, dict) and
                execution.get("repository_revision") == expected_revision,
                "result repository revision mismatch")
    source = result.get("source")
    require(isinstance(source, dict), "source object required")
    require(SHA256_RE.fullmatch(str(source.get("content_sha256", ""))) is not None, "source content digest required")
    require(COMMIT_RE.fullmatch(str(source.get("commit", ""))) is not None, "resolved upstream commit required")
    caps = result.get("capabilities")
    require(isinstance(caps, dict), "capabilities object required")
    required = set(spec["required_capabilities"])
    require(set(caps) == required, f"capability set mismatch: missing={sorted(required-set(caps))}, extra={sorted(set(caps)-required)}")
    for name, status in caps.items():
        require(status in CAPABILITY_STATUSES, f"{name}: invalid status")
    build = result.get("build")
    require(isinstance(build, dict), "build object required")
    if schema_version in {2, 3}:
        metrics = result.get("metrics")
        require(isinstance(metrics, dict), "schema v2 metrics object required")
        require(metrics.get("repeated_cleanup_cycles") == 10000,
                "schema v2 requires exactly 10,000 repeated cleanup cycles")
        if result["provider"] == "aws-lc" and caps.get("external_signer") == "PASS":
            require(isinstance(metrics.get("external_signer_calls"), int) and
                    metrics["external_signer_calls"] >= 2,
                    "AWS-LC external signer must serve TLS 1.2 and TLS 1.3")
        if schema_version == 3 and caps.get("session_resumption") == "PASS":
            require(metrics.get("session_resumption_handshakes") == 4,
                    "schema v3 session resumption requires four measured handshakes")
            require(metrics.get("session_resumption_tls12_handshakes") == 2,
                    "schema v3 requires a TLS 1.2 resumed session")
            require(metrics.get("session_resumption_tls13_handshakes") == 2,
                    "schema v3 requires a TLS 1.3 resumed ticket")
        if caps.get("external_trust") == "PASS":
            require(isinstance(metrics.get("external_trust_calls"), int) and
                    metrics["external_trust_calls"] >= 4,
                    "external trust must accept and reject both TLS versions")
    if result["status"] in {"PASS", "PARTIAL"}:
        require(build.get("static_archives"), "successful result requires static archives")
        require(build.get("system_tls_dependencies") == [], "system TLS dependency detected")
        require(build.get("runtime_loader_library_strings") == [],
                "runtime TLS loader string detected")
        require(all(value != "FAIL" for value in caps.values()), "PARTIAL/PASS result contains failed capability")
    if result["status"] == "PASS":
        require(schema_version == 3, "PASS requires schema v3 dual-version session evidence")
        require(all(value == "PASS" for value in caps.values()), "PASS requires all capabilities PASS")
    if any(value == "BLOCKED" for value in caps.values()):
        require(result["status"] != "PASS", "blocked capability cannot yield PASS")

def validate_matrix(matrix: Mapping[str, Any], spec: Mapping[str, Any]) -> None:
    validate_spec(spec)
    require(matrix.get("schema_version") == 1, "matrix schema")
    cells = matrix.get("cells")
    require(isinstance(cells, list), "matrix cells")
    expected = {(p["id"], platform) for p in spec["providers"] for platform in spec["required_platforms"]}
    observed = set()
    for cell in cells:
        require(isinstance(cell, dict), "matrix cell object")
        key = (cell.get("provider"), cell.get("platform"))
        require(key not in observed, f"duplicate cell {key}")
        observed.add(key)
        status = cell.get("status")
        require(status in MATRIX_STATUSES, f"{key}: invalid status")
        require(isinstance(cell.get("reason"), str) and cell["reason"], f"{key}: reason required")
        if status in {"PASS", "PARTIAL", "FAIL"}:
            require(isinstance(cell.get("result"), str) and cell["result"],
                    f"{key}: retained result path required")
            require(SHA256_RE.fullmatch(str(cell.get("sha256", ""))) is not None,
                    f"{key}: retained result sha256 required")
    require(observed == expected, f"matrix coverage mismatch: missing={sorted(expected-observed)}, extra={sorted(observed-expected)}")

def validate_retained_results(matrix: Mapping[str, Any], spec: Mapping[str, Any], repo: Path) -> None:
    for cell in matrix["cells"]:
        if cell["status"] not in {"PASS", "PARTIAL", "FAIL"}:
            continue
        result_path = repo / cell["result"]
        result = load(result_path)
        validate_result(result, spec)
        require(result["provider"] == cell["provider"], f"{result_path}: provider mismatch")
        require(result["platform"] == cell["platform"], f"{result_path}: platform mismatch")
        require(result["status"] == cell["status"], f"{result_path}: status mismatch")
        require(sha256_path(result_path) == cell["sha256"], f"{result_path}: sha256 mismatch")

def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--spec", type=Path, default=Path(__file__).resolve().parent / "providers.json")
    parser.add_argument("--result", type=Path)
    parser.add_argument("--matrix", type=Path)
    parser.add_argument("--expected-revision")
    args = parser.parse_args(argv)
    try:
        spec = load(args.spec)
        validate_spec(spec)
        if args.result:
            validate_result(load(args.result), spec, args.expected_revision)
        elif args.expected_revision:
            raise ValidationError("--expected-revision requires --result")
        if args.matrix:
            matrix = load(args.matrix)
            validate_matrix(matrix, spec)
            validate_retained_results(matrix, spec, Path(__file__).resolve().parents[2])
    except ValidationError as error:
        print(f"M0-016 validation: FAIL: {error}", file=sys.stderr)
        return 1
    print("M0-016 validation: PASS")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
