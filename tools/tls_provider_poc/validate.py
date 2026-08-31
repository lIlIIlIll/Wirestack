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
CONTAINER_RE = re.compile(r"^alpine:3\.22@sha256:[0-9a-f]{64}$")
REQUIRED_PROVIDER_IDS = {"aws-lc", "mbedtls", "openssl"}
MAX_EXPORTED_SYMBOLS = 16384
MAX_EXPORTED_SYMBOL_LENGTH = 256
MAX_LICENSE_FILES = 512
MAX_LICENSE_TOTAL_BYTES = 8 * 1024 * 1024
MEMORY_PROFILE_BOUND_BYTES = 512 * 1024 * 1024
ALLOCATION_PROFILE_BOUND_BYTES = 1024 * 1024 * 1024

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

def validate_exported_symbols(build: Mapping[str, Any]) -> None:
    inventory = build.get("exported_symbol_inventory")
    require(isinstance(inventory, dict), "exported-symbol inventory required")
    require(inventory.get("scope") == "final-artifact-exports",
            "exported-symbol inventory scope")
    require(isinstance(inventory.get("tool"), str) and inventory["tool"],
            "exported-symbol inventory tool")
    symbols = inventory.get("symbols")
    require(isinstance(symbols, list), "exported-symbol list required")
    require(len(symbols) <= MAX_EXPORTED_SYMBOLS,
            "exported-symbol inventory exceeds its bound")
    require(all(isinstance(symbol, str) and 0 < len(symbol) <= MAX_EXPORTED_SYMBOL_LENGTH
                for symbol in symbols), "exported-symbol entry invalid")
    require(symbols == sorted(set(symbols)),
            "exported-symbol inventory must be sorted and unique")
    require(inventory.get("count") == len(symbols),
            "exported-symbol count mismatch")
    encoded = "".join(f"{symbol}\n" for symbol in symbols).encode("utf-8")
    require(inventory.get("sha256") == hashlib.sha256(encoded).hexdigest(),
            "exported-symbol digest mismatch")

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
    require(schema_version == 5, "unsupported result schema")
    require(result.get("task_id") == "M0-016", "result task_id")
    require(result.get("provider") in REQUIRED_PROVIDER_IDS, "result provider")
    require(result.get("platform") in set(spec["required_platforms"]), "result platform")
    require(result.get("status") in RESULT_STATUSES, "result status")
    if result.get("status") in {"PASS", "PARTIAL"}:
        execution = result.get("execution")
        require(isinstance(execution, dict), "successful result requires execution metadata")
        require(COMMIT_RE.fullmatch(str(execution.get("repository_revision", ""))) is not None,
                "successful result requires exact repository revision")
        require(isinstance(execution.get("image_os"), str) and execution["image_os"],
                "successful result requires image identity")
        require(isinstance(execution.get("image_version"), str) and execution["image_version"],
                "successful result requires image version")
        if result.get("platform") == "windows-x86_64":
            require(execution.get("runner_os") == "Windows",
                    "Windows result requires native Windows runner")
            require(str(execution.get("runner_arch", "")).upper() in {"X64", "AMD64"},
                    "Windows result requires native x86_64 runner")
        if result.get("platform") == "linux-musl-x86_64":
            require(CONTAINER_RE.fullmatch(str(execution.get("container_image", ""))) is not None,
                    "musl result requires immutable Alpine container identity")
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
    if schema_version == 5:
        metrics = result.get("metrics")
        require(isinstance(metrics, dict), "schema v5 metrics object required")
        require(metrics.get("repeated_cleanup_cycles") == 10000,
                "schema v5 requires exactly 10,000 repeated cleanup cycles")
        if result["provider"] == "aws-lc" and caps.get("external_signer") == "PASS":
            require(isinstance(metrics.get("external_signer_calls"), int) and
                    metrics["external_signer_calls"] >= 2,
                    "AWS-LC external signer must serve TLS 1.2 and TLS 1.3")
        if caps.get("session_resumption") == "PASS":
            require(metrics.get("session_resumption_handshakes") == 4,
                    "schema v5 session resumption requires four measured handshakes")
            require(metrics.get("session_resumption_tls12_handshakes") == 2,
                    "schema v5 requires a TLS 1.2 resumed session")
            require(metrics.get("session_resumption_tls13_handshakes") == 2,
                    "schema v5 requires a TLS 1.3 resumed ticket")
        if caps.get("external_trust") == "PASS":
            require(isinstance(metrics.get("external_trust_calls"), int) and
                    metrics["external_trust_calls"] >= 4,
                    "external trust must accept and reject both TLS versions")
        if caps.get("sni_hostname_alpn") == "PASS":
            require(metrics.get("alpn_no_overlap_handshakes") == 2,
                    "ALPN PASS requires TLS 1.2 and TLS 1.3 no-overlap handshakes")
            require(metrics.get("alpn_malformed_inputs_rejected") == 2,
                    "ALPN PASS requires two rejected malformed inputs")
        if (caps.get("negative_expired_certificate") == "PASS" and
                caps.get("negative_malformed_certificate") == "PASS"):
            require(metrics.get("certificate_negative_cases_rejected") == 2,
                    "certificate negatives require expired and malformed rejection")
        if caps.get("mtls") == "PASS":
            require(metrics.get("mtls_required_handshakes") == 1,
                    "mTLS requires one required-client-auth handshake")
            require(metrics.get("mtls_optional_handshakes") == 2,
                    "mTLS requires optional client auth with and without a certificate")
    if result["status"] in {"PASS", "PARTIAL"}:
        require(build.get("static_archives"), "successful result requires static archives")
        validate_exported_symbols(build)
        require(build.get("system_tls_dependencies") == [], "system TLS dependency detected")
        require(build.get("runtime_loader_library_strings") == [],
                "runtime TLS loader string detected")
        license_bundle = build.get("license_bundle")
        require(isinstance(license_bundle, dict), "provider license bundle required")
        require(license_bundle.get("path") == "license-bundle/manifest.json",
                "provider license bundle path")
        require(SHA256_RE.fullmatch(str(license_bundle.get("sha256", ""))) is not None,
                "provider license bundle digest")
        require(isinstance(license_bundle.get("file_count"), int) and
                0 < license_bundle["file_count"] <= MAX_LICENSE_FILES,
                "provider license bundle file count")
        require(isinstance(license_bundle.get("total_bytes"), int) and
                0 < license_bundle["total_bytes"] <= MAX_LICENSE_TOTAL_BYTES,
                "provider license bundle total bytes")
        operational = result.get("operational_evidence")
        require(isinstance(operational, dict), "operational evidence required")
        memory = operational.get("memory_profile")
        require(isinstance(memory, dict), "bounded memory profile required")
        require(memory.get("peak_resident_bytes") == metrics.get("memory_profile_peak_resident_bytes") and
                isinstance(memory.get("peak_resident_bytes"), int) and
                0 < memory["peak_resident_bytes"] <= MEMORY_PROFILE_BOUND_BYTES,
                "peak resident memory profile")
        require(memory.get("resident_bound_bytes") == MEMORY_PROFILE_BOUND_BYTES,
                "resident memory bound")
        require(memory.get("allocation_calls") == metrics.get("allocation_profile_calls") and
                isinstance(memory.get("allocation_calls"), int) and memory["allocation_calls"] > 0,
                "allocation call profile")
        require(memory.get("allocation_bytes") == metrics.get("allocation_profile_bytes") and
                isinstance(memory.get("allocation_bytes"), int) and
                0 < memory["allocation_bytes"] <= ALLOCATION_PROFILE_BOUND_BYTES,
                "allocation byte profile")
        require(memory.get("allocation_bound_bytes") == ALLOCATION_PROFILE_BOUND_BYTES,
                "allocation byte bound")
        diagnostic = operational.get("native_memory_diagnostic")
        require(isinstance(diagnostic, dict) and
                diagnostic.get("status") in {"PASS", "UNSUPPORTED"},
                "native memory diagnostic status")
        if (result["platform"].startswith("linux-glibc-") or
                result["platform"].startswith("macos-")):
            require(diagnostic.get("status") == "PASS",
                    "supported platform requires passing native memory diagnostic")
            leak_detection = diagnostic.get("leak_detection")
            require(isinstance(leak_detection, dict) and
                    leak_detection.get("status") in {"PASS", "UNSUPPORTED"},
                    "native leak-detection status")
            if (result["platform"].startswith("linux-glibc-") and
                    result["provider"] == "mbedtls"):
                require(leak_detection.get("status") == "PASS",
                        "supported provider requires passing native leak detection")
        require(all(value != "FAIL" for value in caps.values()), "PARTIAL/PASS result contains failed capability")
    if result["status"] == "PASS":
        require(schema_version == 5, "PASS requires schema v5 evidence")
        require(all(value == "PASS" for value in caps.values()), "PASS requires all capabilities PASS")
    if any(value == "BLOCKED" for value in caps.values()):
        require(result["status"] != "PASS", "blocked capability cannot yield PASS")


def validate_license_bundle(result_path: Path, result: Mapping[str, Any]) -> None:
    if result.get("status") not in {"PASS", "PARTIAL"}:
        return
    info = result["build"]["license_bundle"]
    root = result_path.parent.resolve()
    manifest_path = (root / info["path"]).resolve()
    require(root == manifest_path or root in manifest_path.parents,
            "provider license bundle path escapes result directory")
    require(manifest_path.is_file(), "provider license bundle manifest is missing")
    require(sha256_path(manifest_path) == info["sha256"],
            "provider license bundle manifest digest mismatch")
    manifest = load(manifest_path)
    require(manifest.get("schema_version") == 1, "provider license manifest schema")
    require(manifest.get("task_id") == "M0-016", "provider license manifest task")
    require(manifest.get("provider") == result["provider"],
            "provider license manifest provider")
    require(manifest.get("source_content_sha256") == result["source"]["content_sha256"],
            "provider license manifest source digest")
    files = manifest.get("files")
    require(isinstance(files, list) and len(files) == info["file_count"],
            "provider license manifest file count")
    require(manifest.get("total_bytes") == info["total_bytes"],
            "provider license manifest byte count")
    observed_paths = set()
    observed_bytes = 0
    for entry in files:
        require(isinstance(entry, dict), "provider license manifest entry")
        relative = Path(str(entry.get("path", "")))
        require(not relative.is_absolute() and ".." not in relative.parts,
                "provider license file path escapes bundle")
        require(relative.as_posix() not in observed_paths,
                "duplicate provider license file path")
        observed_paths.add(relative.as_posix())
        file_path = (root / "license-bundle/files" / relative).resolve()
        files_root = (root / "license-bundle/files").resolve()
        require(files_root in file_path.parents, "provider license file path escapes bundle")
        require(file_path.is_file(), "provider license file is missing")
        size = file_path.stat().st_size
        require(size == entry.get("bytes"), "provider license file size mismatch")
        require(sha256_path(file_path) == entry.get("sha256"),
                "provider license file digest mismatch")
        observed_bytes += size
    require(observed_bytes == info["total_bytes"],
            "provider license bundle total bytes mismatch")

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
            result = load(args.result)
            validate_result(result, spec, args.expected_revision)
            validate_license_bundle(args.result.resolve(), result)
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
