#!/usr/bin/env python3
"""Audit M3 desktop prerequisites and validate exact-revision provider results."""

from __future__ import annotations

if __package__ in {None, ""}:
    import sys
    from pathlib import Path
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tools import evidence_digest

import argparse
import datetime as dt
import json
import math
import os
import re
import sys
import tempfile
import uuid
from pathlib import Path
from typing import Any, Mapping, Sequence

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from tools import development_baseline
from tools import m7_021_linux_release as linux_release
from tools.tls_provider_poc import validate as poc_validate
from tools.repository import repository_tooling
from tools.gates import m2_004_windows_resolver, m2_006_apple_resolver
from tools.tls_provider.selection import (
    archive_symbols,
    expected_symbols,
    select_provider,
    validate_native_header_signatures,
    validate_symbol_set,
)

PINNED_PROVIDER = "aws-lc"
PINNED_PROVIDER_VERSION = "5.5.0"
PINNED_COMMIT = "991e67ff4cf04df4dd89e407f8b920c6936cb56a"
PROVIDER_RESULT_SCHEMA_VERSION = poc_validate.RESULT_SCHEMA_VERSION
EXPECTED_RUNNER_IMAGES = {
    "windows-x86_64": "win25-vs2026",
    "macos-arm64": "macos15",
}
EXPECTED_DESKTOP_DEPENDENCIES = {
    "M3-014": "M2-004,M3-031",
    "M3-015": "M2-006,M3-031",
    "M3-019": "M3-014,M3-031",
    "M3-020": "M3-015,M3-031",
}
EXPECTED_DESKTOP_ACCEPTANCE = {
    "M3-014": "使用系统证书链与策略；返回 identity/chain 证据；不导出 native provider 对象。",
    "M3-015": "使用系统信任评估；行为、错误、证据与统一模型对齐。",
    "M3-019": "系统 key handle 可完成 client/server 签名；私钥不导出；错误和取消稳定。",
    "M3-020": "SecKey 签名桥通过；私钥不导出；生命周期与线程/回调安全。",
}
MOBILE_GRAPH_ROWS = {
    "M4-001": "| M4-001 | 实现 Android system/app trust adapter | 平台 | C4 | M3-009..M3-012,M2-007 | PRD §14.2 | 系统和应用 trust 配置可用；reference identity 不被关闭；结果映射统一。 |",
    "M4-002": "| M4-002 | 实现 Android Keystore external signer | 平台 | C4 | M3-016,M3-018 | PRD §13.6/§14.2 | alias/key handle 可签名且不可导出；算法、取消、生命周期和错误通过真机测试。 |",
    "M4-003": "| M4-003 | 完成 Android TLS/HTTPS client 集成 | 平台 | C4 | M4-001,M4-002,M3-021..M3-027 | PRD M4 | TLS1.2/1.3、ALPN、system/custom trust、mTLS、session 在真机通过。 |",
    "M4-004": "| M4-004 | 完成 Android 前后台与网络切换验证 | 平台 | C4 | M4-003,M0-012 | GATE-NET-07 | 页面退出取消、Wi-Fi/蜂窝/飞行模式/休眠恢复可诊断；旧连接与 network binding 无泄漏。 |",
    "M4-005": "| M4-005 | 实现 iOS system trust adapter | 平台 | C4 | M3-009..M3-012,M2-006 | PRD §14.2 | 系统 trust 与自定义 roots 组合行为明确；identity 证据统一。 |",
    "M4-006": "| M4-006 | 实现 iOS Keychain/SecKey signer | 平台 | C4 | M3-016,M3-018 | PRD §13.6/§14.2 | 不可导出 key 完成签名；回调、取消、线程和生命周期安全。 |",
    "M4-007": "| M4-007 | 完成 iOS TLS/HTTPS client 集成 | 平台 | C4 | M4-005,M4-006,M3-021..M3-027 | PRD M4 | TLS1.2/1.3、ALPN、trust、mTLS、session 在真机通过。 |",
    "M4-008": "| M4-008 | 完成 iOS 前后台与网络切换验证 | 平台 | C4 | M4-007,M0-012 | GATE-NET-07 | 应用生命周期、Wi-Fi/蜂窝/飞行模式、cancel/Deadline 无泄漏且错误可诊断。 |",
    "M4-009": "| M4-009 | 实现 HarmonyOS/OHOS system trust adapter | 平台 | C4 | M3-009..M3-012,M2-008 | PRD §14.2 | 系统 trust、自定义 roots、reference identity 和结构化证据在真机通过。 |",
    "M4-010": "| M4-010 | 实现 Harmony system key external signer | 平台 | C4 | M3-016,M3-018 | PRD §13.6/§14.2 | 不可导出 key handle 完成签名；错误、取消、生命周期一致。 |",
    "M4-011": "| M4-011 | 完成 Harmony TLS/HTTPS client/server 集成 | 平台 | C4 | M4-009,M4-010,M3-021..M3-027 | PRD §14.2/M4 | client P0 和 server P0 均通过；ALPN/SNI/mTLS/session 可用。 |",
    "M4-012": "| M4-012 | 完成 Harmony 网络切换与生命周期验证 | 平台 | C4 | M4-011,M0-012 | GATE-NET-07 | 断网/恢复、切网、前后台、休眠无旧绑定泄漏；新连接可重新解析选路。 |",
    "M4-013": "| M4-013 | 实现 Android/iOS 前台基础 `TlsListener` 能力 | 平台 | C4 | M1-021,M3-022,M4-003,M4-007 | PRD §4 G-003/§14.2 | 明确前台限制；accept/cancel/close/SNI 基础测试通过；不宣称后台常驻能力。 |",
    "M4-014": "| M4-014 | 建立三平台真机 CI 与 capability matrix | 基础设施 | C4 | M4-003..M4-013 | PRD §14.3/§21.5 | 每次发布可运行 client、key、trust、network-change、listener 门禁；输出只读能力矩阵。 |",
}
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
    "docs/evidence/M3-030/architecture-guard.json",
    "docs/evidence/M3-030/clean-consumer.json",
    "docs/evidence/M3-030/linux-aws-lc-results.json",
    "docs/evidence/M3-030/native-abi-report.json",
    "docs/evidence/M3-030/platform-provider-matrix.json",
    "docs/evidence/M3-030/release-validation.json",
    "docs/evidence/M3-030/sbom-validation.json",
    "docs/evidence/M3-030/task-check.json",
    "docs/evidence/M3-030/test-provider-results.json",
)
HISTORICAL_REFERENCES = ("docs/evidence/M3-028/README.md",)
HOSTED_INPUT_PATHS = (
    "tools/tls_provider_poc/openssl_memory_poc.c",
    "tools/tls_provider_poc/providers.json",
    "tools/tls_provider_poc/run.py",
    "tools/tls_provider_poc/validate.py",
)
CURRENT_CORE_KIND = "current-provider-neutral-core"
CURRENT_CORE_RELATIVE = "docs/evidence/M3-031/current-core/qualification.json"
CURRENT_CORE_FIELDS = {
    "schema_version", "source_task", "task_id", "kind", "status", "revision",
    "platform", "production_sources", "execution_inputs", "sdk", "selection",
    "native_archive", "commands", "logs", "installed_consumer", "release",
}
CURRENT_CORE_COMMANDS = (
    {
        "id": "provider-build",
        "argv": ["python3", "tools/build_tls_provider.py", "--offline", "--json"],
        "timeout_seconds": 1200,
    },
    {
        "id": "architecture-guard",
        "argv": [
            "python3", "tools/architecture_guard.py", "--root", ".", "--format", "json",
        ],
        "timeout_seconds": 120,
    },
    {
        "id": "provider-substitution",
        "argv": [
            "cjpm", "test", "--filter=TlsProviderSubstitutionTest",
            "--exclude-tags=Performance", "--parallel", "1", "--no-progress",
            "--no-color", "src/internal/tls_engine",
        ],
        "timeout_seconds": 300,
    },
    {
        "id": "installed-consumer",
        "argv": [
            "python3", "tools/m7_021_linux_release.py", "--root", ".",
            "--output-dir", "dist/m3-031-current-core", "--offline",
        ],
        "timeout_seconds": 600,
    },
)
CURRENT_CORE_COMMAND_FIELDS = {
    "id", "argv", "status", "exit_code", "timed_out", "duration_ms",
    "started_at_utc", "finished_at_utc",
}
CURRENT_CORE_CASES = (
    "testProviderUsesTheProductionFactoryContract",
    "objectsFromDifferentProviderInstancesCannotMix",
    "activeEngineRetainsProviderUntilItCloses",
)
CURRENT_CORE_INSTALLED_QUALIFICATION = "dist/m3-031-current-core/qualification.json"
CURRENT_CORE_ARTIFACT = f"dist/m3-031-current-core/{linux_release.ARTIFACT_NAME}"
CURRENT_CORE_NATIVE_ARCHIVE = "target/native/current/lib/libwirestack_tls_provider.a"
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
CURRENT_DESKTOP_RESOLVER_EVIDENCE = {
    "M2-004": {
        "report": (
            "docs/evidence/M2-004/current-desktop/windows-x86_64/report.json"
        ),
        "validation": (
            "docs/evidence/M2-004/current-desktop/windows-x86_64/validation.json"
        ),
        "pin": "docs/references/m2-004-sts-sdk.json",
        "platform": "windows-x86_64",
    },
    "M2-006": {
        "report": (
            "docs/evidence/M2-006/current-desktop/macos-arm64/report.json"
        ),
        "validation": (
            "docs/evidence/M2-006/current-desktop/macos-arm64/validation.json"
        ),
        "pin": "docs/references/m2-006-sts-sdk.json",
        "platform": "macos-arm64",
    },
}
CURRENT_DESKTOP_LOG_IDS = {
    "M2-004": {
        "resolver_build": "docs/evidence/M2-004/current-desktop/windows-x86_64/logs/resolver-build.log",
        "link_stub_compile": "docs/evidence/M2-004/current-desktop/windows-x86_64/logs/test-link-stub-compile.log",
        "link_stub_archive": "docs/evidence/M2-004/current-desktop/windows-x86_64/logs/test-link-stub-archive.log",
        "resolver_test": "docs/evidence/M2-004/current-desktop/windows-x86_64/logs/resolver-tests.log",
        "cjc_version": "docs/evidence/M2-004/current-desktop/windows-x86_64/logs/cjc-version.log",
        "cjpm_version": "docs/evidence/M2-004/current-desktop/windows-x86_64/logs/cjpm-version.log",
    },
    "M2-006": {
        "resolver-build": "logs/resolver-build.log",
        "test-link-stub-compile": "logs/test-link-stub-compile.log",
        "test-link-stub-archive": "logs/test-link-stub-archive.log",
        "resolver-test": "logs/resolver-test.log",
        "toolchain-version": "logs/toolchain-version.log",
    },
}


class AdoptionError(RuntimeError):
    def __init__(self, code: str, detail: str) -> None:
        super().__init__(detail)
        self.code = code
        self.detail = detail


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


def require_complete_status(root: Path, task_id: str, error_code: str) -> None:
    status_path = root / "docs/planning/status.md"
    try:
        status_text = status_path.read_text(encoding="utf-8")
    except OSError as error:
        raise AdoptionError(error_code, "status file missing") from error
    status_rows = [
        line for line in status_text.splitlines()
        if line.startswith(f"| {task_id} |")
    ]
    if len(status_rows) != 1:
        raise AdoptionError(error_code, f"{task_id}: status row")
    status_columns = [part.strip() for part in status_rows[0].strip("|").split("|")]
    if len(status_columns) < 2 or status_columns[1] != "COMPLETE":
        raise AdoptionError(error_code, f"{task_id}: status is not COMPLETE")


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
    return evidence_digest.text_evidence_sha256(path)


def _backlog_row(backlog: str, task_id: str) -> str:
    prefix = f"| {task_id} |"
    rows = [line for line in backlog.splitlines() if line.startswith(prefix)]
    if len(rows) != 1:
        raise AdoptionError("TASK_GRAPH", f"{task_id}: expected one backlog row")
    return rows[0]


def hosted_input_sha256(root: Path) -> dict[str, str]:
    return {
        relative: evidence_digest.text_evidence_sha256(root / relative)
        for relative in HOSTED_INPUT_PATHS
    }


def validate_hosted_run(root: Path, raw: Mapping[str, Any]) -> dict[str, Any]:
    if raw.get("schema_version") != 2 or raw.get("task_id") != "M3-031":
        raise AdoptionError("UNKNOWN_SCHEMA", "hosted-run schema or task mismatch")
    if raw.get("status") != "PASS" or raw.get("conclusion") != "success":
        raise AdoptionError("INCOMPLETE_RESULT", "hosted-run is not successful")
    revision = raw.get("revision")
    if not isinstance(revision, str) or re.fullmatch(r"[0-9a-f]{40}", revision) is None:
        raise AdoptionError("STALE_REVISION", "hosted-run revision is not an exact SHA")
    try:
        expected = hosted_input_sha256(root)
    except (OSError, evidence_digest.DigestError) as error:
        raise AdoptionError("HOSTED_INPUT", "hosted source input is missing or invalid") from error
    if not evidence_digest.schema_text_sha256_map_equal(raw.get("source_sha256"), expected):
        raise AdoptionError("STALE_SOURCE", "hosted provider inputs differ from retained run")
    artifacts = raw.get("artifacts")
    if not isinstance(artifacts, list) or len(artifacts) != 2:
        raise AdoptionError("INCOMPLETE_RESULT", "hosted-run requires two native artifacts")
    expected_artifacts = {
        f"m3-031-windows-x86_64-{revision}": (
            "docs/evidence/M3-031/windows-x86_64/provider-result.json",
            "docs/evidence/M3-031/windows-x86_64/validation.json",
        ),
        f"m3-031-macos-arm64-{revision}": (
            "docs/evidence/M3-031/macos-arm64/provider-result.json",
            "docs/evidence/M3-031/macos-arm64/validation.json",
        ),
    }
    by_name = {
        item.get("name"): item for item in artifacts if isinstance(item, dict)
    }
    if set(by_name) != set(expected_artifacts):
        raise AdoptionError("STALE_REVISION", "hosted artifacts are not bound to revision")
    artifact_fields = {
        "artifact_id", "archive_digest", "expires_at", "name",
        "provider_result_sha256", "validation_sha256",
    }
    for name, (result_relative, validation_relative) in expected_artifacts.items():
        artifact = by_name[name]
        expires_at = artifact.get("expires_at")
        try:
            expiry = dt.datetime.fromisoformat(
                str(expires_at).replace("Z", "+00:00")
            )
        except ValueError as error:
            raise AdoptionError("HOSTED_ARTIFACT", f"{name}: expiry timestamp") from error
        if (
            set(artifact) != artifact_fields
            or type(artifact.get("artifact_id")) is not int
            or artifact["artifact_id"] <= 0
            or re.fullmatch(r"sha256:[0-9a-f]{64}", str(artifact.get("archive_digest", "")))
            is None
            or expiry.tzinfo is None
            or expiry.utcoffset() != dt.timedelta(0)
        ):
            raise AdoptionError("HOSTED_ARTIFACT", f"{name}: artifact API metadata")
        try:
            result_digest = evidence_digest.text_evidence_sha256(
                root / result_relative
            )
            validation_digest = evidence_digest.text_evidence_sha256(
                root / validation_relative
            )
        except (OSError, evidence_digest.DigestError) as error:
            raise AdoptionError(
                "HOSTED_ARTIFACT", f"{name}: retained result or validation is missing"
            ) from error
        if (
            not evidence_digest.schema_text_sha256_equal(
                artifact.get("provider_result_sha256"), result_digest
            )
            or not evidence_digest.schema_text_sha256_equal(
                artifact.get("validation_sha256"), validation_digest
            )
        ):
            raise AdoptionError(
                "STALE_SOURCE", f"{name}: retained files differ from hosted artifact"
            )
    return {
        "schema_version": 1,
        "task_id": "M3-031",
        "revision": revision,
        "source_sha256": expected,
        "status": "PASS",
    }




def validate_historical_core_evidence(root: Path) -> dict[str, Any]:
    require_complete_status(root, "M3-030", "RETAINED_EVIDENCE")
    try:
        task = repository_tooling.load_task(root / "tools/tasks/M3-030.json", root)
    except repository_tooling.ContractError as error:
        raise AdoptionError(
            "RETAINED_EVIDENCE", f"M3-030 task contract: {error.code}"
        ) from error
    evidence_relative = "docs/evidence/M3-030/evidence.json"
    evidence = load_json(root / evidence_relative)
    if evidence.get("schema_version") != 1 or evidence.get("source_task") != "M3-030":
        raise AdoptionError("RETAINED_EVIDENCE", "M3-030 evidence index identity is invalid")
    if evidence.get("acceptance_status") != "PASS":
        raise AdoptionError("RETAINED_EVIDENCE", "M3-030 evidence is not PASS")
    reports = evidence.get("reports")
    if not isinstance(reports, list):
        raise AdoptionError("RETAINED_EVIDENCE", "M3-030 reports are missing")
    by_path = {
        item.get("path"): item for item in reports if isinstance(item, dict)
    }
    expected_reports = set(task["required_evidence"]) - {evidence_relative}
    if (
        evidence_relative not in task["required_evidence"]
        or expected_reports != set(RETAINED_EVIDENCE)
        or len(reports) != len(expected_reports)
        or set(by_path) != expected_reports
    ):
        raise AdoptionError(
            "RETAINED_EVIDENCE", "M3-030 required report inventory is incomplete"
        )
    for relative in sorted(expected_reports):
        entry = by_path.get(relative)
        if not isinstance(entry, dict):
            raise AdoptionError("RETAINED_EVIDENCE", f"{relative}: absent from evidence index")
        if entry.get("source_task") != "M3-030" or entry.get("acceptance_status") != "PASS":
            raise AdoptionError("RETAINED_EVIDENCE", f"{relative}: index does not record PASS")
        try:
            path = repository_tooling.safe_path(
                root, relative, "M3-030 report", must_exist=True, file_only=True
            )
        except repository_tooling.ContractError as error:
            raise AdoptionError("RETAINED_EVIDENCE", f"{relative}: {error.code}") from error
        if not evidence_digest.schema_text_sha256_equal(
            entry.get("sha256"), evidence_digest.text_evidence_sha256(path)
        ):
            raise AdoptionError("STALE_SOURCE", f"{relative}: report digest changed")
        payload = load_json(path)
        payload_task = payload.get("source_task", payload.get("task_id"))
        if payload_task != "M3-030" or payload.get("status") != "PASS":
            raise AdoptionError(
                "RETAINED_EVIDENCE", f"{relative}: historical report identity or status"
            )

    source_sha256 = evidence.get("source_sha256")
    expected_paths = set(task["source_paths"])
    if not isinstance(source_sha256, dict) or set(source_sha256) != expected_paths:
        raise AdoptionError("RETAINED_EVIDENCE", "M3-030 source inventory is incomplete")
    recorded: dict[str, str] = {}
    current: dict[str, str] = {}
    for relative, expected in source_sha256.items():
        if not isinstance(expected, str) or re.fullmatch(r"[0-9a-f]{64}", expected) is None:
            raise AdoptionError("RETAINED_EVIDENCE", f"{relative}: invalid retained digest")
        try:
            path = repository_tooling.safe_path(
                root, relative, "M3-030 source", must_exist=True, file_only=True
            )
        except repository_tooling.ContractError as error:
            raise AdoptionError("STALE_SOURCE", f"{relative}: {error.code}") from error
        recorded[relative] = expected
        current[relative] = evidence_digest.text_evidence_sha256(path)
    return {
        "task_id": "M3-030",
        "kind": "historical-core-evidence-integrity",
        "reports": sorted(expected_reports),
        "report_count": len(expected_reports),
        "recorded_source_sha256": dict(sorted(recorded.items())),
        "source_sha256": dict(sorted(current.items())),
        "changed_since_m3_030": sorted(
            relative for relative in expected_paths
            if recorded[relative] != current[relative]
        ),
        "qualification": "HISTORICAL_ONLY",
        "status": "HISTORICAL",
    }


def _historical_core_diagnostic(root: Path) -> dict[str, Any]:
    try:
        return validate_historical_core_evidence(root)
    except AdoptionError as error:
        return {
            "task_id": "M3-030",
            "kind": "historical-core-evidence-integrity",
            "status": "HISTORICAL",
            "integrity_status": "STALE" if error.code == "STALE_SOURCE" else "FAIL",
            "code": error.code,
            "detail": development_baseline.redact(error.detail, root)[:1024],
        }


def baseline_sdk_archive(value: Path | None = None) -> Path:
    if value is not None:
        return value.resolve()
    configured = os.environ.get("WIRESTACK_BASELINE_SDK_ARCHIVE")
    if not configured:
        raise AdoptionError(
            "SDK_IDENTITY", "WIRESTACK_BASELINE_SDK_ARCHIVE is required"
        )
    return Path(configured).resolve()


def _current_core_selection(selected: Any) -> dict[str, Any]:
    capabilities = selected.manifest.get("capabilities")
    abi = selected.manifest.get("abi")
    if (
        not isinstance(capabilities, list)
        or any(not isinstance(item, str) or not item for item in capabilities)
        or len(capabilities) != len(set(capabilities))
        or not isinstance(abi, dict)
        or not isinstance(abi.get("version"), int)
    ):
        raise AdoptionError("CURRENT_CORE_SELECTION", "provider capability or ABI inventory")
    return {
        "platform": selected.platform,
        "provider": selected.provider,
        "adapter": selected.adapter,
        "fingerprint": selected.fingerprint,
        "capabilities": capabilities,
        "abi_version": abi["version"],
        "abi_symbols": sorted(expected_symbols(selected)),
    }


def _current_core_expected_log_names() -> set[str]:
    return {
        f"{item['id']}.{stream}.log"
        for item in CURRENT_CORE_COMMANDS
        for stream in ("stdout", "stderr")
    } | {"installed-consumer.qualification.log"}


def _current_core_logs(root: Path, records: Any) -> dict[str, str]:
    if not isinstance(records, list) or len(records) != 9:
        raise AdoptionError("CURRENT_CORE_LOGS", "exactly nine retained logs are required")
    paths: dict[str, str] = {}
    run_id: str | None = None
    prefix = "docs/evidence/M3-031/current-core/runs/"
    expected_names = _current_core_expected_log_names()
    for record in records:
        if not isinstance(record, dict) or set(record) != {"path", "digest"}:
            raise AdoptionError("CURRENT_CORE_LOGS", "log record fields")
        relative = record.get("path")
        if not isinstance(relative, str) or not relative.startswith(prefix):
            raise AdoptionError("CURRENT_CORE_LOGS", "log path is outside current-core runs")
        parts = Path(relative).parts
        if (
            len(parts) != 8
            or parts[:4] != ("docs", "evidence", "M3-031", "current-core")
            or parts[4] != "runs"
            or re.fullmatch(r"[0-9a-f]{32}", parts[5]) is None
            or parts[6] != "commands"
        ):
            raise AdoptionError("CURRENT_CORE_LOGS", "log path layout")
        if run_id is None:
            run_id = parts[5]
        elif run_id != parts[5]:
            raise AdoptionError("CURRENT_CORE_LOGS", "logs span multiple capture runs")
        name = Path(relative).name
        if name not in expected_names or name in paths:
            raise AdoptionError("CURRENT_CORE_LOGS", "missing, duplicate, or unknown log")
        try:
            path = repository_tooling.safe_path(
                root, relative, "current Core log", must_exist=True, file_only=True
            )
            observed = evidence_digest.text_evidence_digest(path).to_json()
            text = path.read_text(encoding="utf-8")
        except (repository_tooling.ContractError, OSError, UnicodeError, evidence_digest.DigestError) as error:
            raise AdoptionError("CURRENT_CORE_LOGS", f"{name}: {type(error).__name__}") from error

        if observed != record.get("digest"):
            raise AdoptionError("STALE_SOURCE", f"{name}: retained log digest changed")
        paths[name] = text
    if set(paths) != expected_names:
        raise AdoptionError("CURRENT_CORE_LOGS", "required command or consumer log is missing")
    return paths


def _current_core_log_path(run_id: str, name: str) -> str:
    return f"docs/evidence/M3-031/current-core/runs/{run_id}/commands/{name}"


def _current_core_command_record(result: Mapping[str, Any]) -> dict[str, Any]:
    return {key: result[key] for key in (
        "id", "argv", "status", "exit_code", "timed_out", "duration_ms",
        "started_at_utc", "finished_at_utc",
    )}


def _current_core_command_text(
    logs: Mapping[str, str], command_id: str, stream: str = "stdout"
) -> str:
    name = f"{command_id}.{stream}.log"
    try:
        return logs[name]
    except KeyError as error:
        raise AdoptionError("CURRENT_CORE_LOGS", f"{name}: missing") from error


def _validate_current_core_command_receipts(commands: Any) -> None:
    if not isinstance(commands, list) or len(commands) != len(CURRENT_CORE_COMMANDS):
        raise AdoptionError("CURRENT_CORE_COMMANDS", "four executed commands are required")
    for actual, expected in zip(commands, CURRENT_CORE_COMMANDS):
        if not isinstance(actual, dict) or set(actual) != CURRENT_CORE_COMMAND_FIELDS:
            raise AdoptionError("CURRENT_CORE_COMMANDS", "command receipt fields")
        if (
            actual.get("id") != expected["id"]
            or actual.get("argv") != expected["argv"]
            or actual.get("status") != "PASS"
            or type(actual.get("exit_code")) is not int
            or actual.get("exit_code") != 0
            or actual.get("timed_out") is not False
        ):
            raise AdoptionError(
                "CURRENT_CORE_COMMANDS",
                f"{expected['id']}: missing, skipped, failed, or changed command",
            )
        duration = actual.get("duration_ms")
        if isinstance(duration, bool) or not isinstance(duration, (int, float)):
            raise AdoptionError("CURRENT_CORE_COMMANDS", f"{expected['id']}: duration")
        try:
            finite_duration = math.isfinite(duration)
        except OverflowError:
            finite_duration = False
        if not finite_duration or duration < 0:
            raise AdoptionError("CURRENT_CORE_COMMANDS", f"{expected['id']}: duration")
        timestamps: list[dt.datetime] = []
        for key in ("started_at_utc", "finished_at_utc"):
            value = actual.get(key)
            if not isinstance(value, str):
                raise AdoptionError("CURRENT_CORE_COMMANDS", f"{expected['id']}: {key}")
            try:
                timestamp = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
            except ValueError as error:
                raise AdoptionError(
                    "CURRENT_CORE_COMMANDS", f"{expected['id']}: {key}"
                ) from error
            if timestamp.tzinfo is None or timestamp.utcoffset() != dt.timedelta(0):
                raise AdoptionError("CURRENT_CORE_COMMANDS", f"{expected['id']}: {key} timezone")
            timestamps.append(timestamp)
        if timestamps[1] < timestamps[0]:
            raise AdoptionError("CURRENT_CORE_COMMANDS", f"{expected['id']}: reversed time")


def _validate_provider_build_log(
    root: Path, selected: Any, output: str
) -> None:
    lines = [line for line in output.splitlines() if line.strip()]
    if not lines:
        raise AdoptionError("CURRENT_CORE_BUILD", "provider-build JSON is missing")
    try:
        result = json.loads(lines[-1])
        manifest_path = _safe_current_core_path(
            root, "target/native/current/provider-manifest.json", "provider build manifest"
        )
        manifest = load_json(manifest_path)
        expected_archive = _safe_current_core_path(
            root, CURRENT_CORE_NATIVE_ARCHIVE, "provider build archive"
        )
        expected_digest = evidence_digest.artifact_byte_sha256(expected_archive)
        archive_bytes = expected_archive.stat().st_size

    except (json.JSONDecodeError, AdoptionError) as error:
        raise AdoptionError("CURRENT_CORE_BUILD", "provider-build result is invalid") from error
    except (OSError, evidence_digest.DigestError) as error:
        raise AdoptionError("CURRENT_CORE_BUILD", "built provider archive or manifest is missing") from error
    if not isinstance(result, dict) or not isinstance(manifest, dict):
        raise AdoptionError("CURRENT_CORE_BUILD", "provider build JSON must be objects")
    build_fingerprint = manifest.get("build_fingerprint")
    archive = manifest.get("archive")
    if (
        not isinstance(build_fingerprint, str)
        or re.fullmatch(r"[0-9a-f]{64}", build_fingerprint) is None
        or result != {
            "abi_version": selected.manifest["abi"]["version"],
            "adapter": selected.adapter,
            "build_fingerprint": build_fingerprint,
            "platform": selected.platform,
            "provider": selected.provider,
            "selection_fingerprint": selected.fingerprint,
            "status": "PASS",
        }
        or type(manifest.get("schema_version")) is not int
        or manifest.get("schema_version") != 1
        or manifest.get("providerId") != selected.provider
        or manifest.get("providerVersion") != selected.manifest["provider_version"]
        or not evidence_digest.schema_text_sha256_equal(
            manifest.get("providerFingerprint"),
            selected.manifest["source"]["content_sha256"],
        )
        or manifest.get("abiVersion") != selected.manifest["abi"]["version"]
        or manifest.get("capabilities") != selected.manifest["capabilities"]
        or not isinstance(archive, dict)
        or type(archive.get("bytes")) is not int
        or archive.get("bytes") != archive_bytes
        or not evidence_digest.schema_artifact_sha256_equal(
            archive.get("sha256"), expected_digest
        )
    ):
        raise AdoptionError("CURRENT_CORE_BUILD", "provider build receipt or manifest mismatch")


def _validate_architecture_guard_log(output: str) -> None:
    try:
        result = json.loads(output)
    except json.JSONDecodeError as error:
        raise AdoptionError("CURRENT_CORE_ARCHITECTURE", "architecture guard JSON is invalid") from error
    if (
        not isinstance(result, dict)
        or type(result.get("schema_version")) is not int
        or result.get("schema_version") != 1
        or result.get("kind") != "architecture-guard"
        or result.get("status") != "PASS"
        or result.get("ok") is not True
        or type(result.get("violation_count")) is not int
        or result.get("violation_count") != 0
        or result.get("violations") != []
    ):
        raise AdoptionError("CURRENT_CORE_ARCHITECTURE", "architecture guard did not PASS")


def _validate_substitution_log(stdout: str, stderr: str) -> None:
    output = stdout + "\n" + stderr
    case_rows = re.findall(
        r"^\s*\[\s*(PASSED|FAILED|ERROR|SKIPPED)\s+\]\s+CASE:\s+([A-Za-z_][A-Za-z0-9_]*)\b",
        output,
        re.MULTILINE,
    )
    suite_rows = re.findall(
        r"^\s*TCS:\s*TlsProviderSubstitutionTest,\s*time elapsed:\s*\d+\s*ns,\s*RESULT:\s*$",
        output,
        re.MULTILINE,
    )
    project_markers = list(re.finditer(
        r"^\s*Project tests finished,.*RESULT:\s*$",
        output,
        re.MULTILINE,
    ))
    summary_pattern = re.compile(
        r"^\s*Summary:\s*TOTAL:\s*(\d+)\s*\n"
        r"\s*PASSED:\s*(\d+),\s*SKIPPED:\s*(\d+),\s*ERROR:\s*(\d+)\s*\n"
        r"\s*FAILED:\s*(\d+)\s*$",
        re.MULTILINE,
    )
    summaries = list(summary_pattern.finditer(output))
    summary_headers = re.findall(
        r"^\s*Summary:\s*TOTAL:",
        output,
        re.MULTILINE,
    )
    expected_cases = [("PASSED", case) for case in CURRENT_CORE_CASES]
    valid_summaries = (
        len(summaries) == 2
        and len(summary_headers) == 2
        and len(project_markers) == 1
    )
    if valid_summaries:
        package_summaries = [
            match for match in summaries
            if match.start() < project_markers[0].start()
        ]
        project_summaries = [
            match for match in summaries
            if match.start() > project_markers[0].start()
        ]
        valid_summaries = (
            len(package_summaries) == 1
            and len(project_summaries) == 1
            and package_summaries[0].groups() == project_summaries[0].groups()
        )
    if valid_summaries:
        total, passed, skipped, errors, failed = (
            int(value) for value in summaries[0].groups()
        )
        valid_summaries = (
            total == passed + skipped + errors + failed
            and passed == len(CURRENT_CORE_CASES)
            and errors == 0
            and failed == 0
        )
    if (
        len(suite_rows) != 1
        or case_rows != expected_cases
        or not valid_summaries
    ):
        raise AdoptionError(
            "CURRENT_CORE_SUBSTITUTION",
            "all three selected provider-substitution cases must execute exactly once and PASS with zero errors or failures",
        )


def _safe_current_core_path(root: Path, relative: Any, field: str) -> Path:
    try:
        return repository_tooling.safe_path(
            root, relative, field, must_exist=True, file_only=True
        )
    except repository_tooling.ContractError as error:
        raise AdoptionError("CURRENT_CORE_EVIDENCE", f"{field}: {error.code}") from error


def validate_current_core(
    root: Path, report: Mapping[str, Any], sdk_archive: Path
) -> dict[str, Any]:
    if not isinstance(report, Mapping) or set(report) != CURRENT_CORE_FIELDS:
        raise AdoptionError("CURRENT_CORE_SCHEMA", "qualification field inventory")

    if (
        type(report.get("schema_version")) is not int
        or report.get("schema_version") != 1
        or report.get("source_task") != "M3-031"
        or report.get("task_id") != "M3-031"
        or report.get("kind") != CURRENT_CORE_KIND
        or report.get("status") != "PASS"
    ):
        raise AdoptionError("CURRENT_CORE_SCHEMA", "qualification identity or status")
    revision = report.get("revision")
    if not isinstance(revision, str) or re.fullmatch(r"[0-9a-f]{40}", revision) is None:
        raise AdoptionError("STALE_REVISION", "current Core revision must be a full lowercase SHA")
    if report.get("release") != development_baseline.RELEASE:
        raise AdoptionError("CURRENT_CORE_RELEASE", "current Core evidence cannot confer release qualification")

    try:
        production_sources = development_baseline.production_binding(root, revision)
        execution_inputs = development_baseline.execution_inputs(root)
        sdk = development_baseline.sdk_identity(root, sdk_archive)
        platform = linux_release.platform_identity()
    except Exception as error:
        detail = development_baseline.redact(str(error), root)
        raise AdoptionError("CURRENT_CORE_BINDING", detail[:1024]) from error
    if report.get("production_sources") != production_sources:
        raise AdoptionError("STALE_SOURCE", "current Core production source binding changed")
    if report.get("execution_inputs") != execution_inputs:
        raise AdoptionError("STALE_SOURCE", "current Core execution input binding changed")
    if report.get("sdk") != sdk:
        raise AdoptionError("SDK_IDENTITY", "current Core SDK identity changed")
    if report.get("platform") != platform:
        raise AdoptionError("CURRENT_CORE_PLATFORM", "current Core platform identity changed")

    try:
        selected = select_provider(root)
        expected_selection = _current_core_selection(selected)
    except Exception as error:
        if isinstance(error, AdoptionError):
            raise
        raise AdoptionError(
            "CURRENT_CORE_SELECTION", development_baseline.redact(str(error), root)[:1024]
        ) from error
    if report.get("selection") != expected_selection:
        raise AdoptionError("CURRENT_CORE_SELECTION", "selected provider or ABI inventory changed")

    commands = report.get("commands")
    _validate_current_core_command_receipts(commands)
    logs = _current_core_logs(root, report.get("logs"))
    _validate_provider_build_log(
        root, selected, _current_core_command_text(logs, "provider-build")
    )
    _validate_architecture_guard_log(
        _current_core_command_text(logs, "architecture-guard")
    )
    _validate_substitution_log(
        _current_core_command_text(logs, "provider-substitution"),
        _current_core_command_text(logs, "provider-substitution", "stderr"),
    )

    native_archive = report.get("native_archive")
    if (
        not isinstance(native_archive, dict)
        or set(native_archive) != {"path", "digest"}
        or native_archive.get("path") != CURRENT_CORE_NATIVE_ARCHIVE
    ):
        raise AdoptionError("CURRENT_CORE_ABI", "native archive path or receipt fields")
    archive_path = _safe_current_core_path(
        root, native_archive.get("path"), "current provider archive"
    )
    try:
        actual_archive_digest = evidence_digest.artifact_byte_digest(archive_path).to_json()
        validate_native_header_signatures(selected, root)
        validate_symbol_set(selected, archive_symbols(archive_path))
    except Exception as error:
        raise AdoptionError(
            "CURRENT_CORE_ABI", development_baseline.redact(str(error), root)[:1024]
        ) from error
    if actual_archive_digest != native_archive.get("digest"):
        raise AdoptionError("STALE_SOURCE", "current provider archive digest changed")

    consumer = report.get("installed_consumer")
    if (
        not isinstance(consumer, dict)
        or set(consumer) != {"qualification", "artifact"}
        or not isinstance(consumer.get("qualification"), dict)
        or set(consumer["qualification"]) != {"path", "digest"}
        or not isinstance(consumer.get("artifact"), dict)
        or set(consumer["artifact"]) != {"path", "digest"}
        or consumer["qualification"].get("path") != CURRENT_CORE_INSTALLED_QUALIFICATION
        or consumer["artifact"].get("path") != CURRENT_CORE_ARTIFACT
    ):
        raise AdoptionError("CURRENT_CORE_CONSUMER", "installed consumer receipt fields")
    qualification_path = _safe_current_core_path(
        root, consumer["qualification"].get("path"), "installed qualification"
    )
    artifact_path = _safe_current_core_path(
        root, consumer["artifact"].get("path"), "installed consumer artifact"
    )
    try:
        qualification_text = development_baseline.redact(
            qualification_path.read_text(encoding="utf-8"), root
        )
        installed = load_json(qualification_path)
        qualification_digest = evidence_digest.text_evidence_digest(
            qualification_path
        ).to_json()
        artifact_digest = evidence_digest.artifact_byte_digest(artifact_path).to_json()
        linux_release.validate_report(installed, root)
    except Exception as error:
        raise AdoptionError(
            "CURRENT_CORE_CONSUMER", development_baseline.redact(str(error), root)[:1024]
        ) from error
    if (
        qualification_digest != consumer["qualification"].get("digest")
        or artifact_digest != consumer["artifact"].get("digest")
        or not evidence_digest.schema_artifact_sha256_equal(
            installed.get("artifact", {}).get("sha256"),
            artifact_digest.get("sha256"),
        )
        or installed.get("artifact", {}).get("bytes") != artifact_path.stat().st_size
        or installed.get("artifact", {}).get("name") != artifact_path.name
    ):
        raise AdoptionError("STALE_SOURCE", "installed qualification or artifact digest changed")
    if logs.get("installed-consumer.qualification.log") != qualification_text:
        raise AdoptionError(
            "CURRENT_CORE_CONSUMER",
            "retained qualification log differs from the installed consumer report",
        )
    consumer_output = _current_core_command_text(logs, "installed-consumer")
    consumer_lines = consumer_output.splitlines()
    if (
        len(consumer_lines) != 4
        or consumer_lines[0] != "M7-021 Linux release qualification: PASS"
        or consumer_lines[1] != f"artifact=<repo>/{CURRENT_CORE_ARTIFACT}"
        or not consumer_lines[2].startswith("sha256=")
        or not evidence_digest.schema_artifact_sha256_equal(
            consumer_lines[2][len("sha256="):], installed["artifact"]["sha256"]
        )
        or consumer_lines[3] != f"report=<repo>/{CURRENT_CORE_INSTALLED_QUALIFICATION}"
    ):
        raise AdoptionError(
            "CURRENT_CORE_CONSUMER", "installed-consumer command output does not bind qualification"
        )
    return dict(report)

def capture_current_core(
    root: Path, revision: str, sdk_archive: Path, output: Path
) -> dict[str, Any]:
    root = root.resolve()
    sdk_archive = sdk_archive.resolve()
    output = (root / output).resolve() if not output.is_absolute() else output.resolve()
    try:
        output.relative_to(root)
    except ValueError as error:
        raise AdoptionError("CURRENT_CORE_OUTPUT", "output must be inside the repository") from error

    run_id = uuid.uuid4().hex
    staging = root / "build/m3-031-current-core" / run_id
    log_dir = root / "docs/evidence/M3-031/current-core/runs" / run_id
    report: dict[str, Any] = {
        "schema_version": 1,
        "source_task": "M3-031",
        "task_id": "M3-031",
        "kind": CURRENT_CORE_KIND,
        "status": "IN_PROGRESS",
        "revision": revision,
        "platform": {},
        "production_sources": {},
        "execution_inputs": {},
        "sdk": {},
        "selection": {},
        "native_archive": {},
        "commands": [],
        "logs": [],
        "installed_consumer": {},
        "release": development_baseline.RELEASE,
    }
    try:
        staging.mkdir(parents=True, exist_ok=False)
        log_dir.mkdir(parents=True, exist_ok=False)
        report["production_sources"] = development_baseline.production_binding(
            root, revision
        )
        report["execution_inputs"] = development_baseline.execution_inputs(root)
        report["sdk"] = development_baseline.sdk_identity(root, sdk_archive)
        report["platform"] = linux_release.platform_identity()
        selected = select_provider(root)
        report["selection"] = _current_core_selection(selected)

        for expected in CURRENT_CORE_COMMANDS:
            result = repository_tooling.run_command(root, expected, staging)
            for stream in ("stdout", "stderr"):
                relative = result[f"{stream}_path"]
                path = _safe_current_core_path(root, relative, f"{expected['id']} {stream}")
                raw = path.read_text(encoding="utf-8")
                report["logs"].append(
                    development_baseline.retain(
                        root, log_dir, f"commands/{expected['id']}.{stream}.log", raw
                    )
                )
            report["commands"].append(_current_core_command_record(result))
            if (
                result.get("status") != "PASS"
                or result.get("exit_code") != 0
                or result.get("timed_out") is not False
            ):
                raise AdoptionError(
                    "CURRENT_CORE_COMMANDS",
                    f"{expected['id']}: command did not execute successfully",
                )

        qualification_path = root / CURRENT_CORE_INSTALLED_QUALIFICATION
        qualification_text = qualification_path.read_text(encoding="utf-8")
        report["logs"].append(
            development_baseline.retain(
                root, log_dir, "commands/installed-consumer.qualification.log",
                qualification_text,
            )
        )
        qualification = load_json(qualification_path)
        artifact_path = root / CURRENT_CORE_ARTIFACT
        archive_path = root / CURRENT_CORE_NATIVE_ARCHIVE
        report["installed_consumer"] = {
            "qualification": {
                "path": CURRENT_CORE_INSTALLED_QUALIFICATION,
                "digest": evidence_digest.text_evidence_digest(
                    qualification_path
                ).to_json(),
            },
            "artifact": {
                "path": CURRENT_CORE_ARTIFACT,
                "digest": evidence_digest.artifact_byte_digest(artifact_path).to_json(),
            },
        }
        report["native_archive"] = {
            "path": CURRENT_CORE_NATIVE_ARCHIVE,
            "digest": evidence_digest.artifact_byte_digest(archive_path).to_json(),
        }
        report["status"] = "PASS"
        validate_current_core(root, report, sdk_archive)
        repository_tooling.atomic_json(output, report)
        return report
    except Exception as error:
        report["status"] = "FAIL"
        detail = development_baseline.redact(str(error), root)
        report["failure"] = {
            "code": error.code if isinstance(error, AdoptionError) else type(error).__name__,
            "detail": detail[:2048],
        }
        failed_output = output.with_name(
            f"{output.stem}.failed-{run_id}{output.suffix}"
        )
        repository_tooling.atomic_json(failed_output, report)
        if isinstance(error, AdoptionError):
            raise
        raise AdoptionError("CURRENT_CORE_CAPTURE", detail[:1024]) from error


def _dependency_path(root: Path, task_id: str, relative: str, field: str) -> Path:
    try:
        return repository_tooling.safe_path(
            root, relative, field, must_exist=True, file_only=True
        )
    except repository_tooling.ContractError as error:
        raise AdoptionError(
            "DEPENDENCY_EVIDENCE", f"{task_id}: {field} {error.code}"
        ) from error


def _dependency_text_digest(raw: Any, task_id: str, field: str) -> evidence_digest.TextEvidenceDigest:
    try:
        return evidence_digest.parse_text_digest(raw, f"{task_id} {field}")
    except evidence_digest.DigestError as error:
        raise AdoptionError(
            "DEPENDENCY_EVIDENCE", f"{task_id}: {field} {error.code}"
        ) from error


def _validate_current_desktop_source_inventory(
    root: Path, task_id: str, report: Mapping[str, Any]
) -> dict[str, str]:
    inventory = report.get("source_inventory")
    if not isinstance(inventory, dict):
        raise AdoptionError("DEPENDENCY_EVIDENCE", f"{task_id}: source inventory")

    if task_id == "M2-004":
        if (
            set(inventory) != {"schema_version", "paths", "digest"}
            or type(inventory.get("schema_version")) is not int
            or inventory.get("schema_version") != 1
            or not isinstance(inventory.get("paths"), list)
        ):
            raise AdoptionError("DEPENDENCY_EVIDENCE", f"{task_id}: source inventory schema")
        entries = inventory["paths"]
        canonical = json.dumps(
            {"schema_version": 1, "paths": entries},
            sort_keys=True,
            separators=(",", ":"),
            ensure_ascii=False,
        )
        observed_inventory_digest = evidence_digest.text_evidence_digest_bytes(
            canonical.encode("utf-8")
        )
        if (
            _dependency_text_digest(
                inventory.get("digest"), task_id, "source inventory digest"
            )
            != observed_inventory_digest
        ):
            raise AdoptionError(
                "DEPENDENCY_EVIDENCE", f"{task_id}: source inventory digest changed"
            )
    elif task_id == "M2-006":
        if (
            set(inventory) != {"revision", "clean_worktree", "files"}
            or inventory.get("revision") != report.get("revision")
            or inventory.get("clean_worktree") is not True
            or not isinstance(inventory.get("files"), list)
        ):
            raise AdoptionError("DEPENDENCY_EVIDENCE", f"{task_id}: source inventory schema")
        entries = inventory["files"]
    else:
        raise AdoptionError("DEPENDENCY_EVIDENCE", f"{task_id}: unsupported source inventory")

    required = {
        CURRENT_DESKTOP_RESOLVER_EVIDENCE[task_id]["pin"],
        "tools/gates/sts_sdk_identity.py",
    }
    digests: dict[str, str] = {}
    for item in entries:
        if not isinstance(item, dict) or set(item) != {"path", "digest"}:
            raise AdoptionError("DEPENDENCY_EVIDENCE", f"{task_id}: source inventory entry")
        relative = item.get("path")
        if not isinstance(relative, str) or relative in digests:
            raise AdoptionError("DEPENDENCY_EVIDENCE", f"{task_id}: duplicate source path")
        expected = _dependency_text_digest(
            item.get("digest"), task_id, f"source inventory[{relative}]"
        )
        path = _dependency_path(root, task_id, relative, "source inventory")
        actual = evidence_digest.text_evidence_digest(path)
        if actual != expected:
            raise AdoptionError(
                "DEPENDENCY_EVIDENCE", f"{task_id}: current source digest changed: {relative}"
            )
        digests[relative] = actual.sha256
    if not required.issubset(digests):
        missing = sorted(required - set(digests))
        raise AdoptionError(
            "DEPENDENCY_EVIDENCE", f"{task_id}: source inventory omits {missing[0]}"
        )
    return digests


def _validate_current_desktop_sdk_pin(
    root: Path, task_id: str, report: Mapping[str, Any]
) -> None:
    pin_path = CURRENT_DESKTOP_RESOLVER_EVIDENCE[task_id]["pin"]
    pin = load_json(_dependency_path(root, task_id, pin_path, "SDK pin"))
    sdk = report.get("sdk")
    archive = pin.get("archive")
    sdk_archive = sdk.get("archive") if isinstance(sdk, dict) else None
    if (
        not isinstance(archive, dict)
        or not isinstance(sdk, dict)
        or not isinstance(sdk_archive, dict)
        or sdk.get("channel") != pin.get("channel")
        or sdk.get("version") != pin.get("version")
        or sdk.get("archive_name") != archive.get("name")
        or sdk_archive.get("domain") != evidence_digest.ARTIFACT_BYTE_DOMAIN
        or not evidence_digest.schema_artifact_sha256_equal(
            sdk_archive.get("sha256"), archive.get("sha256")
        )
    ):
        raise AdoptionError("DEPENDENCY_EVIDENCE", f"{task_id}: pinned SDK identity changed")


def _validate_current_desktop_logs(
    root: Path, task_id: str, report: Mapping[str, Any]
) -> dict[str, str]:
    bindings = CURRENT_DESKTOP_LOG_IDS[task_id]
    logs = report.get("logs")
    records: dict[str, tuple[str, Any]] = {}
    if task_id == "M2-004":
        if not isinstance(logs, dict) or set(logs) != set(bindings):
            raise AdoptionError("DEPENDENCY_EVIDENCE", f"{task_id}: native log inventory")
        for log_id, item in logs.items():
            if not isinstance(item, dict) or set(item) != {"path", "digest"}:
                raise AdoptionError("DEPENDENCY_EVIDENCE", f"{task_id}: {log_id} log fields")
            records[log_id] = (item["path"], item["digest"])
    else:
        if not isinstance(logs, list):
            raise AdoptionError("DEPENDENCY_EVIDENCE", f"{task_id}: native log inventory")
        for item in logs:
            if not isinstance(item, dict) or set(item) != {"id", "path", "digest"}:
                raise AdoptionError("DEPENDENCY_EVIDENCE", f"{task_id}: native log fields")
            log_id = item["id"]
            if not isinstance(log_id, str) or log_id in records:
                raise AdoptionError("DEPENDENCY_EVIDENCE", f"{task_id}: duplicate log id")
            records[log_id] = (item["path"], item["digest"])
        if set(records) != set(bindings):
            raise AdoptionError("DEPENDENCY_EVIDENCE", f"{task_id}: native log inventory")

    digests: dict[str, str] = {}
    report_directory = Path(CURRENT_DESKTOP_RESOLVER_EVIDENCE[task_id]["report"]).parent
    for log_id, expected_relative in bindings.items():
        relative, raw_digest = records[log_id]
        if relative != expected_relative:
            raise AdoptionError("DEPENDENCY_EVIDENCE", f"{task_id}: {log_id} log path")
        if task_id == "M2-006":
            relative = (report_directory / relative).as_posix()
        path = _dependency_path(root, task_id, relative, f"{log_id} log")
        expected = _dependency_text_digest(raw_digest, task_id, f"{log_id} log digest")
        actual = evidence_digest.text_evidence_digest(path)
        if actual != expected:
            raise AdoptionError(
                "DEPENDENCY_EVIDENCE", f"{task_id}: native log digest changed: {log_id}"
            )
        digests[relative] = actual.sha256
    return digests


def _validate_current_desktop_validation(
    task_id: str,
    validation: Mapping[str, Any],
    report: Mapping[str, Any],
    report_path: Path,
    expected_revision: str,
) -> str:
    expected_fields = {
        "M2-004": {
            "schema_version", "task_id", "expected_revision", "report_digest",
            "source_inventory_digest", "failures", "status",
        },
        "M2-006": {
            "schema_version", "task_id", "expected_revision", "expected_mode",
            "report_digest", "failures", "status",
        },
    }[task_id]
    if (
        set(validation) != expected_fields
        or type(validation.get("schema_version")) is not int
        or validation.get("schema_version") != 2
        or validation.get("task_id") != task_id
        or validation.get("expected_revision") != expected_revision
        or validation.get("failures") != []
        or validation.get("status") != "PASS"
        or report.get("revision") != expected_revision
        or report.get("decision") != "PASS"
        or report.get("failures") != []
    ):
        raise AdoptionError("DEPENDENCY_EVIDENCE", f"{task_id}: native validation identity/status")
    if task_id == "M2-006" and (
        validation.get("expected_mode") != "macos"
        or report.get("mode") != "macos"
    ):
        raise AdoptionError("DEPENDENCY_EVIDENCE", f"{task_id}: native validation mode")

    report_digest = _dependency_text_digest(
        validation.get("report_digest"), task_id, "report digest"
    )
    actual_report_digest = evidence_digest.text_evidence_digest(report_path)
    if report_digest != actual_report_digest:
        raise AdoptionError("DEPENDENCY_EVIDENCE", f"{task_id}: report digest changed")
    if task_id == "M2-004":
        source_digest = _dependency_text_digest(
            validation.get("source_inventory_digest"), task_id, "source inventory digest"
        )
        inventory_digest = _dependency_text_digest(
            report.get("source_inventory", {}).get("digest"),
            task_id,
            "report source inventory digest",
        )
        if source_digest != inventory_digest:
            raise AdoptionError(
                "DEPENDENCY_EVIDENCE", f"{task_id}: source inventory receipt changed"
            )
    return actual_report_digest.sha256


def validate_dependency_evidence(
    root: Path, expected_revision: str
) -> dict[str, Any]:
    if re.fullmatch(r"[0-9a-f]{40}", expected_revision) is None:
        raise AdoptionError("DEPENDENCY_EVIDENCE", "expected revision must be a full lowercase SHA")
    validated: dict[str, Any] = {}
    source_sha256: dict[str, str] = {}
    for task_id, binding in CURRENT_DESKTOP_RESOLVER_EVIDENCE.items():
        report_relative = binding["report"]
        validation_relative = binding["validation"]
        report_path = _dependency_path(root, task_id, report_relative, "native report")
        validation_path = _dependency_path(
            root, task_id, validation_relative, "native validation"
        )
        report = load_json(report_path)
        validation = load_json(validation_path)
        if (
            type(report.get("schema_version")) is not int
            or report.get("schema_version") != 2
            or report.get("task_id") != task_id
            or report.get("revision") != expected_revision
        ):
            raise AdoptionError("DEPENDENCY_EVIDENCE", f"{task_id}: report identity/revision")
        try:
            if task_id == "M2-004":
                failures = m2_004_windows_resolver.validate_current_desktop_artifacts(
                    report_path,
                    validation_path,
                    expected_revision,
                    repo_root=root,
                )
            else:
                failures = m2_006_apple_resolver.validate_current_desktop_artifacts(
                    report_path,
                    validation_path,
                    expected_revision,
                    expected_mode="macos",
                )
        except Exception as error:
            raise AdoptionError(
                "DEPENDENCY_EVIDENCE", f"{task_id}: native report validation failed"
            ) from error
        if failures:
            raise AdoptionError(
                "DEPENDENCY_EVIDENCE", f"{task_id}: {failures[0]}"
            )

        _validate_current_desktop_sdk_pin(root, task_id, report)
        report_source_digests = _validate_current_desktop_source_inventory(
            root, task_id, report
        )
        log_digests = _validate_current_desktop_logs(root, task_id, report)
        report_digest = _validate_current_desktop_validation(
            task_id, validation, report, report_path, expected_revision
        )
        validation_digest = evidence_digest.text_evidence_digest(validation_path).sha256
        pair_sources = {
            report_relative: report_digest,
            validation_relative: validation_digest,
            **report_source_digests,
            **log_digests,
        }
        source_sha256.update(pair_sources)
        validated[task_id] = {
            "platform": binding["platform"],
            "report": report_relative,
            "report_digest": evidence_digest.text_evidence_digest(report_path).to_json(),
            "validation": validation_relative,
            "validation_digest": evidence_digest.text_evidence_digest(
                validation_path
            ).to_json(),
            "source_count": len(report_source_digests),
            "log_count": len(log_digests),
            "sdk": report["sdk"],
            "status": "PASS",
        }
    return {
        "tasks": validated,
        "source_sha256": dict(sorted(source_sha256.items())),
        "status": "PASS",
    }


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
        if columns[6] != EXPECTED_DESKTOP_ACCEPTANCE[task_id]:
            raise AdoptionError("TASK_GRAPH", f"{task_id}: acceptance text changed")
        desktop[task_id] = {"dependencies": dependencies, "status": "PASS"}
    for task_id, expected_row in MOBILE_GRAPH_ROWS.items():
        if _backlog_row(backlog, task_id) != expected_row:
            raise AdoptionError("MOBILE_GRAPH_DRIFT", task_id)
    return {
        "desktop": desktop,
        "mobile_rows_checked": len(MOBILE_GRAPH_ROWS),
        "status": "PASS",
    }


def audit_core(root: Path, sdk_archive: Path | None = None) -> dict[str, Any]:
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
    historical = _historical_core_diagnostic(root)
    archive = baseline_sdk_archive(sdk_archive)
    current_path = _safe_current_core_path(
        root, CURRENT_CORE_RELATIVE, "current Core qualification"
    )
    current_report = load_json(current_path)
    current_core = validate_current_core(root, current_report, archive)

    dependency_evidence = validate_dependency_evidence(
        root, current_core["revision"]
    )
    source_sha256.update(dependency_evidence["source_sha256"])
    source_sha256[CURRENT_CORE_RELATIVE] = evidence_digest.text_evidence_sha256(
        current_path
    )
    graph = audit_task_graph(root)
    backlog_relative = "docs/planning/implementation-backlog.md"
    source_sha256[backlog_relative] = evidence_digest.text_evidence_sha256(root / backlog_relative)
    return {
        "schema_version": 1,
        "task_id": "M3-031",
        "kind": "provider-neutral-core-adoption",
        "status": "PASS",
        "prerequisites": prerequisites,
        "excluded_global_conditions": list(EXCLUDED_GLOBAL_CONDITIONS),
        "historical_task_status_changed": False,
        "historical_evidence": list(RETAINED_EVIDENCE),
        "historical_core_evidence_validation": historical,
        "current_core_qualification": {
            "path": CURRENT_CORE_RELATIVE,
            "digest": evidence_digest.text_evidence_digest(current_path).to_json(),
            "revision": current_core["revision"],
            "selection": current_core["selection"],
            "native_archive": current_core["native_archive"],
            "installed_consumer": current_core["installed_consumer"],
            "status": "PASS",
        },
        "dependency_evidence_validation": dependency_evidence,
        "historical_references": list(HISTORICAL_REFERENCES),
        "source_sha256": dict(sorted(source_sha256.items())),
        "task_graph": graph,
        "boundary": "Only the desktop-applicable contract is audited. Global six-platform and mobile conditions are not evaluated, and no desktop trust or system-key adapter is implemented.",
    }


def validate_provider_result(
    raw: Mapping[str, Any], *, expected_platform: str, expected_revision: str,
    root: Path = ROOT, result_path: Path | None = None,
) -> dict[str, Any]:
    if len(expected_revision) != 40 or any(value not in "0123456789abcdef" for value in expected_revision):
        raise AdoptionError("STALE_REVISION", "expected revision must be an exact lowercase SHA")
    if raw.get("provider") != PINNED_PROVIDER:
        raise AdoptionError("PROVIDER", str(raw.get("provider")))
    if raw.get("platform") != expected_platform:
        raise AdoptionError("PLATFORM", str(raw.get("platform")))
    status = raw.get("status")
    if status not in poc_validate.RESULT_STATUSES:
        raise AdoptionError("RAW_RESULT", f"unsupported result status: {status}")
    if status != "PASS":
        raise AdoptionError("INCOMPLETE_RESULT", str(status))
    if raw.get("schema_version") != PROVIDER_RESULT_SCHEMA_VERSION:
        raise AdoptionError("RAW_RESULT", str(raw.get("schema_version")))
    if raw.get("poc_exit_code") != 0:
        raise AdoptionError("INCOMPLETE_RESULT", "provider PoC did not exit successfully")
    source = raw.get("source")
    provider_manifest = load_json(root / "native/tls/aws_lc/provider.json")
    expected_source = provider_manifest.get("source")
    if (
        provider_manifest.get("provider_id") != PINNED_PROVIDER
        or provider_manifest.get("provider_version") != PINNED_PROVIDER_VERSION
        or not isinstance(expected_source, dict)
        or expected_source.get("commit") != PINNED_COMMIT
    ):
        raise AdoptionError("PROVIDER", "approved AWS-LC provider pin mismatch")
    if not isinstance(source, dict) or any(
        source.get(field) != expected_source.get(field)
        for field in ("kind", "commit", "tree", "content_sha256")
    ):
        raise AdoptionError("PROVIDER", "AWS-LC source identity mismatch")
    spec = load_json(root / "tools/tls_provider_poc/providers.json")
    provider_spec = next(
        (item for item in spec.get("providers", []) if item.get("id") == PINNED_PROVIDER),
        None,
    )
    if (
        not isinstance(provider_spec, dict)
        or provider_spec.get("version") != PINNED_PROVIDER_VERSION
        or provider_spec.get("commit") != PINNED_COMMIT
    ):
        raise AdoptionError("PROVIDER", "approved AWS-LC PoC pin mismatch")
    try:
        poc_validate.validate_result(raw, spec, expected_revision)
    except poc_validate.ValidationError as error:
        detail = str(error)
        code = "STALE_REVISION" if "revision" in detail else "RAW_RESULT"
        raise AdoptionError(code, detail) from error
    if result_path is None:
        result_path = (
            root / f"docs/evidence/M3-031/{expected_platform}/provider-result.json"
        )
    try:
        poc_validate.validate_license_bundle(result_path, raw)
    except poc_validate.ValidationError as error:
        raise AdoptionError("LICENSE_BUNDLE", str(error)) from error
    capabilities = raw.get("capabilities")
    if not isinstance(capabilities, dict) or any(value != "PASS" for value in capabilities.values()):
        raise AdoptionError("INCOMPLETE_RESULT", "every capability must be PASS")
    execution = raw.get("execution")
    if not isinstance(execution, dict):
        raise AdoptionError("PLATFORM", "execution metadata missing")
    if execution.get("image_os") != EXPECTED_RUNNER_IMAGES[expected_platform]:
        raise AdoptionError("PLATFORM", "required hosted runner image was not used")
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
        "license_bundle_manifest_sha256": raw.get("build", {}).get(
            "license_bundle", {}
        ).get("sha256"),
        "status": "PASS",
    }


def aggregate(
    core: Mapping[str, Any], windows: Mapping[str, Any], macos: Mapping[str, Any],
    expected_revision: str, *, root: Path = ROOT,
    windows_path: Path | None = None, macos_path: Path | None = None,
    sdk_archive: Path | None = None,
) -> dict[str, Any]:
    root = root.resolve()
    current_core = audit_core(root, sdk_archive)
    if not isinstance(core, Mapping) or dict(core) != current_core:
        raise AdoptionError(
            "CORE_REQUIREMENT",
            "provided Core audit is not the current audit of the source-bound qualification",
        )
    if current_core["current_core_qualification"]["revision"] != expected_revision:
        raise AdoptionError(
            "STALE_REVISION",
            "hosted desktop results do not use the current Core qualification revision",
        )
    win = validate_provider_result(
        windows, expected_platform="windows-x86_64", expected_revision=expected_revision,
        root=root, result_path=windows_path,
    )
    mac = validate_provider_result(
        macos, expected_platform="macos-arm64", expected_revision=expected_revision,
        root=root, result_path=macos_path,
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


def _rooted_input(root: Path, path: Path) -> Path:
    return path.resolve() if path.is_absolute() else (root / path).resolve()


def _write_or_print(value: Mapping[str, Any], output: Path | None) -> None:
    if output is not None:
        atomic_json(output, value)
    print(json.dumps(value, sort_keys=True))


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    sub = parser.add_subparsers(dest="command", required=True)
    core_parser = sub.add_parser("audit-core")
    core_parser.add_argument("--sdk-archive", type=Path)
    core_parser.add_argument("--output", type=Path)
    capture = sub.add_parser("capture-current-core")
    capture.add_argument("--revision", required=True)
    capture.add_argument("--sdk-archive", type=Path)
    capture.add_argument("--output", type=Path, default=Path(CURRENT_CORE_RELATIVE))
    current = sub.add_parser("validate-current-core")
    current.add_argument("--input", type=Path, default=Path(CURRENT_CORE_RELATIVE))
    current.add_argument("--sdk-archive", type=Path)
    current.add_argument("--output", type=Path)
    provider = sub.add_parser("validate-provider")
    provider.add_argument("--input", type=Path, required=True)
    provider.add_argument("--platform", choices=["windows-x86_64", "macos-arm64"], required=True)
    provider.add_argument("--expected-revision", required=True)
    provider.add_argument("--output", type=Path)
    hosted = sub.add_parser("validate-hosted")
    hosted.add_argument("--input", type=Path, required=True)
    hosted.add_argument("--output", type=Path)
    matrix = sub.add_parser("aggregate")
    matrix.add_argument("--core", type=Path, required=True)
    matrix.add_argument("--windows", type=Path, required=True)
    matrix.add_argument("--macos", type=Path, required=True)
    matrix.add_argument("--expected-revision", required=True)
    matrix.add_argument("--sdk-archive", type=Path)
    matrix.add_argument("--output", type=Path)
    args = parser.parse_args(argv)
    root = args.root.resolve()
    try:
        if args.command == "audit-core":
            value = audit_core(root, args.sdk_archive)
        elif args.command == "capture-current-core":
            value = capture_current_core(
                root, args.revision, baseline_sdk_archive(args.sdk_archive), args.output
            )
        elif args.command == "validate-current-core":
            value = validate_current_core(
                root,
                load_json(_rooted_input(root, args.input)),
                baseline_sdk_archive(args.sdk_archive),
            )
        elif args.command == "validate-provider":
            input_path = _rooted_input(root, args.input)
            raw = load_json(input_path)
            value = validate_provider_result(
                raw, expected_platform=args.platform,
                expected_revision=args.expected_revision,
                root=root,
                result_path=input_path,
            )
        elif args.command == "validate-hosted":
            value = validate_hosted_run(root, load_json(_rooted_input(root, args.input)))
        else:
            core_path = _rooted_input(root, args.core)
            windows_path = _rooted_input(root, args.windows)
            macos_path = _rooted_input(root, args.macos)
            value = aggregate(
                load_json(core_path), load_json(windows_path), load_json(macos_path),
                args.expected_revision,
                root=root,
                windows_path=windows_path,
                macos_path=macos_path,
                sdk_archive=args.sdk_archive,
            )
        _write_or_print(value, args.output)
        return 0
    except AdoptionError as error:
        print(json.dumps({"code": error.code, "detail": error.detail[:2048], "status": "FAIL"}, sort_keys=True))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
