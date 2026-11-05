from __future__ import annotations

import copy
import datetime as dt
import json
import shutil
import tempfile
import unittest
from contextlib import ExitStack, contextmanager
from pathlib import Path
from unittest import mock

from tools import evidence_digest
from tools import m3_031_desktop_tls_adoption as adoption


ROOT = Path(__file__).resolve().parents[2]


def tool_identity(name: str) -> dict:
    output = f"{name} 1.0"
    return {
        "argv": [name, "--version"],
        "exit_code": 0,
        "output": output,
        "output_sha256": evidence_digest.text_evidence_bytes_sha256(output.encode()),
    }


def build_provenance(platform: str, *, diagnostic: bool = False) -> dict:
    return {
        "target_triple": {
            "windows-x86_64": "x86_64-pc-windows-msvc",
            "macos-arm64": "arm64-apple-darwin",
        }[platform],
        "compiler": tool_identity("cc"),
        "cxx_compiler": tool_identity("c++"),
        "cmake": tool_identity("cmake"),
        "build_tool": tool_identity("build-tool"),
        "assembler": (
            tool_identity("nasm")
            if platform == "windows-x86_64" and not diagnostic else None
        ),
        "configure_argv": [
            "cmake", "-DBUILD_SHARED_LIBS=OFF", "-DBUILD_TESTING=OFF",
            "-DDISABLE_GO=ON", "<SOURCE>", "<BUILD>", "<PREFIX>",
        ],
        "build_argv": [
            ["build-tool", "<BUILD>"],
            ["build-tool", "<PREFIX>"],
        ],
        "environment": {
            key: ("/usr/bin:/bin" if key == "PATH" else "")
            for key in adoption.poc_validate.BUILD_ENVIRONMENT_KEYS
        },
        "patches": [],
        "patch_set_sha256": evidence_digest.text_evidence_bytes_sha256(b"[]\n"),
        "instrumentation": (
            "address+undefined-sanitizer" if diagnostic else "none"
        ),
        "provider_instrumented": diagnostic,
    }


FIXED_NOW = dt.datetime(2030, 1, 15, 12, 0, tzinfo=dt.timezone.utc)


class FrozenDateTime(dt.datetime):
    @classmethod
    def now(cls, tz=None):
        if tz is None:
            return cls(2030, 1, 15, 12, 0)
        return FIXED_NOW.astimezone(tz)


def fixture_spec(now: dt.datetime) -> dict:
    spec = json.loads(
        (ROOT / "tools/tls_provider_poc/providers.json").read_text(encoding="utf-8")
    )
    source_time = (now - dt.timedelta(days=30)).isoformat().replace("+00:00", "Z")
    review_time = (now - dt.timedelta(days=1)).isoformat().replace("+00:00", "Z")
    for provider in spec["providers"]:
        provider["security_update"] = {
            "maximum_source_pin_age_days": 90,
            "source_committed_at": source_time,
            "advisory_urls": [f"https://example.test/advisories/{provider['id']}"],
            "advisory_disposition": {
                "status": "not-affected",
                "pin_commit": provider["commit"],
                "reviewed_through": review_time,
                "reviewed_advisory_ids": [f"SYNTHETIC-{provider['id'].upper()}-001"],
                "affected_advisory_ids": [],
            },
            "update_workflow": "docs/security/provider-update-workflow.md",
        }
    return spec


def write_provider_fixture(root: Path, spec: dict) -> None:
    manifest_path = root / "native/tls/aws_lc/provider.json"
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(ROOT / "native/tls/aws_lc/provider.json", manifest_path)
    spec_path = root / "tools/tls_provider_poc/providers.json"
    spec_path.parent.mkdir(parents=True, exist_ok=True)
    spec_path.write_text(json.dumps(spec, indent=2) + "\n", encoding="utf-8")


def provider_result(platform: str, revision: str, spec: dict) -> dict:
    provider = next(item for item in spec["providers"] if item["id"] == "aws-lc")
    metrics = {
        "repeated_cleanup_cycles": 10000,
        "external_signer_calls": 2,
        "external_trust_calls": 4,
        "alpn_no_overlap_handshakes": 2,
        "alpn_malformed_inputs_rejected": 2,
        "certificate_negative_cases_rejected": 2,
        "session_resumption_handshakes": 4,
        "session_resumption_tls12_handshakes": 2,
        "session_resumption_tls13_handshakes": 2,
        "mtls_required_handshakes": 1,
        "mtls_optional_handshakes": 2,
        "local_close_operations": 2,
        "memory_profile_peak_resident_bytes": 64 * 1024 * 1024,
        "memory_profile_bound_bytes": adoption.poc_validate.MEMORY_PROFILE_BOUND_BYTES,
        "provider_allocation_calls": 200,
        "provider_allocation_call_bound": adoption.poc_validate.PROVIDER_ALLOCATION_CALL_BOUND,
        "provider_allocation_bytes": 1024 * 1024,
        "provider_allocation_bound_bytes": adoption.poc_validate.PROVIDER_ALLOCATION_PROFILE_BOUND_BYTES,
        "provider_allocation_peak_live_bytes": 512 * 1024,
        "provider_allocation_live_before_cleanup_bytes": 64 * 1024,
        "provider_allocation_live_after_cleanup_bytes": 64 * 1024,
        "cancellation_wakeups": 1,
        "cancellation_latency_us": 1000,
        "cancellation_bound_us": adoption.poc_validate.CANCELLATION_WAKE_BOUND_US,
    }
    diagnostic_supported = platform == "macos-arm64"
    return {
        "schema_version": adoption.poc_validate.RESULT_SCHEMA_VERSION,
        "task_id": "M0-016",
        "provider": "aws-lc",
        "platform": platform,
        "status": "PASS",
        "execution": {
            "repository_revision": revision,
            "runner_os": "Windows" if platform == "windows-x86_64" else "macOS",
            "runner_arch": "X64" if platform == "windows-x86_64" else "ARM64",
            "image_os": adoption.EXPECTED_RUNNER_IMAGES[platform],
            "image_version": "1",
        },
        "source": {
            "kind": provider["source_kind"],
            "commit": provider["commit"],
            "tree": provider["tree"],
            "content_sha256": provider["content_sha256"],
            "security_update": copy.deepcopy(provider["security_update"]),
        },
        "poc_exit_code": 0,
        "capabilities": {name: "PASS" for name in spec["required_capabilities"]},
        "build": {
            "binary_bytes": 1,
            "binary_sha256": "8" * 64,
            "static_archives": [
                {"name": "libssl.a", "bytes": 1, "sha256": "6" * 64}
            ],
            "exported_symbol_inventory": {
                "scope": "final-artifact-exports",
                "tool": "fixture-tool",
                "count": 0,
                "sha256": evidence_digest.text_evidence_bytes_sha256(b""),
                "symbols": [],
            },
            "system_tls_dependencies": [],
            "runtime_loader_library_strings": [],
            "license_bundle": {
                "path": "license-bundle/manifest.json",
                "sha256": "0" * 64,
                "file_count": 1,
                "total_bytes": len(b"synthetic license\n"),
            },
            "provenance": build_provenance(platform),
        },
        "metrics": metrics,
        "operational_evidence": {
            "native_memory_diagnostic": {
                "status": "PASS" if diagnostic_supported else "UNSUPPORTED",
                "tool": "address+undefined-sanitizer",
                "cleanup_cycles": 10,
                "output_sha256": "7" * 64,
                "leak_detection": {"status": "UNSUPPORTED"},
                **({
                    "provider_instrumented": True,
                    "provider_static_archives": [{
                        "name": "libprovider.a", "bytes": 1,
                        "sha256": "5" * 64,
                    }],
                    "provider_build_provenance": build_provenance(
                        platform, diagnostic=True
                    ),
                } if diagnostic_supported else {}),
            },
            "memory_profile": {
                "method": "native-process-peak-resident-and-provider-allocation-hooks",
                "peak_resident_bytes": metrics["memory_profile_peak_resident_bytes"],
                "resident_bound_bytes": metrics["memory_profile_bound_bytes"],
                "provider_allocation_calls": metrics["provider_allocation_calls"],
                "provider_allocation_call_bound": metrics["provider_allocation_call_bound"],
                "provider_allocation_bytes": metrics["provider_allocation_bytes"],
                "provider_allocation_bound_bytes": metrics["provider_allocation_bound_bytes"],
                "provider_allocation_peak_live_bytes": metrics["provider_allocation_peak_live_bytes"],
                "provider_allocation_live_before_cleanup_bytes": metrics["provider_allocation_live_before_cleanup_bytes"],
                "provider_allocation_live_after_cleanup_bytes": metrics["provider_allocation_live_after_cleanup_bytes"],
                "payload_bytes_per_transfer": 32768,
            },
            "cancellation": {
                "method": "caller-owned-wait-thread-explicit-cancel-and-bounded-join",
                "wakeups": metrics["cancellation_wakeups"],
                "latency_us": metrics["cancellation_latency_us"],
                "bound_us": metrics["cancellation_bound_us"],
            },
        },
    }


def materialize_current_license_bundle(
    platform: str, raw: dict, directory: str | Path, spec: dict
) -> Path:
    root = Path(directory)
    write_provider_fixture(root, spec)
    result_root = root / f"docs/evidence/M3-031/{platform}"
    bundle = result_root / "license-bundle"
    files_root = bundle / "files"
    files_root.mkdir(parents=True, exist_ok=True)
    license_content = b"synthetic license\n"

    license_path = files_root / "LICENSE"
    license_path.write_bytes(license_content)
    manifest = {
        "schema_version": 1,
        "task_id": "M0-016",
        "provider": "aws-lc",
        "source_content_sha256": raw["source"]["content_sha256"],
        "files": [{
            "path": "LICENSE",
            "bytes": len(license_content),
            "sha256": evidence_digest.text_evidence_bytes_sha256(license_content),
        }],
        "file_count": 1,
        "total_bytes": len(license_content),
    }
    manifest_path = bundle / "manifest.json"
    manifest_path.write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"

    )
    raw["build"]["license_bundle"].update({
        "sha256": evidence_digest.text_evidence_sha256(manifest_path),
        "file_count": 1,
        "total_bytes": len(license_content),
    })
    result_path = result_root / "provider-result.json"
    result_path.parent.mkdir(parents=True, exist_ok=True)
    result_path.write_text(json.dumps(raw, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    return result_path

def current_core_fixture(
    root: Path, sdk_archive: Path, *, prepare_audit_inputs: bool = False
) -> tuple[dict, dict]:
    root.mkdir(parents=True, exist_ok=True)
    core_paths = {
        relative
        for requirements in adoption.CORE_REQUIREMENTS.values()
        for relative, _ in requirements
    }
    protected_audit_inputs: set[str] = set()
    if prepare_audit_inputs:
        protected_audit_inputs = prepare_core_audit_inputs(root, "d" * 40)
    for relative in adoption.linux_release.QUALIFICATION_INPUTS:
        if prepare_audit_inputs and (
            relative in core_paths or relative in protected_audit_inputs
        ):
            continue
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(f"fixture input: {relative}\n", encoding="utf-8")
    (root / "src/core.cj").parent.mkdir(parents=True, exist_ok=True)
    (root / "src/core.cj").write_text("package fixture\n", encoding="utf-8")
    for relative in (
        "native/tls/aws_lc/provider.json",
        "tools/tls_provider/abi-v1.json",
        "tools/tls_provider/selection.json",
    ):
        target = root / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / relative, target)
    selected = adoption.select_provider(root)
    symbols = adoption.expected_symbols(selected)
    archive_path = root / adoption.CURRENT_CORE_NATIVE_ARCHIVE
    archive_path.parent.mkdir(parents=True, exist_ok=True)
    archive_path.write_bytes(b"synthetic provider archive bytes\n")
    archive_digest = evidence_digest.artifact_byte_digest(archive_path)
    source_identity = {
        field: selected.manifest["source"][field]
        for field in ("commit", "tree", "content_sha256")
    }
    target = {
        "os": "linux",
        "architecture": "x86_64",
        "libc": "glibc",
        "libc_version": "synthetic-fixture",
    }
    build_manifest = {
        "schema_version": 1,
        "providerId": selected.provider,
        "providerVersion": selected.manifest["provider_version"],
        "providerFingerprint": selected.manifest["source"]["content_sha256"],
        "backend": selected.manifest["abi"]["backend"],
        "abiVersion": selected.manifest["abi"]["version"],
        "patchLevel": "abi-1;patches=none",
        "capabilities": selected.manifest["capabilities"],
        "source": source_identity,
        "target": target,
        "build_fingerprint": "f" * 64,
        "test_only_key_log": False,
        "build_inputs": {"fixture": "unit-test"},
        "archive": {
            "name": archive_path.name,
            "bytes": archive_path.stat().st_size,
            "sha256": archive_digest.sha256,
        },
        "externalOpenSslDependency": False,
        "runtimeLoaderLibraryStrings": [],
    }
    manifest_path = root / "target/native/current/provider-manifest.json"
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    manifest_path.write_text(json.dumps(build_manifest), encoding="utf-8")

    artifact_path = root / adoption.CURRENT_CORE_ARTIFACT
    artifact_path.parent.mkdir(parents=True, exist_ok=True)
    artifact_bytes = b"synthetic installed consumer artifact\n"
    artifact_path.write_bytes(artifact_bytes)
    artifact_sha256 = evidence_digest.artifact_bytes_sha256(artifact_bytes)
    sample_qualification = json.loads(
        (ROOT / "docs/evidence/M7-021/linux_x86_64/qualification.json").read_text(
            encoding="utf-8"
        )
    )
    installed = copy.deepcopy(sample_qualification)
    installed["source_tree_sha256"] = adoption.linux_release.source_tree_sha256(root)
    installed["qualification_inputs"] = {
        relative: evidence_digest.text_evidence_sha256(root / relative)
        for relative in adoption.linux_release.QUALIFICATION_INPUTS
    }
    installed["artifact"].update({
        "name": artifact_path.name,
        "bytes": len(artifact_bytes),
        "sha256": artifact_sha256,
        "reproducibility": {
            "builds": 2,
            "digests": [artifact_sha256, artifact_sha256],
            "byte_identical": True,
        },
    })
    installed_path = root / adoption.CURRENT_CORE_INSTALLED_QUALIFICATION
    installed_path.parent.mkdir(parents=True, exist_ok=True)
    installed_path.write_text(json.dumps(installed, indent=2) + "\n", encoding="utf-8")

    production_sources = {
        "src/core.cj": evidence_digest.text_evidence_digest_bytes(b"fixture source").to_json()
    }
    execution_inputs = {
        "tools/fixture.py": evidence_digest.text_evidence_digest_bytes(b"fixture input").to_json()
    }
    sdk = {
        "archive": evidence_digest.artifact_byte_digest(sdk_archive).to_json(),
        "matched_archive_files": 1,
        "cjc": "Cangjie Compiler: 1.1.3",
        "cjpm": "CJPM 1.1.3",
    }
    platform = target
    binding = {
        "production_sources": production_sources,
        "execution_inputs": execution_inputs,
        "sdk": sdk,
        "platform": platform,
        "symbols": symbols,
    }
    run_id = "a" * 32
    command_text = {
        "provider-build": (
            "Linux TLS provider ready: <repo>/target/native/current\n"
            + json.dumps({
                "abi_version": selected.manifest["abi"]["version"],
                "adapter": selected.adapter,
                "build_fingerprint": build_manifest["build_fingerprint"],
                "platform": selected.platform,
                "provider": selected.provider,
                "selection_fingerprint": selected.fingerprint,
                "status": "PASS",
            }, sort_keys=True)
            + "\n"
        ),
        "architecture-guard": json.dumps({
            "schema_version": 1,
            "kind": "architecture-guard",
            "status": "PASS",
            "ok": True,
            "violation_count": 0,
            "violations": [],
        }),
        "provider-substitution": (
            "TCS: TlsProviderSubstitutionTest, time elapsed: 100 ns, RESULT:\n"
            + "".join(
                f"    [ PASSED ] CASE: {case} (1 ns)\n"
                for case in adoption.CURRENT_CORE_CASES
            )
            + "Summary: TOTAL: 3\n"
            + "    PASSED: 3, SKIPPED: 0, ERROR: 0\n"
            + "    FAILED: 0\n"
            + "Project tests finished, time elapsed: 110 ns, RESULT:\n"
            + "TP: wirestack.*, time elapsed: 100 ns, RESULT:\n"
            + "Summary: TOTAL: 3\n"
            + "    PASSED: 3, SKIPPED: 0, ERROR: 0\n"
            + "    FAILED: 0\n"
        ),
        "installed-consumer": (
            "M7-021 Linux release qualification: PASS\n"
            f"artifact=<repo>/{adoption.CURRENT_CORE_ARTIFACT}\n"
            f"sha256={artifact_sha256}\n"
            f"report=<repo>/{adoption.CURRENT_CORE_INSTALLED_QUALIFICATION}\n"
        ),
    }
    logs = []
    commands = []
    started = "2030-01-15T12:00:00Z"
    finished = "2030-01-15T12:00:01Z"
    for expected in adoption.CURRENT_CORE_COMMANDS:
        commands.append({
            "id": expected["id"],
            "argv": expected["argv"],
            "status": "PASS",
            "exit_code": 0,
            "timed_out": False,
            "duration_ms": 1000,
            "started_at_utc": started,
            "finished_at_utc": finished,
        })
        for stream in ("stdout", "stderr"):
            name = f"{expected['id']}.{stream}.log"
            content = command_text[expected["id"]] if stream == "stdout" else ""
            log_path = (
                root / "docs/evidence/M3-031/current-core/runs"
                / run_id / "commands" / name
            )
            log_path.parent.mkdir(parents=True, exist_ok=True)
            log_path.write_text(content, encoding="utf-8")
            logs.append({
                "path": log_path.relative_to(root).as_posix(),
                "digest": evidence_digest.text_evidence_digest(log_path).to_json(),
            })
    qualification_log = (
        root / "docs/evidence/M3-031/current-core/runs" / run_id
        / "commands/installed-consumer.qualification.log"
    )
    qualification_log.write_text(installed_path.read_text(encoding="utf-8"), encoding="utf-8")
    logs.append({
        "path": qualification_log.relative_to(root).as_posix(),
        "digest": evidence_digest.text_evidence_digest(qualification_log).to_json(),
    })
    report = {
        "schema_version": 1,
        "source_task": "M3-031",
        "task_id": "M3-031",
        "kind": adoption.CURRENT_CORE_KIND,
        "status": "PASS",
        "revision": "d" * 40,
        "platform": platform,
        "production_sources": production_sources,
        "execution_inputs": execution_inputs,
        "sdk": sdk,
        "selection": adoption._current_core_selection(selected),
        "native_archive": {
            "path": adoption.CURRENT_CORE_NATIVE_ARCHIVE,
            "digest": archive_digest.to_json(),
        },
        "commands": commands,
        "logs": logs,
        "installed_consumer": {
            "qualification": {
                "path": adoption.CURRENT_CORE_INSTALLED_QUALIFICATION,
                "digest": evidence_digest.text_evidence_digest(installed_path).to_json(),
            },
            "artifact": {
                "path": adoption.CURRENT_CORE_ARTIFACT,
                "digest": evidence_digest.artifact_byte_digest(artifact_path).to_json(),
            },
        },
        "release": copy.deepcopy(adoption.development_baseline.RELEASE),
    }
    return report, binding

def prepare_core_audit_inputs(root: Path, revision: str) -> set[str]:
    for requirements in adoption.CORE_REQUIREMENTS.values():
        for relative, _ in requirements:
            copy_repo_file(root, relative)
    protected: set[str] = set()
    for task_id in ("M2-004", "M2-006"):
        task_relative = f"tools/tasks/{task_id}.json"
        task_path = copy_repo_file(root, task_relative)
        task = json.loads(task_path.read_text(encoding="utf-8"))
        source_paths = task["source_paths"]
        for relative in source_paths:
            copy_repo_file(root, relative)
            protected.add(relative)
        protected.add(task_relative)
    task_path = copy_repo_file(root, "tools/tasks/M3-030.json")
    task = json.loads(task_path.read_text(encoding="utf-8"))
    for relative in set(task["source_paths"]) | set(task["required_evidence"]):
        copy_repo_file(root, relative)
    for relative in (
        "docs/planning/status.md",
        "docs/planning/implementation-backlog.md",
        *adoption.HISTORICAL_REFERENCES,
    ):
        copy_repo_file(root, relative)
    status_path = root / "docs/planning/status.md"
    status_lines = []
    for line in status_path.read_text(encoding="utf-8").splitlines():
        if line.startswith("| M2-004 |") or line.startswith("| M2-006 |"):
            columns = line.split("|")
            columns[2] = " BLOCKED "
            line = "|".join(columns)
        status_lines.append(line)
    status_path.write_text("\n".join(status_lines) + "\n", encoding="utf-8")
    protected.add("docs/planning/status.md")
    protected.update(write_current_desktop_resolver_fixtures(root, revision))
    return protected


def write_current_desktop_resolver_fixtures(root: Path, revision: str) -> set[str]:
    """Build synthetic receipts for binding tests, not native qualification."""

    protected: set[str] = set()
    for task_id, binding in adoption.CURRENT_DESKTOP_RESOLVER_EVIDENCE.items():
        task_path = root / f"tools/tasks/{task_id}.json"
        task = json.loads(task_path.read_text(encoding="utf-8"))
        source_paths = task["source_paths"]
        entries = []
        for relative in source_paths:
            source_path = root / relative
            entries.append({
                "path": relative,
                "digest": evidence_digest.text_evidence_digest(source_path).to_json(),
            })
            protected.add(relative)

        pin = json.loads((root / binding["pin"]).read_text(encoding="utf-8"))
        sdk = {
            "channel": pin["channel"],
            "version": pin["version"],
            "archive_name": pin["archive"]["name"],
            "archive": {
                "domain": evidence_digest.ARTIFACT_BYTE_DOMAIN,
                "sha256": pin["archive"]["sha256"],
            },
        }
        if task_id == "M2-004":
            canonical_inventory = json.dumps(
                {"schema_version": 1, "paths": entries},
                sort_keys=True,
                separators=(",", ":"),
                ensure_ascii=False,
            )
            inventory = {
                "schema_version": 1,
                "paths": entries,
                "digest": evidence_digest.text_evidence_digest_bytes(
                    canonical_inventory.encode("utf-8")
                ).to_json(),
            }
        else:
            inventory = {
                "revision": revision,
                "clean_worktree": True,
                "files": entries,
            }

        logs = {}
        log_bindings = adoption.CURRENT_DESKTOP_LOG_IDS[task_id]
        for log_id, relative in log_bindings.items():
            log_relative = (
                relative
                if task_id == "M2-004"
                else (Path(binding["report"]).parent / relative).as_posix()
            )
            log_path = root / log_relative
            log_path.parent.mkdir(parents=True, exist_ok=True)
            log_path.write_text(f"synthetic native log {task_id}/{log_id}\n", encoding="utf-8")
            protected.add(log_relative)
            if task_id == "M2-004":
                logs[log_id] = {
                    "path": relative,
                    "digest": evidence_digest.text_evidence_digest(log_path).to_json(),
                }
            else:
                logs[log_id] = {
                    "id": log_id,
                    "path": relative,
                    "digest": evidence_digest.text_evidence_digest(log_path).to_json(),
                }

        report = {
            "schema_version": 2,
            "task_id": task_id,
            "revision": revision,
            "decision": "PASS",
            "failures": [],
            "sdk": sdk,
            "source_inventory": inventory,
            "logs": logs if task_id == "M2-004" else list(logs.values()),
        }
        if task_id == "M2-006":
            report["mode"] = "macos"
        report_path = root / binding["report"]
        report_path.parent.mkdir(parents=True, exist_ok=True)
        report_path.write_text(json.dumps(report, sort_keys=True) + "\n", encoding="utf-8")
        validation = {
            "schema_version": 2,
            "task_id": task_id,
            "expected_revision": revision,
            "report_digest": evidence_digest.text_evidence_digest(report_path).to_json(),
            "failures": [],
            "status": "PASS",
        }
        if task_id == "M2-004":
            validation["source_inventory_digest"] = inventory["digest"]
        else:
            validation["expected_mode"] = "macos"
        validation_path = root / binding["validation"]
        validation_path.parent.mkdir(parents=True, exist_ok=True)
        validation_path.write_text(
            json.dumps(validation, sort_keys=True) + "\n", encoding="utf-8"
        )
        protected.update((binding["report"], binding["validation"]))
    return protected


@contextmanager
def current_desktop_resolver_validation_patches():
    with ExitStack() as stack:
        stack.enter_context(mock.patch.object(
            adoption.m2_004_windows_resolver,
            "validate_current_desktop_artifacts",
            return_value=[],
        ))
        stack.enter_context(mock.patch.object(
            adoption.m2_006_apple_resolver,
            "validate_current_desktop_artifacts",
            return_value=[],
        ))
        yield

def copy_repo_file(root: Path, relative: str) -> Path:
    source = ROOT / relative
    target = root / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, target)
    return target




def synthetic_historical_core_fixture(root: Path) -> Path:
    task_path = copy_repo_file(root, "tools/tasks/M3-030.json")
    task = json.loads(task_path.read_text(encoding="utf-8"))
    for relative in task["source_paths"]:
        copy_repo_file(root, relative)
    copy_repo_file(root, "docs/planning/status.md")

    records = []
    for relative in adoption.RETAINED_EVIDENCE:
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        # These synthetic records exercise historical integrity only; they
        # contain no native qualification data or claim about M3-030.
        path.write_text(json.dumps({"source_task": "M3-030", "status": "PASS"}), encoding="utf-8")
        records.append({
            "path": relative,
            "source_task": "M3-030",
            "acceptance_status": "PASS",
            "sha256": evidence_digest.text_evidence_sha256(path),
        })
    evidence = {
        "schema_version": 1,
        "source_task": "M3-030",
        "acceptance_status": "PASS",
        "reports": records,
        "source_sha256": {
            relative: evidence_digest.text_evidence_sha256(root / relative)
            for relative in task["source_paths"]
        },
    }
    evidence_path = root / "docs/evidence/M3-030/evidence.json"
    evidence_path.parent.mkdir(parents=True, exist_ok=True)
    evidence_path.write_text(json.dumps(evidence), encoding="utf-8")
    return evidence_path



@contextmanager
def current_core_validation_patches(binding: dict):
    with ExitStack() as stack:
        stack.enter_context(mock.patch.object(
            adoption.development_baseline,
            "production_binding",
            return_value=binding["production_sources"],
        ))
        stack.enter_context(mock.patch.object(
            adoption.development_baseline,
            "execution_inputs",
            return_value=binding["execution_inputs"],
        ))
        stack.enter_context(mock.patch.object(
            adoption.development_baseline, "sdk_identity", return_value=binding["sdk"]
        ))
        stack.enter_context(mock.patch.object(
            adoption.linux_release,
            "platform_identity",
            return_value=binding["platform"],
        ))
        stack.enter_context(mock.patch.object(adoption, "validate_native_header_signatures"))
        stack.enter_context(mock.patch.object(
            adoption,
            "archive_symbols",
            return_value=binding["symbols"],
        ))
        yield


class M3031DesktopTlsAdoptionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.spec = fixture_spec(FIXED_NOW)
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        write_provider_fixture(self.root, self.spec)

    def validate_provider_result(
        self, raw: dict, *, expected_platform: str,
        expected_revision: str | None = None, result_path: Path | None = None,
        root: Path | None = None,
    ) -> dict:
        with mock.patch.object(adoption.poc_validate.dt, "datetime", FrozenDateTime):
            return adoption.validate_provider_result(
                raw,
                expected_platform=expected_platform,
                expected_revision=expected_revision or self.revision,
                root=root or self.root,
                result_path=result_path,
            )

    def make_current_core_case(self, *, for_audit: bool = False):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        base = Path(temporary.name)
        root = base / "repo"
        sdk_archive = base / "cangjie-sdk.tar.gz"
        sdk_archive.write_bytes(b"synthetic pinned SDK archive")
        report, binding = current_core_fixture(
            root, sdk_archive, prepare_audit_inputs=for_audit
        )
        return root, sdk_archive, report, binding



    revision = "d" * 40

    def assert_code(self, code: str, callback) -> None:
        with self.assertRaises(adoption.AdoptionError) as caught:
            callback()
        self.assertEqual(code, caught.exception.code)

    def write_substitution_log(
        self,
        root: Path,
        report: dict,
        case_statuses: list[str],
        *,
        duplicate_case: str | None = None,
    ) -> None:
        rows = [
            (status, case)
            for status, case in zip(case_statuses, adoption.CURRENT_CORE_CASES)
        ]
        if duplicate_case is not None:
            rows.append(("PASSED", duplicate_case))
        unrelated_skips = 28
        passed = sum(status == "PASSED" for status, _ in rows)
        skipped = unrelated_skips + sum(status == "SKIPPED" for status, _ in rows)
        errors = sum(status == "ERROR" for status, _ in rows)
        failed = sum(status == "FAILED" for status, _ in rows)
        summary = (
            f"Summary: TOTAL: {unrelated_skips + len(rows)}\n"
            f"    PASSED: {passed}, SKIPPED: {skipped}, ERROR: {errors}\n"
            f"    FAILED: {failed}\n"
        )
        output = (
            "TP: wirestack.internal.tls_engine, time elapsed: 100 ns, RESULT:\n"
            "    TCS: TlsProviderSubstitutionTest, time elapsed: 90 ns, RESULT:\n"
            + "".join(
                f"    [ {status} ] CASE: {case} (1 ns)\n"
                for status, case in rows
            )
            + summary
            + "--------------------------------------------------------------------------------------------------\n"
            + "Project tests finished, time elapsed: 110 ns, RESULT:\n"
            + "TP: wirestack.*, time elapsed: 100 ns, RESULT:\n"
            + "    PASSED:\n"
            + "    TP: wirestack.internal.tls_engine, time elapsed: 95 ns\n"
            + summary
            + "--------------------------------------------------------------------------------------------------\n"
            + "cjpm test success\n"
        )
        record = next(
            item for item in report["logs"]
            if Path(item["path"]).name == "provider-substitution.stdout.log"
        )
        log_path = root / record["path"]
        log_path.write_text(output, encoding="utf-8")
        record["digest"] = evidence_digest.text_evidence_digest(
            log_path
        ).to_json()

    def test_current_core_accepts_filtered_substitution_cases(self) -> None:
        root, sdk_archive, report, binding = self.make_current_core_case()
        self.write_substitution_log(
            root, report, ["PASSED", "PASSED", "PASSED"]
        )
        with current_core_validation_patches(binding):
            self.assertEqual(
                report,
                adoption.validate_current_core(root, report, sdk_archive),
            )

    def test_current_core_rejects_nonpassing_or_duplicated_substitution_cases(
        self,
    ) -> None:
        root, sdk_archive, report, binding = self.make_current_core_case()
        with current_core_validation_patches(binding):
            for status in ("SKIPPED", "FAILED", "ERROR"):
                self.write_substitution_log(
                    root,
                    report,
                    [status, "PASSED", "PASSED"],
                )
                self.assert_code(
                    "CURRENT_CORE_SUBSTITUTION",
                    lambda: adoption.validate_current_core(
                        root, report, sdk_archive
                    ),
                )
            self.write_substitution_log(
                root,
                report,
                ["PASSED", "PASSED", "PASSED"],
                duplicate_case=adoption.CURRENT_CORE_CASES[0],
            )
            self.assert_code(
                "CURRENT_CORE_SUBSTITUTION",
                lambda: adoption.validate_current_core(root, report, sdk_archive),
            )
            timed_out = copy.deepcopy(report)
            timed_out["commands"][2]["timed_out"] = True
            self.assert_code(
                "CURRENT_CORE_COMMANDS",
                lambda: adoption.validate_current_core(
                    root, timed_out, sdk_archive
                ),
            )

    def test_current_core_fixture_uses_stable_synthetic_linux_platform(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "repo"
            sdk_archive = Path(directory) / "cangjie-sdk.tar.gz"
            sdk_archive.write_bytes(b"synthetic pinned SDK archive")
            with mock.patch.object(
                adoption.linux_release,
                "platform_identity",
                side_effect=AssertionError("fixture must not inspect host platform"),
            ):
                report, binding = current_core_fixture(root, sdk_archive)
            self.assertEqual(
                {
                    "os": "linux",
                    "architecture": "x86_64",
                    "libc": "glibc",
                    "libc_version": "synthetic-fixture",
                },
                binding["platform"],
            )
            with current_core_validation_patches(binding):
                self.assertEqual(
                    report,
                    adoption.validate_current_core(root, report, sdk_archive),
                )


    def test_current_core_requires_complete_report_and_command_receipts(self) -> None:
        root, sdk_archive, report, binding = self.make_current_core_case()
        with current_core_validation_patches(binding):
            self.assertEqual(
                report,
                adoption.validate_current_core(root, report, sdk_archive),
            )
            self.assert_code(
                "CURRENT_CORE_SCHEMA",
                lambda: adoption.validate_current_core(
                    root, {"status": "PASS"}, sdk_archive
                ),
            )
            boolean_schema = copy.deepcopy(report)
            boolean_schema["schema_version"] = True
            self.assert_code(
                "CURRENT_CORE_SCHEMA",
                lambda: adoption.validate_current_core(
                    root, boolean_schema, sdk_archive
                ),
            )
            missing_command = copy.deepcopy(report)
            missing_command["commands"].pop()
            self.assert_code(
                "CURRENT_CORE_COMMANDS",
                lambda: adoption.validate_current_core(
                    root, missing_command, sdk_archive
                ),
            )
            changed_argv = copy.deepcopy(report)
            changed_argv["commands"][0]["argv"].append("--unexpected")
            self.assert_code(
                "CURRENT_CORE_COMMANDS",
                lambda: adoption.validate_current_core(
                    root, changed_argv, sdk_archive
                ),
            )
            skipped = copy.deepcopy(report)
            skipped["commands"][2]["status"] = "SKIPPED"
            self.assert_code(
                "CURRENT_CORE_COMMANDS",
                lambda: adoption.validate_current_core(root, skipped, sdk_archive),
            )
            timed_out = copy.deepcopy(report)
            timed_out["commands"][0]["timed_out"] = True
            self.assert_code(
                "CURRENT_CORE_COMMANDS",
                lambda: adoption.validate_current_core(root, timed_out, sdk_archive),
            )

    def test_current_core_rejects_boolean_architecture_guard_schema(self) -> None:
        root, sdk_archive, report, binding = self.make_current_core_case()
        guard_record = next(
            record for record in report["logs"]
            if Path(record["path"]).name == "architecture-guard.stdout.log"
        )
        guard_path = root / guard_record["path"]
        guard_path.write_text(
            json.dumps({
                "schema_version": True,
                "kind": "architecture-guard",
                "status": "PASS",
                "ok": True,
                "violation_count": 0,
                "violations": [],
            }),
            encoding="utf-8",
        )
        guard_record["digest"] = evidence_digest.text_evidence_digest(
            guard_path
        ).to_json()
        with current_core_validation_patches(binding):
            self.assert_code(
                "CURRENT_CORE_ARCHITECTURE",
                lambda: adoption.validate_current_core(root, report, sdk_archive),
            )

    def test_current_core_rejects_source_sdk_and_log_drift(self) -> None:
        root, sdk_archive, report, binding = self.make_current_core_case()
        with current_core_validation_patches(binding):
            changed_source = copy.deepcopy(report)
            changed_source["production_sources"]["src/core.cj"]["sha256"] = "0" * 64
            self.assert_code(
                "STALE_SOURCE",
                lambda: adoption.validate_current_core(
                    root, changed_source, sdk_archive
                ),
            )
            changed_inputs = copy.deepcopy(report)
            changed_inputs["execution_inputs"]["tools/fixture.py"]["sha256"] = "0" * 64
            self.assert_code(
                "STALE_SOURCE",
                lambda: adoption.validate_current_core(
                    root, changed_inputs, sdk_archive
                ),
            )
            changed_sdk = copy.deepcopy(report)
            changed_sdk["sdk"]["cjpm"] = "unqualified compiler"
            self.assert_code(
                "SDK_IDENTITY",
                lambda: adoption.validate_current_core(root, changed_sdk, sdk_archive),
            )
            log_path = root / report["logs"][0]["path"]
            original = log_path.read_bytes()
            log_path.write_bytes(original + b"drift")
            self.assert_code(
                "STALE_SOURCE",
                lambda: adoption.validate_current_core(root, report, sdk_archive),
            )
            log_path.write_bytes(original)
            escaping_log = copy.deepcopy(report)
            escaping_log["logs"][0]["path"] = "../../outside.log"
            self.assert_code(
                "CURRENT_CORE_LOGS",
                lambda: adoption.validate_current_core(
                    root, escaping_log, sdk_archive
                ),
            )
            missing_log = copy.deepcopy(report)
            missing_log["logs"].pop()
            self.assert_code(
                "CURRENT_CORE_LOGS",
                lambda: adoption.validate_current_core(root, missing_log, sdk_archive),
            )
            cross_run_log = copy.deepcopy(report)
            cross_run_log["logs"][0]["path"] = cross_run_log["logs"][0]["path"].replace(
                "a" * 32, "b" * 32, 1
            )
            self.assert_code(
                "CURRENT_CORE_LOGS",
                lambda: adoption.validate_current_core(
                    root, cross_run_log, sdk_archive
                ),
            )

    def test_current_core_rechecks_header_archive_symbols_and_bytes(self) -> None:
        root, sdk_archive, report, binding = self.make_current_core_case()
        with current_core_validation_patches(binding):
            with mock.patch.object(
                adoption,
                "validate_native_header_signatures",
                side_effect=RuntimeError("header mismatch"),
            ):
                self.assert_code(
                    "CURRENT_CORE_ABI",
                    lambda: adoption.validate_current_core(root, report, sdk_archive),
                )
            missing_symbol = next(iter(binding["symbols"]))
            with mock.patch.object(
                adoption, "archive_symbols",
                return_value=set(binding["symbols"]) - {missing_symbol},
            ):
                self.assert_code(
                    "CURRENT_CORE_ABI",
                    lambda: adoption.validate_current_core(root, report, sdk_archive),
                )

            archive_path = root / adoption.CURRENT_CORE_NATIVE_ARCHIVE
            archive_path.write_bytes(archive_path.read_bytes() + b"drift")
            manifest_path = root / "target/native/current/provider-manifest.json"
            build_manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            build_manifest["archive"]["bytes"] = archive_path.stat().st_size
            build_manifest["archive"]["sha256"] = evidence_digest.artifact_byte_sha256(
                archive_path
            )
            manifest_path.write_text(json.dumps(build_manifest), encoding="utf-8")
            self.assert_code(
                "STALE_SOURCE",
                lambda: adoption.validate_current_core(root, report, sdk_archive),
            )

    def test_current_core_rejects_invalid_installed_consumer_evidence(self) -> None:
        root, sdk_archive, report, binding = self.make_current_core_case()
        installed_path = root / adoption.CURRENT_CORE_INSTALLED_QUALIFICATION
        installed = json.loads(installed_path.read_text(encoding="utf-8"))
        installed["installation"]["https_client_server_smoke"] = "FAIL"
        installed_path.write_text(json.dumps(installed), encoding="utf-8")
        with current_core_validation_patches(binding):
            self.assert_code(
                "CURRENT_CORE_CONSUMER",
                lambda: adoption.validate_current_core(root, report, sdk_archive),
            )


        root, sdk_archive, report, binding = self.make_current_core_case()
        qualification_log = next(
            record for record in report["logs"]
            if Path(record["path"]).name == "installed-consumer.qualification.log"
        )
        qualification_log_path = root / qualification_log["path"]
        qualification_log_path.write_bytes(
            qualification_log_path.read_bytes() + b"drift"
        )
        qualification_log["digest"] = evidence_digest.text_evidence_digest(
            qualification_log_path
        ).to_json()
        with current_core_validation_patches(binding):
            self.assert_code(
                "CURRENT_CORE_CONSUMER",
                lambda: adoption.validate_current_core(root, report, sdk_archive),
            )
        root, sdk_archive, report, binding = self.make_current_core_case()
        artifact_path = root / adoption.CURRENT_CORE_ARTIFACT
        artifact_path.write_bytes(artifact_path.read_bytes() + b"drift")
        with current_core_validation_patches(binding):
            self.assert_code(
                "STALE_SOURCE",
                lambda: adoption.validate_current_core(root, report, sdk_archive),
            )

    def test_core_audit_keeps_historical_diagnostic_but_rejects_stale_native_evidence(self) -> None:
        root, sdk_archive, report, binding = self.make_current_core_case(for_audit=True)
        current_path = root / adoption.CURRENT_CORE_RELATIVE
        current_path.parent.mkdir(parents=True, exist_ok=True)
        current_path.write_text(json.dumps(report), encoding="utf-8")

        self.assert_code(
            "STALE_SOURCE",
            lambda: adoption.validate_historical_core_evidence(root),
        )
        historical = adoption._historical_core_diagnostic(root)
        self.assertEqual("HISTORICAL", historical["status"])
        self.assertEqual("STALE", historical["integrity_status"])
        self.assertEqual("STALE_SOURCE", historical["code"])
        self.assertIn("docs/evidence/M3-030/task-check.json", historical["detail"])

        source = root / "native/resolver/windows/wirestack_resolver.c"
        with current_core_validation_patches(binding):
            with current_desktop_resolver_validation_patches():
                self.assertEqual(
                    report, adoption.validate_current_core(root, report, sdk_archive)
                )
                audit = adoption.audit_core(root, sdk_archive)
                self.assertEqual("PASS", audit["status"])
                self.assertEqual(
                    "HISTORICAL",
                    audit["historical_core_evidence_validation"]["status"],
                )

                source.write_bytes(source.read_bytes() + b"changed after native capture\n")
                with self.assertRaises(adoption.AdoptionError) as caught:
                    adoption.audit_core(root, sdk_archive)
                self.assertEqual("DEPENDENCY_EVIDENCE", caught.exception.code)
                self.assertIn(
                    "M2-004: current source digest changed",
                    caught.exception.detail,
                )

                current_path.write_text(json.dumps({"status": "PASS"}), encoding="utf-8")
                self.assert_code(
                    "CURRENT_CORE_SCHEMA",
                    lambda: adoption.audit_core(root, sdk_archive),
                )


    def test_aggregate_rejects_fabricated_current_core_pass(self) -> None:
        root, sdk_archive, report, binding = self.make_current_core_case(for_audit=True)
        current_path = root / adoption.CURRENT_CORE_RELATIVE
        current_path.parent.mkdir(parents=True, exist_ok=True)
        current_path.write_text(json.dumps(report), encoding="utf-8")
        with current_core_validation_patches(binding):
            with current_desktop_resolver_validation_patches():
                self.assert_code(
                    "CORE_REQUIREMENT",
                    lambda: adoption.aggregate(
                        {"status": "PASS"},
                        {},
                        {},
                        report["revision"],
                        root=root,
                        sdk_archive=sdk_archive,
                    ),
                )


    def test_direct_current_desktop_proof_does_not_require_global_m2_status(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            revision = "e" * 40
            prepare_core_audit_inputs(root, revision)
            status = (root / "docs/planning/status.md").read_text(encoding="utf-8")
            self.assertIn("| M2-004 | BLOCKED |", status)
            self.assertIn("| M2-006 | BLOCKED |", status)

            with current_desktop_resolver_validation_patches():
                evidence = adoption.validate_dependency_evidence(root, revision)

            self.assertEqual("PASS", evidence["status"])
            self.assertEqual(
                set(adoption.CURRENT_DESKTOP_RESOLVER_EVIDENCE),
                set(evidence["tasks"]),
            )
            self.assertEqual(
                status,
                (root / "docs/planning/status.md").read_text(encoding="utf-8"),
            )

    def test_direct_current_desktop_proof_rejects_source_log_report_and_missing_drift(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            revision = "e" * 40
            prepare_core_audit_inputs(root, revision)
            binding = adoption.CURRENT_DESKTOP_RESOLVER_EVIDENCE["M2-004"]
            source_path = root / "native/resolver/windows/wirestack_resolver.c"
            original_source = source_path.read_bytes()
            report_path = root / binding["report"]
            original_report = report_path.read_bytes()
            log_path = root / adoption.CURRENT_DESKTOP_LOG_IDS["M2-004"]["resolver_build"]
            original_log = log_path.read_bytes()

            with current_desktop_resolver_validation_patches():
                source_path.write_bytes(original_source + b"source drift\n")
                self.assert_code(
                    "DEPENDENCY_EVIDENCE",
                    lambda: adoption.validate_dependency_evidence(root, revision),
                )
                source_path.write_bytes(original_source)

                log_path.write_bytes(original_log + b"log drift\n")
                self.assert_code(
                    "DEPENDENCY_EVIDENCE",
                    lambda: adoption.validate_dependency_evidence(root, revision),
                )
                log_path.write_bytes(original_log)

                changed_report = json.loads(original_report)
                changed_report["scope"] = {"synthetic_mutation": True}
                report_path.write_text(
                    json.dumps(changed_report, sort_keys=True) + "\n",
                    encoding="utf-8",
                )
                self.assert_code(
                    "DEPENDENCY_EVIDENCE",
                    lambda: adoption.validate_dependency_evidence(root, revision),
                )
                validation_path = root / binding["validation"]
                original_validation = validation_path.read_bytes()
                changed_report = json.loads(original_report)
                changed_report["sdk"]["archive"]["sha256"] = "0" * 64
                report_path.write_text(
                    json.dumps(changed_report, sort_keys=True) + "\n",
                    encoding="utf-8",
                )
                validation = json.loads(original_validation)
                validation["report_digest"] = evidence_digest.text_evidence_digest(
                    report_path
                ).to_json()
                validation_path.write_text(
                    json.dumps(validation, sort_keys=True) + "\n",
                    encoding="utf-8",
                )
                with self.assertRaises(adoption.AdoptionError) as caught:
                    adoption.validate_dependency_evidence(root, revision)
                self.assertEqual("DEPENDENCY_EVIDENCE", caught.exception.code)
                self.assertIn("pinned SDK identity changed", caught.exception.detail)
                report_path.write_bytes(original_report)
                validation_path.write_bytes(original_validation)

                report_path.unlink()
                self.assert_code(
                    "DEPENDENCY_EVIDENCE",
                    lambda: adoption.validate_dependency_evidence(root, revision),
                )

    def test_historical_verifier_preserves_integrity_checks_without_qualification(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            evidence_path = synthetic_historical_core_fixture(root)

            historical = adoption.validate_historical_core_evidence(root)
            self.assertEqual("HISTORICAL", historical["status"])
            self.assertEqual("HISTORICAL_ONLY", historical["qualification"])
            self.assertEqual(set(adoption.RETAINED_EVIDENCE), set(historical["reports"]))

            report_path = root / adoption.RETAINED_EVIDENCE[0]
            original_report = report_path.read_bytes()
            report_path.write_bytes(original_report + b"drift")
            self.assert_code(
                "STALE_SOURCE",
                lambda: adoption.validate_historical_core_evidence(root),
            )
            report_path.write_bytes(original_report)
            report_path.unlink()
            self.assert_code(
                "RETAINED_EVIDENCE",
                lambda: adoption.validate_historical_core_evidence(root),
            )
            report_path.write_bytes(original_report)

            evidence = json.loads(evidence_path.read_text(encoding="utf-8"))
            source_relative = "build.cj"
            self.assertIn(source_relative, evidence["source_sha256"])
            source_digest = evidence["source_sha256"].pop(source_relative)
            evidence_path.write_text(json.dumps(evidence), encoding="utf-8")
            self.assert_code(
                "RETAINED_EVIDENCE",
                lambda: adoption.validate_historical_core_evidence(root),
            )
            evidence["source_sha256"][source_relative] = source_digest
            evidence_path.write_text(json.dumps(evidence), encoding="utf-8")
            (root / source_relative).write_text("historical source drift", encoding="utf-8")
            historical = adoption.validate_historical_core_evidence(root)
            self.assertEqual("HISTORICAL", historical["status"])
            self.assertIn(source_relative, historical["changed_since_m3_030"])


    def test_hosted_receipt_binds_all_sources_artifacts_and_results(self) -> None:
        revision = "a" * 40
        for relative in adoption.HOSTED_INPUT_PATHS:
            path = self.root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(f"synthetic hosted source: {relative}\n", encoding="utf-8")
        pairs = (
            (
                "windows-x86_64",
                "docs/evidence/M3-031/windows-x86_64/provider-result.json",
                "docs/evidence/M3-031/windows-x86_64/validation.json",
            ),
            (
                "macos-arm64",
                "docs/evidence/M3-031/macos-arm64/provider-result.json",
                "docs/evidence/M3-031/macos-arm64/validation.json",
            ),
        )
        artifacts = []
        for index, (platform, result_relative, validation_relative) in enumerate(pairs, 1):
            result_path = self.root / result_relative
            validation_path = self.root / validation_relative
            result_path.parent.mkdir(parents=True, exist_ok=True)
            result_path.write_text(
                json.dumps({"platform": platform, "status": "PASS"}) + "\n",
                encoding="utf-8",
            )
            validation_path.write_text(
                json.dumps({"platform": platform, "status": "PASS"}) + "\n",
                encoding="utf-8",
            )
            artifacts.append({
                "artifact_id": 1000 + index,
                "archive_digest": f"sha256:{str(index) * 64}",
                "expires_at": "2030-01-16T12:00:00Z",
                "name": f"m3-031-{platform}-{revision}",
                "provider_result_sha256": evidence_digest.text_evidence_sha256(result_path),
                "validation_sha256": evidence_digest.text_evidence_sha256(validation_path),
            })
        raw = {
            "schema_version": 2,
            "task_id": "M3-031",
            "status": "PASS",
            "conclusion": "success",
            "revision": revision,
            "source_sha256": adoption.hosted_input_sha256(self.root),
            "artifacts": artifacts,
        }
        self.assertEqual("PASS", adoption.validate_hosted_run(self.root, raw)["status"])

        for relative in adoption.HOSTED_INPUT_PATHS:
            path = self.root / relative
            original = path.read_bytes()
            path.write_bytes(original + b"drift")
            self.assert_code(
                "STALE_SOURCE", lambda: adoption.validate_hosted_run(self.root, raw)
            )
            path.write_bytes(original)

        changed_artifact = copy.deepcopy(raw)
        changed_artifact["artifacts"][0]["name"] = "m3-031-windows-x86_64-" + "b" * 40
        self.assert_code(
            "STALE_REVISION",
            lambda: adoption.validate_hosted_run(self.root, changed_artifact),
        )
        invalid_artifact = copy.deepcopy(raw)
        invalid_artifact["artifacts"][0]["artifact_id"] = 0
        self.assert_code(
            "HOSTED_ARTIFACT",
            lambda: adoption.validate_hosted_run(self.root, invalid_artifact),
        )

        for relative in (pairs[0][1], pairs[0][2]):
            path = self.root / relative
            original = path.read_bytes()
            path.write_bytes(original + b"drift")
            self.assert_code(
                "STALE_SOURCE", lambda: adoption.validate_hosted_run(self.root, raw)
            )
            path.write_bytes(original)

    def test_repository_text_digest_is_checkout_line_ending_stable(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "report.json"
            path.write_bytes(b'{\r\n  "status": "PASS"\r\n}\r\n')
            windows_digest = evidence_digest.text_evidence_sha256(path)
            path.write_bytes(b'{\n  "status": "PASS"\n}\n')
            self.assertEqual(windows_digest, evidence_digest.text_evidence_sha256(path))

    def test_desktop_acceptance_column_cannot_be_weakened(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            backlog = (ROOT / "docs/planning/implementation-backlog.md").read_text(
                encoding="utf-8"
            )
            acceptance = adoption.EXPECTED_DESKTOP_ACCEPTANCE["M3-014"]
            backlog = backlog.replace(acceptance, "使用系统证书链与策略")
            path = root / "docs/planning/implementation-backlog.md"
            path.parent.mkdir(parents=True)
            path.write_text(backlog, encoding="utf-8")
            self.assert_code("TASK_GRAPH", lambda: adoption.audit_task_graph(root))

    def test_dependency_evidence_json_preserves_exact_artifact_bytes(self) -> None:
        attributes = (ROOT / ".gitattributes").read_text(encoding="utf-8")
        for task_id in ("M2-004", "M2-006"):
            self.assertIn(f"docs/evidence/{task_id}/*.json -text", attributes)
            self.assertIn(f"docs/evidence/{task_id}/**/*.json -text", attributes)

    def test_missing_core_declaration_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            relative, _ = adoption.CORE_REQUIREMENTS["M3-001"][0]
            path = root / relative
            path.parent.mkdir(parents=True)
            path.write_text("missing", encoding="utf-8")
            self.assert_code("CORE_REQUIREMENT", lambda: adoption.audit_core(root))

    def test_exact_native_desktop_results_pass(self) -> None:
        for platform in ("windows-x86_64", "macos-arm64"):
            with self.subTest(platform=platform):
                raw = provider_result(platform, self.revision, self.spec)
                result_path = materialize_current_license_bundle(
                    platform, raw, self.root, self.spec
                )
                result = self.validate_provider_result(
                    raw, expected_platform=platform, result_path=result_path
                )
                self.assertEqual("PASS", result["status"])
                self.assertEqual(2, result["external_signer_calls"])

    def test_same_length_license_byte_mutation_fails(self) -> None:
        raw = provider_result("windows-x86_64", self.revision, self.spec)
        result_path = materialize_current_license_bundle(
            "windows-x86_64", raw, self.root, self.spec
        )
        license_path = result_path.parent / "license-bundle/files/LICENSE"
        original = license_path.read_bytes()
        license_path.write_bytes(b"S" + original[1:])
        self.assertEqual(len(original), license_path.stat().st_size)
        self.assert_code(
            "LICENSE_BUNDLE",
            lambda: self.validate_provider_result(
                raw,
                expected_platform="windows-x86_64",
                result_path=result_path,
            ),
        )

    def test_provider_license_bundle_is_retained_and_digest_bound(self) -> None:
        raw = provider_result("windows-x86_64", self.revision, self.spec)
        raw["build"]["license_bundle"]["sha256"] = "0" * 64
        self.assert_code(
            "LICENSE_BUNDLE",
            lambda: self.validate_provider_result(
                raw, expected_platform="windows-x86_64"
            ),
        )
        raw = provider_result("macos-arm64", self.revision, self.spec)
        raw["build"]["license_bundle"]["path"] = "../../outside/manifest.json"
        self.assert_code(
            "RAW_RESULT",
            lambda: self.validate_provider_result(
                raw, expected_platform="macos-arm64"
            ),
        )
        missing_result = self.root / "unmaterialized/provider-result.json"
        self.assert_code(
            "LICENSE_BUNDLE",
            lambda: self.validate_provider_result(
                provider_result("windows-x86_64", self.revision, self.spec),
                expected_platform="windows-x86_64",
                result_path=missing_result,
            ),
        )

    def test_stale_revision_is_rejected(self) -> None:
        raw = provider_result("windows-x86_64", "e" * 40, self.spec)
        self.assert_code(
            "STALE_REVISION",
            lambda: self.validate_provider_result(
                raw,
                expected_platform="windows-x86_64",
                expected_revision=self.revision,
            ),
        )

    def test_partial_skipped_and_unknown_schema_never_pass(self) -> None:
        for mutation, expected in (
            (lambda value: value.update({"status": "PARTIAL"}), "INCOMPLETE_RESULT"),
            (lambda value: value.update({"status": "SKIPPED"}), "RAW_RESULT"),
            (lambda value: value.update({"schema_version": 99}), "RAW_RESULT"),
        ):
            raw = provider_result("macos-arm64", self.revision, self.spec)
            mutation(raw)
            self.assert_code(
                expected,
                lambda raw=raw: self.validate_provider_result(
                    raw, expected_platform="macos-arm64"
                ),
            )

    def test_wrong_platform_and_provider_are_rejected(self) -> None:
        raw = provider_result("macos-arm64", self.revision, self.spec)
        self.assert_code(
            "PLATFORM",
            lambda: self.validate_provider_result(
                raw, expected_platform="windows-x86_64"
            ),
        )
        raw = provider_result("windows-x86_64", self.revision, self.spec)
        raw["provider"] = "openssl"
        self.assert_code(
            "PROVIDER",
            lambda: self.validate_provider_result(
                raw, expected_platform="windows-x86_64"
            ),
        )

    def test_failed_poc_wrong_runner_and_source_identity_are_rejected(self) -> None:
        raw = provider_result("windows-x86_64", self.revision, self.spec)
        raw["poc_exit_code"] = 1
        self.assert_code(
            "INCOMPLETE_RESULT",
            lambda: self.validate_provider_result(
                raw, expected_platform="windows-x86_64"
            ),
        )
        raw = provider_result("windows-x86_64", self.revision, self.spec)
        raw["execution"]["image_os"] = "windows-2022"
        result_path = materialize_current_license_bundle(
            "windows-x86_64", raw, self.root, self.spec
        )
        self.assert_code(
            "PLATFORM",
            lambda: self.validate_provider_result(
                raw, expected_platform="windows-x86_64", result_path=result_path
            ),
        )
        raw = provider_result("macos-arm64", self.revision, self.spec)
        raw["source"]["tree"] = "0" * 40
        self.assert_code(
            "PROVIDER",
            lambda: self.validate_provider_result(
                raw, expected_platform="macos-arm64"
            ),
        )

    def test_provider_manifest_cannot_move_the_approved_pin(self) -> None:
        raw = provider_result("macos-arm64", self.revision, self.spec)
        original_load = adoption.load_json

        def moved_manifest(path: Path) -> dict:
            value = original_load(path)
            if path == self.root / "native/tls/aws_lc/provider.json":
                value = copy.deepcopy(value)
                value["provider_version"] = "9.9.9"
            return value

        with mock.patch.object(adoption, "load_json", side_effect=moved_manifest):
            self.assert_code(
                "PROVIDER",
                lambda: self.validate_provider_result(
                    raw, expected_platform="macos-arm64"
                ),
            )

    def test_validate_provider_honors_selected_root(self) -> None:
        raw = provider_result("macos-arm64", self.revision, self.spec)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result_path = materialize_current_license_bundle(
                "macos-arm64", raw, root, self.spec
            )
            manifest_path = root / "native/tls/aws_lc/provider.json"
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            manifest["provider_version"] = "9.9.9"
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
            self.assert_code(
                "PROVIDER",
                lambda: self.validate_provider_result(
                    raw,
                    expected_platform="macos-arm64",
                    result_path=result_path,
                    root=root,
                ),
            )
    def test_atomic_report_replacement_preserves_old_file_on_failure(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "report.json"
            output.write_text('{"old":true}\n', encoding="utf-8")
            with mock.patch.object(adoption.os, "replace", side_effect=OSError("injected")):
                with self.assertRaises(OSError):
                    adoption.atomic_json(output, {"new": True})
            self.assertEqual({"old": True}, json.loads(output.read_text()))
            self.assertEqual([], list(output.parent.glob(f".{output.name}.*.tmp")))


if __name__ == "__main__":
    unittest.main()
