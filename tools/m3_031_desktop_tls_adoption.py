#!/usr/bin/env python3
"""Audit M3 desktop prerequisites and validate exact-revision provider results."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import tempfile
from pathlib import Path
from typing import Any, Mapping, Sequence

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from tools.tls_provider_poc import validate as poc_validate


PINNED_PROVIDER = "aws-lc"
PINNED_PROVIDER_VERSION = "5.5.0"
PINNED_COMMIT = "991e67ff4cf04df4dd89e407f8b920c6936cb56a"
EXPECTED_DESKTOP_DEPENDENCIES = {
    "M3-014": "M2-004,M3-031",
    "M3-015": "M2-006,M3-031",
    "M3-019": "M3-014,M3-031",
    "M3-020": "M3-015,M3-031",
}
ACCEPTANCE_FRAGMENTS = {
    "M3-014": "使用系统证书链与策略",
    "M3-015": "使用系统信任评估",
    "M3-019": "系统 key handle 可完成 client/server 签名",
    "M3-020": "SecKey 签名桥通过",
}
MOBILE_GRAPH_FRAGMENTS = (
    "| M4-001 | 实现 Android system/app trust adapter | 平台 | C4 | M3-009..M3-012,M2-007 |",
    "| M4-002 | 实现 Android Keystore external signer | 平台 | C4 | M3-016,M3-018 |",
    "| M4-005 | 实现 iOS system trust adapter | 平台 | C4 | M3-009..M3-012,M2-006 |",
    "| M4-006 | 实现 iOS Keychain/SecKey signer | 平台 | C4 | M3-016,M3-018 |",
    "| M4-009 | 实现 HarmonyOS/OHOS system trust adapter | 平台 | C4 | M3-009..M3-012,M2-008 |",
    "| M4-010 | 实现 Harmony system key external signer | 平台 | C4 | M3-016,M3-018 |",
    "| M4-014 | 建立三平台真机 CI 与 capability matrix |",
)
CORE_REQUIREMENTS: dict[str, tuple[tuple[str, str], ...]] = {
    "M3-001": (
        ("native/tls/aws_lc/provider.json", '"provider_version": "5.5.0"'),
        ("tools/tls_provider/selection.json", '"default_provider": "aws-lc"'),
    ),
    "M3-002": (
        ("src/internal/tls_engine/package.cj", "public interface TlsProvider"),
        ("src/internal/tls_engine/package.cj", "public struct TlsProviderManifest"),
    ),
    "M3-006": (
        ("src/internal/tls_engine/context.cj", "public class TlsClientContextBuilder"),
        ("src/internal/tls_engine/context.cj", "public class TlsServerContextBuilder"),
        ("src/internal/tls_engine/context_test.cj", "missingTls13AndHttp2CapabilitiesFailBeforeHandshake"),
    ),
    "M3-009": (
        ("src/trust.cj", "public class TrustPolicy"),
        ("src/trust.cj", "public struct TrustVerificationEvidence"),
    ),
    "M3-010": (
        ("src/trust.cj", "HARD_MAXIMUM_CHAIN_LENGTH"),
        ("src/internal/trust/trust_test.cj", "certificateAndChainLimitsFailBeforeUnboundedParsingOrCopying"),
        ("src/internal/tls_engine/m3_028_fuzz_test.cj", "certificateAdapterMutationsHaveDeterministicTypedTerminals"),
    ),
    "M3-011": (
        ("src/hostname_verifier.cj", "public class HostnameVerifier"),
        ("src/internal/trust/hostname_test.cj", "dnsAndIpReferenceIdentitiesNeverCrossMatch"),
        ("src/internal/trust/hostname_test.cj", "wildcardMatchesExactlyOneLeftmostLabelOnly"),
    ),
    "M3-012": (
        ("src/trust.cj", "SystemPlusCustomRoots"),
        ("src/trust.cj", "PinnedPublicKeys"),
        ("src/internal/tls_engine/engine_pump_test.cj", "matchingSpkiPinDoesNotBypassReferenceIdentityVerification"),
    ),
    "M3-016": (
        ("src/internal/tls_engine/identity.cj", "public class PrivateKeyRef"),
        ("src/internal/tls_engine/identity.cj", "public class LocalIdentity"),
        ("src/internal/tls_engine/identity_test.cj", "externalSignerAndSystemHandleShareOneOpaqueKeyContract"),
    ),
    "M3-018": (
        ("src/internal/tls_engine/engine.cj", "public interface ExternalSigningTlsEngine"),
        ("src/internal/tls_engine/engine_pump_test.cj", "externalSignerCompletesARealHandshakeOutsideTheNativeCallback"),
        ("src/internal/tls_engine/engine_pump_test.cj", "externalSignerExceptionFailsClosedWithoutCrossingTheCAbi"),
        ("src/internal/tls_engine/engine_pump_test.cj", "cancellationBeforeSignerInvocationFailsThePendingNativeOperation"),
    ),
}
RETAINED_EVIDENCE = (
    "docs/evidence/M3-028/README.md",
    "docs/evidence/M3-030/README.md",
    "docs/evidence/M3-030/native-abi-report.json",
    "docs/evidence/M3-030/test-provider-results.json",
)
EXCLUDED_GLOBAL_CONDITIONS = (
    {
        "task_id": "M3-001",
        "condition": "six-platform target build",
        "disposition": "NOT_EVALUATED",
        "owner": "historical global task",
    },
    {
        "task_id": "M3-001..M3-018",
        "condition": "mobile simulator or native-device acceptance",
        "disposition": "NOT_EVALUATED",
        "owner": "historical global or M4 task",
    },
)


class AdoptionError(RuntimeError):
    def __init__(self, code: str, detail: str) -> None:
        super().__init__(detail)
        self.code = code
        self.detail = detail


def sha256_path(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise AdoptionError("MISSING_INPUT", str(path)) from error
    except (OSError, json.JSONDecodeError) as error:
        raise AdoptionError("INVALID_JSON", str(path)) from error
    if not isinstance(value, dict):
        raise AdoptionError("UNKNOWN_SCHEMA", f"{path}: root must be an object")
    return value


def atomic_json(path: Path, value: Mapping[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.", suffix=".tmp", dir=path.parent
    )
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as stream:
            json.dump(value, stream, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary_name, path)
    finally:
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass


def _require_text(root: Path, relative: str, needle: str) -> str:
    path = root / relative
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as error:
        raise AdoptionError("CORE_REQUIREMENT", f"{relative}: missing") from error
    if needle not in text:
        raise AdoptionError("CORE_REQUIREMENT", f"{relative}: missing required declaration")
    return sha256_path(path)


def _backlog_row(backlog: str, task_id: str) -> str:
    prefix = f"| {task_id} |"
    rows = [line for line in backlog.splitlines() if line.startswith(prefix)]
    if len(rows) != 1:
        raise AdoptionError("TASK_GRAPH", f"{task_id}: expected one backlog row")
    return rows[0]


def audit_task_graph(root: Path) -> dict[str, Any]:
    backlog_path = root / "docs/planning/implementation-backlog.md"
    try:
        backlog = backlog_path.read_text(encoding="utf-8")
    except OSError as error:
        raise AdoptionError("TASK_GRAPH", str(backlog_path)) from error
    desktop: dict[str, Any] = {}
    for task_id, dependencies in EXPECTED_DESKTOP_DEPENDENCIES.items():
        row = _backlog_row(backlog, task_id)
        columns = [part.strip() for part in row.strip("|").split("|")]
        if len(columns) < 7 or columns[4] != dependencies:
            raise AdoptionError("TASK_GRAPH", f"{task_id}: dependency mismatch")
        fragment = ACCEPTANCE_FRAGMENTS[task_id]
        if fragment not in row:
            raise AdoptionError("TASK_GRAPH", f"{task_id}: acceptance text changed")
        desktop[task_id] = {"dependencies": dependencies, "status": "PASS"}
    for fragment in MOBILE_GRAPH_FRAGMENTS:
        if fragment not in backlog:
            raise AdoptionError("MOBILE_GRAPH_DRIFT", fragment[:80])
    return {
        "desktop": desktop,
        "mobile_rows_checked": len(MOBILE_GRAPH_FRAGMENTS),
        "status": "PASS",
    }


def audit_core(root: Path) -> dict[str, Any]:
    root = root.resolve()
    source_sha256: dict[str, str] = {}
    prerequisites: dict[str, Any] = {}
    for task_id, requirements in CORE_REQUIREMENTS.items():
        paths: list[str] = []
        for relative, needle in requirements:
            source_sha256[relative] = _require_text(root, relative, needle)
            paths.append(relative)
        prerequisites[task_id] = {
            "scope": "desktop-applicable-contract",
            "paths": sorted(set(paths)),
            "status": "PASS",
        }
    for relative in RETAINED_EVIDENCE:
        path = root / relative
        if not path.is_file():
            raise AdoptionError("CORE_REQUIREMENT", f"{relative}: retained evidence missing")
        source_sha256[relative] = sha256_path(path)
    graph = audit_task_graph(root)
    backlog_relative = "docs/planning/implementation-backlog.md"
    source_sha256[backlog_relative] = sha256_path(root / backlog_relative)
    return {
        "schema_version": 1,
        "task_id": "M3-031",
        "kind": "provider-neutral-core-adoption",
        "status": "PASS",
        "prerequisites": prerequisites,
        "excluded_global_conditions": list(EXCLUDED_GLOBAL_CONDITIONS),
        "historical_task_status_changed": False,
        "retained_evidence": list(RETAINED_EVIDENCE),
        "source_sha256": dict(sorted(source_sha256.items())),
        "task_graph": graph,
        "boundary": "Only the desktop-applicable contract is audited. Global six-platform and mobile conditions are not evaluated, and no desktop trust or system-key adapter is implemented.",
    }


def validate_provider_result(
    raw: Mapping[str, Any], *, expected_platform: str, expected_revision: str
) -> dict[str, Any]:
    if len(expected_revision) != 40 or any(value not in "0123456789abcdef" for value in expected_revision):
        raise AdoptionError("STALE_REVISION", "expected revision must be an exact lowercase SHA")
    spec = load_json(ROOT / "tools/tls_provider_poc/providers.json")
    try:
        poc_validate.validate_result(raw, spec, expected_revision)
    except poc_validate.ValidationError as error:
        detail = str(error)
        code = "STALE_REVISION" if "revision" in detail else "RAW_RESULT"
        raise AdoptionError(code, detail) from error
    if raw.get("provider") != PINNED_PROVIDER:
        raise AdoptionError("PROVIDER", str(raw.get("provider")))
    if raw.get("platform") != expected_platform:
        raise AdoptionError("PLATFORM", str(raw.get("platform")))
    if raw.get("status") != "PASS":
        raise AdoptionError("INCOMPLETE_RESULT", str(raw.get("status")))
    if raw.get("schema_version") != 2:
        raise AdoptionError("UNKNOWN_SCHEMA", str(raw.get("schema_version")))
    source = raw.get("source")
    if not isinstance(source, dict) or source.get("commit") != PINNED_COMMIT:
        raise AdoptionError("PROVIDER", "AWS-LC source commit mismatch")
    capabilities = raw.get("capabilities")
    if not isinstance(capabilities, dict) or any(value != "PASS" for value in capabilities.values()):
        raise AdoptionError("INCOMPLETE_RESULT", "every capability must be PASS")
    execution = raw.get("execution")
    if not isinstance(execution, dict):
        raise AdoptionError("PLATFORM", "execution metadata missing")
    if expected_platform == "windows-x86_64":
        if execution.get("runner_os") != "Windows" or str(execution.get("runner_arch", "")).upper() not in {"X64", "AMD64"}:
            raise AdoptionError("PLATFORM", "native Windows x86_64 runner required")
    elif expected_platform == "macos-arm64":
        if execution.get("runner_os") not in {"macOS", "Darwin"} or str(execution.get("runner_arch", "")).lower() not in {"arm64", "aarch64"}:
            raise AdoptionError("PLATFORM", "native macOS arm64 runner required")
    return {
        "schema_version": 1,
        "task_id": "M3-031",
        "platform": expected_platform,
        "provider": PINNED_PROVIDER,
        "provider_version": PINNED_PROVIDER_VERSION,
        "repository_revision": expected_revision,
        "capabilities": capabilities,
        "external_signer_calls": raw.get("metrics", {}).get("external_signer_calls"),
        "repeated_cleanup_cycles": raw.get("metrics", {}).get("repeated_cleanup_cycles"),
        "status": "PASS",
    }


def aggregate(
    core: Mapping[str, Any], windows: Mapping[str, Any], macos: Mapping[str, Any],
    expected_revision: str
) -> dict[str, Any]:
    if core.get("schema_version") != 1 or core.get("status") != "PASS":
        raise AdoptionError("CORE_REQUIREMENT", "Core audit is not PASS")
    win = validate_provider_result(
        windows, expected_platform="windows-x86_64", expected_revision=expected_revision
    )
    mac = validate_provider_result(
        macos, expected_platform="macos-arm64", expected_revision=expected_revision
    )
    return {
        "schema_version": 1,
        "task_id": "M3-031",
        "repository_revision": expected_revision,
        "selection": {
            "windows-x86_64": {"provider": PINNED_PROVIDER, "status": "PASS"},
            "macos-arm64": {"provider": PINNED_PROVIDER, "status": "PASS"},
        },
        "provider_results": [win, mac],
        "runtime_fallback": False,
        "status": "PASS",
    }


def _write_or_print(value: Mapping[str, Any], output: Path | None) -> None:
    if output is not None:
        atomic_json(output, value)
    print(json.dumps(value, sort_keys=True))


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    sub = parser.add_subparsers(dest="command", required=True)
    core_parser = sub.add_parser("audit-core")
    core_parser.add_argument("--output", type=Path)
    provider = sub.add_parser("validate-provider")
    provider.add_argument("--input", type=Path, required=True)
    provider.add_argument("--platform", choices=["windows-x86_64", "macos-arm64"], required=True)
    provider.add_argument("--expected-revision", required=True)
    provider.add_argument("--output", type=Path)
    matrix = sub.add_parser("aggregate")
    matrix.add_argument("--core", type=Path, required=True)
    matrix.add_argument("--windows", type=Path, required=True)
    matrix.add_argument("--macos", type=Path, required=True)
    matrix.add_argument("--expected-revision", required=True)
    matrix.add_argument("--output", type=Path)
    args = parser.parse_args(argv)
    try:
        if args.command == "audit-core":
            value = audit_core(args.root)
        elif args.command == "validate-provider":
            raw = load_json(args.input)
            value = validate_provider_result(
                raw, expected_platform=args.platform,
                expected_revision=args.expected_revision,
            )
        else:
            value = aggregate(
                load_json(args.core), load_json(args.windows), load_json(args.macos),
                args.expected_revision,
            )
        _write_or_print(value, args.output)
        return 0
    except AdoptionError as error:
        print(json.dumps({"code": error.code, "detail": error.detail[:2048], "status": "FAIL"}, sort_keys=True))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
