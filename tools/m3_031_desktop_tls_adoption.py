#!/usr/bin/env python3
"""Audit M3 desktop prerequisites and validate exact-revision provider results."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import tempfile
from pathlib import Path
from typing import Any, Mapping, Sequence

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from tools.tls_provider_poc import validate as poc_validate
from tools.repository import repository_tooling
from tools.gates import m2_004_windows_resolver, m2_006_apple_resolver
from tools.tls_provider.selection import expected_symbols, select_provider


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
M3_030_PROFILE = "linux-x86_64-glibc"
M3_030_TEST_PROVIDER_PROPERTIES = (
    "factory-substitution",
    "instance-mismatch",
    "retained-lifetime",
)
HISTORICAL_REFERENCES = ("docs/evidence/M3-028/README.md",)
HOSTED_INPUT_PATHS = (
    "tools/tls_provider_poc/openssl_memory_poc.c",
    "tools/tls_provider_poc/providers.json",
    "tools/tls_provider_poc/run.py",
    "tools/tls_provider_poc/validate.py",
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
DEPENDENCY_EVIDENCE_BINDINGS = {
    "M2-004": (
        (
            "docs/evidence/M2-004/windows-x86_64/validation.json",
            "docs/evidence/M2-004/windows-x86_64/report.json",
            None,
        ),
    ),
    "M2-006": (
        (
            "docs/evidence/M2-006/macos-arm64/validation.json",
            "docs/evidence/M2-006/macos-arm64/report.json",
            "macos",
        ),
        (
            "docs/evidence/M2-006/ios-simulator-arm64/validation.json",
            "docs/evidence/M2-006/ios-simulator-arm64/report.json",
            "ios-simulator",
        ),
    ),
}


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


def repository_text_sha256(path: Path) -> str:
    data = path.read_bytes()
    if b"\x00" not in data:
        data = data.replace(b"\r\n", b"\n")
    return hashlib.sha256(data).hexdigest()


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
    return sha256_path(path)


def _backlog_row(backlog: str, task_id: str) -> str:
    prefix = f"| {task_id} |"
    rows = [line for line in backlog.splitlines() if line.startswith(prefix)]
    if len(rows) != 1:
        raise AdoptionError("TASK_GRAPH", f"{task_id}: expected one backlog row")
    return rows[0]


def hosted_input_sha256(root: Path) -> dict[str, str]:
    return {
        relative: repository_text_sha256(root / relative)
        for relative in HOSTED_INPUT_PATHS
    }


def validate_hosted_run(root: Path, raw: Mapping[str, Any]) -> dict[str, Any]:
    if raw.get("schema_version") != 2 or raw.get("task_id") != "M3-031":
        raise AdoptionError("UNKNOWN_SCHEMA", "hosted-run schema or task mismatch")
    if raw.get("status") != "PASS" or raw.get("conclusion") != "success":
        raise AdoptionError("INCOMPLETE_RESULT", "hosted-run is not successful")
    revision = raw.get("revision")
    if not isinstance(revision, str) or len(revision) != 40 or any(
            value not in "0123456789abcdef" for value in revision):
        raise AdoptionError("STALE_REVISION", "hosted-run revision is not an exact SHA")
    expected = hosted_input_sha256(root)
    if raw.get("source_sha256") != expected:
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
    for name, (result_relative, validation_relative) in expected_artifacts.items():
        artifact = by_name[name]
        if (
            artifact.get("provider_result_sha256")
            != sha256_path(root / result_relative)
            or artifact.get("validation_sha256")
            != sha256_path(root / validation_relative)
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


def _m3_030_base(**values: Any) -> dict[str, Any]:
    return {
        "schemaVersion": 1,
        "taskId": "M3-030",
        "source_task": "M3-030",
        "platform": M3_030_PROFILE,
        "acceptance_status": "PASS",
        "status": "PASS",
        "decision": "PASS",
        **values,
    }


def expected_m3_030_reports(root: Path) -> dict[str, dict[str, Any]]:
    try:
        selected = select_provider(root)
    except Exception as error:
        raise AdoptionError(
            "RETAINED_EVIDENCE", f"M3-030 provider selection: {type(error).__name__}"
        ) from error
    qualification = load_json(
        root / "docs/evidence/M7-021/linux_x86_64/qualification.json"
    )
    if qualification.get("task_id") != "M7-021" or qualification.get("decision") != "PASS":
        raise AdoptionError("RETAINED_EVIDENCE", "M7-021 qualification is not PASS")
    artifact = qualification.get("artifact")
    if not isinstance(artifact, dict):
        raise AdoptionError("RETAINED_EVIDENCE", "M7-021 artifact identity is missing")
    bundle = load_json(root / "docs/evidence/M7-025/linux_x86_64/bundle.json")
    if (
        bundle.get("schemaVersion") != 1
        or bundle.get("taskId") != "M7-025"
        or bundle.get("decision") != "PASS"
    ):
        raise AdoptionError("RETAINED_EVIDENCE", "M7-025 supply-chain bundle is not PASS")
    build_fingerprint = bundle.get("buildFingerprint")
    if not isinstance(build_fingerprint, str) or re.fullmatch(
        r"[0-9a-f]{64}", build_fingerprint
    ) is None:
        raise AdoptionError("RETAINED_EVIDENCE", "M7-025 build fingerprint is invalid")
    return {
        "architecture-guard.json": _m3_030_base(
            violationCount=0,
            violations=[],
        ),
        "clean-consumer.json": _m3_030_base(
            checks={
                "publicApiOnly": "PASS",
                "build": "PASS",
                "httpsLoopback": "PASS",
            },
        ),
        "linux-aws-lc-results.json": _m3_030_base(
            providerId=selected.provider,
            providerVersion=selected.manifest["provider_version"],
            selectionFingerprint=selected.fingerprint,
            capabilities=selected.manifest["capabilities"],
            externalOpenSslDependency=False,
        ),
        "native-abi-report.json": _m3_030_base(
            abiVersion=selected.manifest["abi"]["version"],
            requiredFunctions=sorted(expected_symbols(selected)),
            signatureCount=len(selected.abi_contract["signatures"]),
            callingConventions=["c"],
            signatureChecks={
                "cangjieForeignDeclarations": "PASS",
                "nativeHeaderProbe": "PASS",
            },
            archive="target/native/current/lib/libwirestack_tls_provider.a",
            missingFunctions=[],
        ),
        "platform-provider-matrix.json": _m3_030_base(
            selected={
                "platform": selected.platform,
                "provider": selected.provider,
                "adapter": selected.adapter,
                "fallback": False,
            },
            productionCombinations=[f"{selected.platform}+{selected.provider}"],
            futureAdaptersImplemented=[],
        ),
        "release-validation.json": _m3_030_base(
            artifact=artifact,
            provider=selected.provider,
            externalOpenSslDependency=False,
        ),
        "sbom-validation.json": _m3_030_base(
            buildFingerprint=build_fingerprint,
            provider=selected.provider,
            licenseExpression=selected.manifest["license_expression"],
        ),
        "test-provider-results.json": _m3_030_base(
            passed=3,
            failed=0,
            skippedAsPass=False,
            properties=list(M3_030_TEST_PROVIDER_PROPERTIES),
            releasePayload=False,
        ),
    }


def validate_m3_030_task_check(
    payload: Mapping[str, Any], task: Mapping[str, Any]
) -> None:
    if (
        payload.get("schema_version") != 1
        or payload.get("task_id") != "M3-030"
        or payload.get("kind") != "repository-check"
        or payload.get("mode") != "task"
        or payload.get("status") != "PASS"
        or payload.get("issues") != []
    ):
        raise AdoptionError("RETAINED_EVIDENCE", "M3-030 task report identity or status")
    commands = payload.get("commands")
    expected_commands = task.get("acceptance_commands")
    if not isinstance(commands, list) or not isinstance(expected_commands, list):
        raise AdoptionError("RETAINED_EVIDENCE", "M3-030 task commands are missing")
    if [item.get("id") for item in commands if isinstance(item, dict)] != [
        item.get("id") for item in expected_commands if isinstance(item, dict)
    ] or len(commands) != len(expected_commands):
        raise AdoptionError("RETAINED_EVIDENCE", "M3-030 task command inventory changed")
    for observed, expected in zip(commands, expected_commands):
        if not isinstance(observed, dict) or not isinstance(expected, dict):
            raise AdoptionError("RETAINED_EVIDENCE", "M3-030 task command entry")
        if (
            observed.get("id") != expected.get("id")
            or observed.get("argv") != expected.get("argv")
            or observed.get("status") != "PASS"
            or observed.get("exit_code") != 0
            or observed.get("timed_out") is not False
            or observed.get("skipped") not in {None, False}
        ):
            raise AdoptionError(
                "RETAINED_EVIDENCE",
                f"M3-030 task command is not an executed PASS: {expected.get('id')}",
            )


def validate_retained_evidence(root: Path) -> dict[str, Any]:
    require_complete_status(root, "M3-030", "RETAINED_EVIDENCE")
    try:
        task = repository_tooling.load_task(root / "tools/tasks/M3-030.json", root)
    except repository_tooling.ContractError as error:
        raise AdoptionError("RETAINED_EVIDENCE", f"M3-030 task contract: {error.code}") from error
    evidence_path = root / "docs/evidence/M3-030/evidence.json"
    evidence = load_json(evidence_path)
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
    evidence_relative = "docs/evidence/M3-030/evidence.json"
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
    semantic_reports = expected_m3_030_reports(root)
    for relative in sorted(expected_reports):
        entry = by_path.get(relative)
        if not isinstance(entry, dict):
            raise AdoptionError("RETAINED_EVIDENCE", f"{relative}: absent from evidence index")
        path = root / relative
        if entry.get("source_task") != "M3-030" or entry.get("acceptance_status") != "PASS":
            raise AdoptionError("RETAINED_EVIDENCE", f"{relative}: index does not record PASS")
        if entry.get("sha256") != repository_text_sha256(path):
            raise AdoptionError("STALE_SOURCE", f"{relative}: report digest changed")
        payload = load_json(path)
        payload_task = payload.get("source_task")
        if payload_task is None:
            payload_task = payload.get("task_id")
        if payload_task != "M3-030" or payload.get("status") != "PASS":
            raise AdoptionError("RETAINED_EVIDENCE", f"{relative}: report does not provide PASS")
        name = Path(relative).name
        if name == "task-check.json":
            validate_m3_030_task_check(payload, task)
        elif semantic_reports.get(name) != payload:
            raise AdoptionError(
                "RETAINED_EVIDENCE", f"{relative}: report semantics are invalid"
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
        path = root / relative
        if not path.is_file():
            raise AdoptionError("STALE_SOURCE", f"{relative}: retained M3-030 source is missing")
        recorded[relative] = expected
        current[relative] = repository_text_sha256(path)
    return {"task_id": "M3-030", "reports": sorted(expected_reports),
            "semantic_report_count": len(expected_reports),
            "recorded_source_sha256": dict(sorted(recorded.items())),
            "source_sha256": dict(sorted(current.items())),
            "changed_since_m3_030": sorted(
                relative for relative in expected_paths
                if recorded[relative] != current[relative]
            ),
            "status": "PASS"}


def validate_native_source_binding(
    root: Path, task_id: str, report: Mapping[str, Any],
    source_sha256: Mapping[str, str],
) -> None:
    manifest = report.get("resolver_manifest")
    inputs = manifest.get("inputs") if isinstance(manifest, dict) else None
    if not isinstance(inputs, dict):
        raise AdoptionError("DEPENDENCY_EVIDENCE", f"{task_id}: native source inputs")
    if task_id == "M2-004":
        expected = {
            "native/resolver/windows/wirestack_resolver.c": inputs.get("source_sha256"),
            "native/resolver/windows/wirestack_resolver.h": inputs.get("header_sha256"),
        }
    elif task_id == "M2-006":
        raw_sources = inputs.get("sources")
        if not isinstance(raw_sources, dict):
            raise AdoptionError("DEPENDENCY_EVIDENCE", f"{task_id}: native sources")
        required = (
            "native/resolver/apple/wirestack_resolver.c",
            "native/resolver/apple/wirestack_resolver.h",
            "native/resolver/linux/wirestack_resolver.c",
            "native/resolver/linux/wirestack_resolver.h",
        )
        expected = {}
        for relative in required:
            matches = [
                digest for path, digest in raw_sources.items()
                if isinstance(path, str) and path.replace("\\", "/").endswith(relative)
            ]
            if len(matches) != 1:
                raise AdoptionError(
                    "DEPENDENCY_EVIDENCE", f"{task_id}: {relative} native binding"
                )
            expected[relative] = matches[0]
    else:
        raise AdoptionError("DEPENDENCY_EVIDENCE", f"{task_id}: unsupported binding")
    for relative, digest in expected.items():
        if not isinstance(digest, str) or source_sha256.get(relative) != digest:
            raise AdoptionError(
                "DEPENDENCY_EVIDENCE", f"{task_id}: {relative} native source drift"
            )
        try:
            path = repository_tooling.safe_path(
                root, relative, "native source", must_exist=True, file_only=True
            )
        except repository_tooling.ContractError as error:
            raise AdoptionError("DEPENDENCY_EVIDENCE", f"{task_id}: {error.code}") from error
        if repository_text_sha256(path) != digest:
            raise AdoptionError("STALE_SOURCE", f"{task_id}: {relative}")


def validate_dependency_evidence(
    root: Path,
    bindings: Mapping[str, Sequence[tuple[str, str, str | None]]] = DEPENDENCY_EVIDENCE_BINDINGS,
    *,
    verify_current_sources: bool = True,
) -> dict[str, Any]:
    validated: dict[str, Any] = {}
    for task_id, report_bindings in bindings.items():
        require_complete_status(root, task_id, "DEPENDENCY_EVIDENCE")
        try:
            task = repository_tooling.load_task(root / f"tools/tasks/{task_id}.json", root)
        except repository_tooling.ContractError as error:
            raise AdoptionError("DEPENDENCY_EVIDENCE", f"{task_id}: {error.code}") from error
        evidence = load_json(root / f"docs/evidence/{task_id}/evidence.json")
        if set(evidence) != repository_tooling.EVIDENCE_KEYS:
            raise AdoptionError("DEPENDENCY_EVIDENCE", f"{task_id}: evidence fields")
        if (
            evidence.get("schema_version") != repository_tooling.EVIDENCE_SCHEMA_VERSION
            or evidence.get("source_task") != task_id
            or evidence.get("acceptance_status") != "PASS"
        ):
            raise AdoptionError("DEPENDENCY_EVIDENCE", f"{task_id}: evidence identity or status")
        if not isinstance(evidence.get("platform"), dict) or not isinstance(
            evidence.get("toolchain"), dict
        ):
            raise AdoptionError("DEPENDENCY_EVIDENCE", f"{task_id}: environment identity")

        source_sha256 = evidence.get("source_sha256")
        if not isinstance(source_sha256, dict) or set(source_sha256) != set(task["source_paths"]):
            raise AdoptionError("DEPENDENCY_EVIDENCE", f"{task_id}: source inventory")
        for relative, expected in source_sha256.items():
            if not isinstance(expected, str) or len(expected) != 64 or any(
                character not in "0123456789abcdef" for character in expected
            ):
                raise AdoptionError("DEPENDENCY_EVIDENCE", f"{task_id}: source digest")
            if verify_current_sources:
                try:
                    path = repository_tooling.safe_path(
                        root, relative, "source_sha256", must_exist=True, file_only=True
                    )
                except repository_tooling.ContractError as error:
                    raise AdoptionError("DEPENDENCY_EVIDENCE", f"{task_id}: {error.code}") from error
                if expected != repository_text_sha256(path):
                    raise AdoptionError("STALE_SOURCE", f"{task_id}: {relative}")

        reports = evidence.get("reports")
        if not isinstance(reports, list) or not reports:
            raise AdoptionError("DEPENDENCY_EVIDENCE", f"{task_id}: reports")
        report_paths: set[str] = set()
        for item in reports:
            if not isinstance(item, dict) or set(item) != repository_tooling.REPORT_KEYS:
                raise AdoptionError("DEPENDENCY_EVIDENCE", f"{task_id}: report fields")
            relative = item.get("path")
            if not isinstance(relative, str) or relative in report_paths:
                raise AdoptionError("DEPENDENCY_EVIDENCE", f"{task_id}: report path")
            report_paths.add(relative)
            try:
                path = repository_tooling.safe_path(
                    root, relative, "report", must_exist=True, file_only=True
                )
            except repository_tooling.ContractError as error:
                raise AdoptionError("DEPENDENCY_EVIDENCE", f"{task_id}: {error.code}") from error
            if (
                item.get("source_task") != task_id
                or item.get("acceptance_status") != "PASS"
                or item.get("sha256") != sha256_path(path)
                or load_json(path).get("status") != "PASS"
            ):
                raise AdoptionError("DEPENDENCY_EVIDENCE", f"{task_id}: report not PASS or stale")
        evidence_path = f"docs/evidence/{task_id}/evidence.json"
        if set(task["required_evidence"]) - ({evidence_path} | report_paths):
            raise AdoptionError("DEPENDENCY_EVIDENCE", f"{task_id}: required evidence")

        native_reports: dict[str, str] = {}
        for validation_relative, report_relative, expected_mode in report_bindings:
            if validation_relative not in report_paths:
                raise AdoptionError("DEPENDENCY_EVIDENCE", f"{task_id}: validation not sealed")
            validation = load_json(root / validation_relative)
            report_path = root / report_relative
            report = load_json(report_path)
            if (
                validation.get("schema_version") != 1
                or validation.get("task_id") != task_id
                or validation.get("status") != "PASS"
                or validation.get("failures") != []
                or validation.get("report_sha256") != sha256_path(report_path)
                or report.get("schema_version") != 1
                or report.get("task_id") != task_id
                or report.get("decision") != "PASS"
                or validation.get("expected_revision") != report.get("revision")
                or (expected_mode is not None and validation.get("expected_mode") != expected_mode)
                or (expected_mode is not None and report.get("mode") != expected_mode)
            ):
                raise AdoptionError("DEPENDENCY_EVIDENCE", f"{task_id}: native report binding")
            if task_id == "M2-004":
                canonical_failures = m2_004_windows_resolver.validate_report(
                    report, str(report.get("revision", ""))
                )
            else:
                canonical_failures = m2_006_apple_resolver.validate_report(
                    report, str(report.get("revision", "")), str(expected_mode)
                )
            if canonical_failures:
                raise AdoptionError(
                    "DEPENDENCY_EVIDENCE",
                    f"{task_id}: canonical report validation {canonical_failures[0]}",
                )
            validate_native_source_binding(root, task_id, report, source_sha256)
            native_reports[report_relative] = sha256_path(report_path)
        validated[task_id] = {
            "native_reports": dict(sorted(native_reports.items())),
            "source_count": len(source_sha256),
            "source_verification": (
                "CURRENT_CHECKOUT" if verify_current_sources else "CURRENT_NATIVE_SOURCES"
            ),
            "status": "PASS",
        }
    return {"tasks": validated, "status": "PASS"}


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
    retained = validate_retained_evidence(root)
    dependency_evidence = validate_dependency_evidence(root, verify_current_sources=False)
    for relative in RETAINED_EVIDENCE + HISTORICAL_REFERENCES:
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
        "retained_evidence_validation": retained,
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
) -> dict[str, Any]:
    if core.get("schema_version") != 1 or core.get("status") != "PASS":
        raise AdoptionError("CORE_REQUIREMENT", "Core audit is not PASS")
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
    hosted = sub.add_parser("validate-hosted")
    hosted.add_argument("--input", type=Path, required=True)
    hosted.add_argument("--output", type=Path)
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
                root=args.root.resolve(),
                result_path=args.input.resolve(),
            )
        elif args.command == "validate-hosted":
            value = validate_hosted_run(args.root.resolve(), load_json(args.input))
        else:
            value = aggregate(
                load_json(args.core), load_json(args.windows), load_json(args.macos),
                args.expected_revision,
                root=args.root.resolve(),
                windows_path=args.windows.resolve(),
                macos_path=args.macos.resolve(),
            )
        _write_or_print(value, args.output)
        return 0
    except AdoptionError as error:
        print(json.dumps({"code": error.code, "detail": error.detail[:2048], "status": "FAIL"}, sort_keys=True))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
