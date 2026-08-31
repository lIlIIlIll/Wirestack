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
PROVIDER_ALLOCATION_PROFILE_BOUND_BYTES = 64 * 1024 * 1024 * 1024
PROVIDER_ALLOCATION_CALL_BOUND = 100_000_000
CANCELLATION_WAKE_BOUND_US = 250_000
RESULT_SCHEMA_VERSION = 6
MAX_TOOL_VERSION_BYTES = 16 * 1024

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

def validate_tool_identity(value: Any, name: str) -> None:
    require(isinstance(value, dict), f"{name} identity required")
    argv = value.get("argv")
    require(isinstance(argv, list) and argv and
            all(isinstance(item, str) and 0 < len(item) <= 1024 for item in argv),
            f"{name} argv")
    require(isinstance(value.get("exit_code"), int), f"{name} exit code")
    output = value.get("output")
    require(isinstance(output, str) and output and
            len(output.encode("utf-8")) <= MAX_TOOL_VERSION_BYTES,
            f"{name} bounded version output")
    require(value.get("output_sha256") ==
            hashlib.sha256(output.encode("utf-8")).hexdigest(),
            f"{name} version digest")

def validate_build_provenance(provenance: Any, provider: str,
                              result_platform: str,
                              *, diagnostic: bool) -> None:
    require(isinstance(provenance, dict), "provider build provenance required")
    triples = {
        "linux-glibc-x86_64": "x86_64-unknown-linux-gnu",
        "linux-musl-x86_64": "x86_64-unknown-linux-musl",
        "windows-x86_64": "x86_64-pc-windows-msvc",
        "macos-arm64": "arm64-apple-darwin",
    }
    require(provenance.get("target_triple") == triples.get(result_platform),
            "provider build target triple")
    validate_tool_identity(provenance.get("compiler"), "C compiler")
    validate_tool_identity(provenance.get("cxx_compiler"), "C++ compiler")
    validate_tool_identity(provenance.get("build_tool"), "provider build tool")
    if provider in {"aws-lc", "mbedtls"}:
        validate_tool_identity(provenance.get("cmake"), "CMake")
    else:
        require(provenance.get("cmake") is None,
                "non-CMake provider must not invent CMake identity")
    configure = provenance.get("configure_argv")
    builds = provenance.get("build_argv")
    require(isinstance(configure, list) and configure and
            all(isinstance(item, str) and 0 < len(item) <= 2048 for item in configure),
            "provider configure argv")
    require(isinstance(builds, list) and builds and all(
        isinstance(command, list) and command and
        all(isinstance(item, str) and 0 < len(item) <= 2048 for item in command)
        for command in builds), "provider build argv")
    require(all(not item.startswith(("/tmp/", "C:\\Users\\"))
                for command in [configure, *builds] for item in command),
            "provider build argv must use normalized paths")
    environment = provenance.get("environment")
    require(isinstance(environment, dict) and all(
        isinstance(key, str) and isinstance(value, str)
        for key, value in environment.items()), "provider build environment")
    require(provenance.get("patches") == [], "provider patch set must be explicit")
    require(provenance.get("patch_set_sha256") == hashlib.sha256(b"[]\n").hexdigest(),
            "provider patch-set digest")
    expected_instrumentation = "address+undefined-sanitizer" if diagnostic else "none"
    require(provenance.get("instrumentation") == expected_instrumentation,
            "provider build instrumentation")
    require(provenance.get("provider_instrumented") is diagnostic,
            "provider instrumentation marker")
    joined = "\n".join(configure)
    if provider == "aws-lc":
        require(all(flag in joined for flag in (
            "-DBUILD_SHARED_LIBS=OFF", "-DBUILD_TESTING=OFF", "-DDISABLE_GO=ON")),
            "AWS-LC build flags")
    elif provider == "mbedtls":
        require(all(flag in joined for flag in (
            "-DENABLE_TESTING=OFF", "-DENABLE_PROGRAMS=OFF",
            "-DUSE_SHARED_MBEDTLS_LIBRARY=OFF",
            "-DTF_PSA_CRYPTO_USER_CONFIG_FILE=<REPOSITORY>/tools/tls_provider_poc/mbedtls_provider_profile_config.h")),
            "Mbed TLS build flags")
    else:
        require(all(flag in configure for flag in (
            "no-shared", "no-module", "no-tests", "no-zlib", "no-zstd")),
            "OpenSSL build flags")

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
    require(schema_version == RESULT_SCHEMA_VERSION, "unsupported result schema")
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
    if schema_version == RESULT_SCHEMA_VERSION:
        metrics = result.get("metrics")
        require(isinstance(metrics, dict), "schema v6 metrics object required")
        require(metrics.get("repeated_cleanup_cycles") == 10000,
                "schema v6 requires exactly 10,000 repeated cleanup cycles")
        if result["provider"] == "aws-lc" and caps.get("external_signer") == "PASS":
            require(isinstance(metrics.get("external_signer_calls"), int) and
                    metrics["external_signer_calls"] >= 2,
                    "AWS-LC external signer must serve TLS 1.2 and TLS 1.3")
        if caps.get("session_resumption") == "PASS":
            require(metrics.get("session_resumption_handshakes") == 4,
                    "schema v6 session resumption requires four measured handshakes")
            require(metrics.get("session_resumption_tls12_handshakes") == 2,
                    "schema v6 requires a TLS 1.2 resumed session")
            require(metrics.get("session_resumption_tls13_handshakes") == 2,
                    "schema v6 requires a TLS 1.3 resumed ticket")
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
        if caps.get("caller_cancellation") == "PASS":
            require(metrics.get("cancellation_wakeups") == 1,
                    "caller cancellation requires one explicit wakeup")
            require(metrics.get("cancellation_bound_us") == CANCELLATION_WAKE_BOUND_US,
                    "caller cancellation wake bound")
            require(isinstance(metrics.get("cancellation_latency_us"), int) and
                    0 <= metrics["cancellation_latency_us"] <= CANCELLATION_WAKE_BOUND_US,
                    "caller cancellation wake latency")
    if result["status"] in {"PASS", "PARTIAL"}:
        require(build.get("static_archives"), "successful result requires static archives")
        validate_exported_symbols(build)
        require(build.get("system_tls_dependencies") == [], "system TLS dependency detected")
        require(build.get("runtime_loader_library_strings") == [],
                "runtime TLS loader string detected")
        validate_build_provenance(
            build.get("provenance"), result["provider"], result["platform"],
            diagnostic=False)
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
        require(memory.get("method") ==
                "native-process-peak-resident-and-provider-allocation-hooks",
                "provider allocation profile method")
        require(memory.get("provider_allocation_calls") ==
                metrics.get("provider_allocation_calls") and
                isinstance(memory.get("provider_allocation_calls"), int) and
                0 < memory["provider_allocation_calls"] <= PROVIDER_ALLOCATION_CALL_BOUND,
                "provider allocation call profile")
        require(memory.get("provider_allocation_call_bound") ==
                PROVIDER_ALLOCATION_CALL_BOUND,
                "provider allocation call bound")
        require(memory.get("provider_allocation_bytes") ==
                metrics.get("provider_allocation_bytes") and
                isinstance(memory.get("provider_allocation_bytes"), int) and
                0 < memory["provider_allocation_bytes"] <=
                PROVIDER_ALLOCATION_PROFILE_BOUND_BYTES,
                "provider allocation byte profile")
        require(memory.get("provider_allocation_bound_bytes") ==
                PROVIDER_ALLOCATION_PROFILE_BOUND_BYTES,
                "provider allocation byte bound")
        require(memory.get("provider_allocation_peak_live_bytes") ==
                metrics.get("provider_allocation_peak_live_bytes") and
                isinstance(memory.get("provider_allocation_peak_live_bytes"), int) and
                0 < memory["provider_allocation_peak_live_bytes"] <=
                MEMORY_PROFILE_BOUND_BYTES,
                "provider peak live allocation profile")
        cancellation = operational.get("cancellation")
        require(isinstance(cancellation, dict) and
                cancellation.get("method") ==
                "caller-owned-wait-thread-and-explicit-cancel-signal" and
                cancellation.get("wakeups") == metrics.get("cancellation_wakeups") and
                cancellation.get("latency_us") == metrics.get("cancellation_latency_us") and
                cancellation.get("bound_us") == metrics.get("cancellation_bound_us"),
                "caller cancellation operational evidence")
        diagnostic = operational.get("native_memory_diagnostic")
        require(isinstance(diagnostic, dict) and
                diagnostic.get("status") in {"PASS", "UNSUPPORTED"},
                "native memory diagnostic status")
        if (result["platform"].startswith("linux-glibc-") or
                result["platform"].startswith("macos-")):
            require(diagnostic.get("status") == "PASS",
                    "supported platform requires passing native memory diagnostic")
            require(diagnostic.get("provider_instrumented") is True,
                    "native diagnostic must instrument provider archives")
            archives = diagnostic.get("provider_static_archives")
            require(isinstance(archives, list) and archives and all(
                isinstance(archive, dict) and
                isinstance(archive.get("name"), str) and archive["name"] and
                isinstance(archive.get("bytes"), int) and archive["bytes"] > 0 and
                SHA256_RE.fullmatch(str(archive.get("sha256", ""))) is not None
                for archive in archives), "instrumented provider archive inventory")
            validate_build_provenance(
                diagnostic.get("provider_build_provenance"), result["provider"],
                result["platform"], diagnostic=True)
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
        require(schema_version == RESULT_SCHEMA_VERSION,
                "PASS requires schema v6 evidence")
        require(all(value == "PASS" for value in caps.values()), "PASS requires all capabilities PASS")
    if any(value == "BLOCKED" for value in caps.values()):
        require(result["status"] != "PASS", "blocked capability cannot yield PASS")


def validate_license_bundle(result_path: Path, result: Mapping[str, Any],
                            manifest_override: Path | None = None) -> None:
    if result.get("status") not in {"PASS", "PARTIAL"}:
        return
    info = result["build"]["license_bundle"]
    root = result_path.parent.resolve()
    manifest_path = (
        manifest_override.resolve()
        if manifest_override is not None
        else (root / info["path"]).resolve()
    )
    if manifest_override is None:
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
        files_root = (manifest_path.parent / "files").resolve()
        file_path = (files_root / relative).resolve()
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
            if status in {"PASS", "PARTIAL"}:
                bundle = cell.get("license_bundle")
                require(isinstance(bundle, dict),
                        f"{key}: retained license bundle required")
                require(isinstance(bundle.get("manifest"), str) and bundle["manifest"],
                        f"{key}: retained license manifest path required")
                require(SHA256_RE.fullmatch(str(bundle.get("sha256", ""))) is not None,
                        f"{key}: retained license manifest sha256 required")
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
        if cell["status"] in {"PASS", "PARTIAL"}:
            repo_root = repo.resolve()
            manifest_path = (repo_root / cell["license_bundle"]["manifest"]).resolve()
            require(repo_root == manifest_path or repo_root in manifest_path.parents,
                    f"{result_path}: provider license manifest path escapes repository")
            require(manifest_path.is_file(),
                    f"{result_path}: provider license manifest is missing")
            require(sha256_path(manifest_path) == cell["license_bundle"]["sha256"],
                    f"{result_path}: provider license manifest matrix digest mismatch")
            require(result["build"]["license_bundle"]["sha256"] ==
                    cell["license_bundle"]["sha256"],
                    f"{result_path}: provider license manifest result digest mismatch")
            validate_license_bundle(result_path, result, manifest_path)

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
