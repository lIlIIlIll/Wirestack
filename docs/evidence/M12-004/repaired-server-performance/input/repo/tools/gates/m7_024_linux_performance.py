#!/usr/bin/env python3
from __future__ import annotations

if __package__ in {None, ""}:
    import sys
    from pathlib import Path
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from tools import evidence_digest

import argparse
import datetime as dt
import json
import math
import platform
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Mapping, Sequence


EXPECTED_DOMAINS = (
    "raw-tcp",
    "dns-to-connected",
    "tls",
    "http1",
    "http2",
    "cancellation",
    "sse",
    "memory",
)
EXPECTED_ARTIFACTS = (
    "raw_tcp",
    "cancellation",
    "dns_to_connected",
    "tls",
    "http1",
    "http2",
    "sse",
)
HTTP2_SOURCE_DIRECTORIES = (
    "src/internal/http1",
    "src/internal/http2",
    "src/internal/http_model",
    "src/internal/transport",
)


class GateError(Exception):
    pass


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat()


def http2_source_sha256(root: Path) -> str:
    paths: list[Path] = []
    for directory in HTTP2_SOURCE_DIRECTORIES:
        paths.extend(
            path for path in (root / directory).glob("*.cj")
            if not path.name.endswith("_test.cj")
        )
    if not paths:
        raise GateError("HTTP/2 production source inventory is empty")
    return evidence_digest.text_evidence_inventory_sha256(root, paths)


def checked_path(root: Path, relative: str) -> Path:
    if not isinstance(relative, str) or not relative:
        raise GateError("artifact path must be a non-empty string")
    root = root.resolve()
    path = (root / relative).resolve()
    try:
        path.relative_to(root)
    except ValueError as error:
        raise GateError(f"artifact path escapes repository: {relative}") from error
    if not path.is_file():
        raise GateError(f"artifact is not a file: {relative}")
    return path


def reject_constant(value: str) -> None:
    raise GateError(f"non-finite JSON value: {value}")


def assert_finite(value: Any, location: str = "root") -> None:
    if isinstance(value, float) and not math.isfinite(value):
        raise GateError(f"non-finite number at {location}")
    if isinstance(value, list):
        for index, item in enumerate(value):
            assert_finite(item, f"{location}[{index}]")
    elif isinstance(value, dict):
        for key, item in value.items():
            assert_finite(item, f"{location}.{key}")


def load_json(path: Path) -> Any:
    try:
        value = json.loads(path.read_text(encoding="utf-8"), parse_constant=reject_constant)
    except GateError:
        raise
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise GateError(f"cannot parse JSON {path}: {error}") from error
    assert_finite(value)
    return value


def exact_names(values: Sequence[Any]) -> tuple[str, ...]:
    return tuple(str(value) for value in values)


def as_number(value: Any, name: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise GateError(f"{name} must be a finite number")
    if not math.isfinite(float(value)):
        raise GateError(f"{name} must be finite")
    return float(value)


def as_int(value: Any, name: str) -> int:
    if isinstance(value, bool):
        raise GateError(f"{name} must be an integer")
    if isinstance(value, str):
        try:
            parsed = int(value)
        except ValueError as error:
            raise GateError(f"{name} must be an integer") from error
        return parsed
    if not isinstance(value, int):
        raise GateError(f"{name} must be an integer")
    return value


def compare(actual: Any, operator: str, expected: Any) -> bool:
    if operator == "eq":
        return actual == expected
    left = as_number(actual, "actual")
    right = as_number(expected, "expected")
    if operator == "ge":
        return left >= right
    if operator == "le":
        return left <= right
    raise GateError(f"unknown comparison operator: {operator}")


@dataclass
class DomainResult:
    name: str
    checks: list[dict[str, Any]] = field(default_factory=list)
    metrics: dict[str, Any] = field(default_factory=dict)

    def check(self, name: str, actual: Any, operator: str, expected: Any) -> bool:
        try:
            passed = compare(actual, operator, expected)
        except GateError as error:
            passed = False
            actual = f"INVALID: {error}"
        self.checks.append({
            "name": name,
            "operator": operator,
            "expected": expected,
            "actual": actual,
            "decision": "PASS" if passed else "FAIL",
        })
        return passed

    def fail(self, name: str, reason: str) -> None:
        self.checks.append({
            "name": name,
            "operator": "valid",
            "expected": True,
            "actual": reason,
            "decision": "FAIL",
        })

    def report(self) -> dict[str, Any]:
        decision = "PASS" if self.checks and all(
            item["decision"] == "PASS" for item in self.checks
        ) else "FAIL"
        return {
            "name": self.name,
            "decision": decision,
            "checks": self.checks,
            "metrics": self.metrics,
        }


def validate_manifest(manifest: Mapping[str, Any]) -> None:
    if manifest.get("schema_version") != 1:
        raise GateError("unsupported manifest schema")
    if manifest.get("gate_id") != "M7-024-LINUX-PERFORMANCE":
        raise GateError("unexpected gate id")
    if manifest.get("profile") != "linux-glibc-x86_64":
        raise GateError("unexpected performance profile")
    if exact_names(manifest.get("domains", [])) != EXPECTED_DOMAINS:
        raise GateError("manifest must contain the exact ordered eight-domain inventory")
    artifacts = manifest.get("artifacts")
    if not isinstance(artifacts, dict) or tuple(artifacts.keys()) != EXPECTED_ARTIFACTS:
        raise GateError("manifest must contain the exact ordered artifact inventory")
    for name, artifact in artifacts.items():
        if not isinstance(artifact, dict):
            raise GateError(f"artifact entry is not an object: {name}")
        digest = artifact.get("sha256")
        if not isinstance(digest, str) or len(digest) != 64 or any(
            character not in "0123456789abcdef" for character in digest
        ):
            raise GateError(f"invalid artifact digest: {name}")
    http2_source = artifacts["http2"].get("source_sha256")
    if not isinstance(http2_source, str) or len(http2_source) != 64 or any(
        character not in "0123456789abcdef" for character in http2_source
    ):
        raise GateError("invalid HTTP/2 production source digest")
    if not isinstance(manifest.get("thresholds"), dict):
        raise GateError("manifest thresholds are missing")


def load_manifest(root: Path, path: Path) -> Mapping[str, Any]:
    manifest_path = path.resolve()
    try:
        manifest_path.relative_to(root.resolve())
    except ValueError as error:
        raise GateError("manifest path escapes repository") from error
    value = load_json(manifest_path)
    if not isinstance(value, dict):
        raise GateError("manifest root must be an object")
    validate_manifest(value)
    return value


def load_artifacts(root: Path, manifest: Mapping[str, Any]) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    documents: dict[str, Any] = {}
    inventory: list[dict[str, Any]] = []
    for name, artifact in manifest["artifacts"].items():
        path = checked_path(root, artifact["path"])
        actual_digest = evidence_digest.text_evidence_sha256(path)
        if not evidence_digest.schema_text_sha256_equal(
            actual_digest, artifact["sha256"],
        ):
            raise GateError(
                f"artifact digest mismatch for {name}: expected {artifact['sha256']}, "
                f"actual {actual_digest}"
            )
        documents[name] = load_json(path)
        inventory.append({
            "name": name,
            "path": artifact["path"],
            "sha256": actual_digest,
            "bytes": path.stat().st_size,
            "decision": "PASS",
        })
    return documents, inventory


def run_validator(name: str, validator: Callable[[], DomainResult]) -> dict[str, Any]:
    try:
        return validator().report()
    except (GateError, KeyError, IndexError, TypeError, ValueError) as error:
        result = DomainResult(name)
        result.fail("schema-and-values", str(error))
        return result.report()


def check_toolchain(result: DomainResult, prefix: str, cjc: str, cjpm: str,
                    expected: Mapping[str, Any]) -> None:
    result.check(f"{prefix} Cangjie version", expected["cangjie"] in cjc, "eq", True)
    result.check(f"{prefix} target", expected["target"] in cjc, "eq", True)
    result.check(f"{prefix} CJPM version", expected["cjpm"] in cjpm, "eq", True)


def validate_raw_tcp(document: Mapping[str, Any], limits: Mapping[str, Any],
                     expected_environment: Mapping[str, Any] | None = None) -> DomainResult:
    result = DomainResult("raw-tcp")
    result.check("source decision", document["linux_profile_status"], "eq", "PASS")
    configuration = document["configuration"]
    result.check("release process shape", configuration["comparison_process_shape"], "eq", "same_unittest_binary")
    result.check("measured rounds", configuration["repetitions"], "eq", limits["measured_rounds"])
    result.check("warmup rounds", configuration["warmup"], "eq", limits["warmup_rounds"])
    if expected_environment is not None:
        environment = document["environment"]
        result.check("Linux x86_64 glibc environment", expected_environment["system"] in environment["os"] and expected_environment["machine"] in environment["os"] and expected_environment["libc"] in environment["os"], "eq", True)
        result.check("architecture", environment["architecture"], "eq", expected_environment["machine"])
        check_toolchain(result, "raw TCP", environment["cjc"], environment["cjpm"], expected_environment)
    cases = document["cases"]
    payloads = [case["payload_bytes"] for case in cases]
    result.check("payload inventory", payloads, "eq", limits["payload_bytes"])
    metrics: list[dict[str, Any]] = []
    for case in cases:
        label = case["name"]
        comparison = case["comparison"]
        result.check(f"{label} decision", case["decision"], "eq", "PASS")
        result.check(f"{label} samples", case["sample_count_per_implementation"], "eq", limits["measured_rounds"])
        result.check(f"{label} paired order", len(case["paired_order"]), "eq", limits["measured_rounds"])
        result.check(f"{label} std.net raw samples", len(case["std_net"]["samples"]), "eq", limits["measured_rounds"])
        result.check(f"{label} adapter raw samples", len(case["stdnet_transport"]["samples"]), "eq", limits["measured_rounds"])
        result.check(f"{label} throughput ratio", comparison["throughput_ratio"], "ge", limits["minimum_throughput_ratio"])
        result.check(f"{label} P95 latency ratio", comparison["p95_latency_ratio"], "le", limits["maximum_p95_latency_ratio"])
        instrumented = case["stdnet_transport"]["instrumented_sample"]
        result.check(f"{label} staging read bytes", instrumented["adapter_staging_copied_read_bytes"], "le", limits["maximum_staging_copied_bytes"])
        result.check(f"{label} staging write bytes", instrumented["adapter_staging_copied_write_bytes"], "le", limits["maximum_staging_copied_bytes"])
        metrics.append({
            "payload_bytes": case["payload_bytes"],
            "throughput_ratio": comparison["throughput_ratio"],
            "p95_latency_ratio": comparison["p95_latency_ratio"],
        })
    result.metrics["cases"] = metrics
    return result


def validate_dns(document: Mapping[str, Any], limits: Mapping[str, Any],
                 expected_environment: Mapping[str, Any] | None = None) -> DomainResult:
    result = DomainResult("dns-to-connected")
    result.check("source decision", document["decision"], "eq", "PASS")
    result.check("platform scope", document["platform_scope"], "eq", "linux-glibc-x86_64")
    benchmark = document["benchmark"]
    result.check("optimization", benchmark["build_compile_option"], "eq", "-O2")
    result.check("measured rounds", benchmark["measured_rounds"], "eq", limits["measured_rounds"])
    result.check("samples per round", benchmark["samples_per_round"], "eq", limits["samples_per_round"])
    result.check("samples per profile", benchmark["samples_per_profile"], "eq", limits["samples_per_profile"])
    if expected_environment is not None:
        environment = document["environment"]
        result.check("system", environment["uname"]["system"], "eq", expected_environment["system"])
        result.check("machine", environment["uname"]["machine"], "eq", expected_environment["machine"])
        result.check("libc", environment["libc"], "eq", [expected_environment["libc"], expected_environment["libc_version"]])
        check_toolchain(result, "DNS", environment["cjc"], environment["cjpm"], expected_environment)
    profiles = document["profiles"]
    names = list(profiles.keys())
    result.check("profile inventory", names, "eq", limits["profiles"])
    metrics: dict[str, Any] = {}
    for name, profile_data in profiles.items():
        observed_names = sorted({
            sample["profile"]
            for round_data in profile_data["rounds"]
            for sample in round_data["samples"]
        })
        result.check(f"{name} sample identity", observed_names, "eq", [name])
        result.check(f"{name} decision", profile_data["decision"], "eq", "PASS")
        result.check(f"{name} round count", len(profile_data["rounds"]), "eq", limits["measured_rounds"])
        result.check(f"{name} round samples", [len(item["samples"]) for item in profile_data["rounds"]], "eq", [limits["samples_per_round"]] * limits["measured_rounds"])
        result.check(f"{name} aggregate samples", profile_data["aggregate"]["sample_count"], "eq", limits["samples_per_profile"])
        metrics[name] = {
            "total_p50_ns": profile_data["aggregate"]["total_ns"]["p50"],
            "total_p95_ns": profile_data["aggregate"]["total_ns"]["p95"],
            "total_p99_ns": profile_data["aggregate"]["total_ns"]["p99"],
        }
        if name == "cancellation":
            p99 = profile_data["aggregate"]["cancellation_ns"]["p99"]
            result.check("DNS cancellation P99", p99, "le", limits["maximum_cancellation_p99_ns"])
            metrics[name]["cancellation_p99_ns"] = p99
    result.metrics["profiles"] = metrics
    return result


def validate_tls(document: Mapping[str, Any], limits: Mapping[str, Any],
                 expected_environment: Mapping[str, Any] | None = None) -> DomainResult:
    result = DomainResult("tls")
    decision = document["decision"]
    result.check("source decision", decision["decision"], "eq", "PASS")
    result.check("Linux glibc environment", "Linux" in document["environment"]["platform"] and "glibc2.44" in document["environment"]["platform"], "eq", True)
    if expected_environment is not None:
        platform_name = document["environment"]["platform"]
        result.check("TLS system", expected_environment["system"] in platform_name, "eq", True)
        result.check("TLS machine", expected_environment["machine"] in platform_name, "eq", True)
        result.check("TLS libc", f"{expected_environment['libc']}{expected_environment['libc_version']}" in platform_name, "eq", True)
    checks = decision["checks"]
    pairs = (
        ("bulk throughput ratio", "bulk_ratio", "ge", "minimum_bulk_throughput_ratio"),
        ("full handshake P50 ratio", "full_p50_ratio", "le", "maximum_full_handshake_p50_ratio"),
        ("full handshake P95 ratio", "full_p95_ratio", "le", "maximum_full_handshake_p95_ratio"),
    )
    for label, key, operator, threshold in pairs:
        result.check(label, checks[key]["value"], operator, limits[threshold])
        result.check(f"{label} source decision", checks[key]["decision"], "eq", "PASS")
    for case_name in ("bulk_tls13", "full_tls13"):
        case = document["cases"][case_name]
        result.check(f"{case_name} Wirestack rounds", len(case["wirestack"]), "eq", limits["measured_rounds"])
        result.check(f"{case_name} stdx rounds", len(case["stdx"]), "eq", limits["measured_rounds"])
    resumed = document["resumed"]
    result.check("resumed rounds", len(resumed), "ge", limits["minimum_resumed_rounds"])
    result.check("all resumed rounds reused a session", all(item["resumed"] is True for item in resumed), "eq", True)
    memory = document["memory"]
    body = memory["body_scaling"]
    idle = memory["idle_connections"]
    result.check("memory decision", memory["decision"], "eq", "PASS")
    result.check("body peak growth", body["peak_growth_kib"], "le", limits["maximum_body_growth_kib"])
    result.check("body growth ratio", body["growth_per_payload_kib"], "le", limits["maximum_body_growth_ratio"])
    result.check("idle KiB per connection", idle["slope_kib_per_connection"], "le", limits["maximum_idle_kib_per_connection"])
    result.metrics.update({
        "bulk_throughput_ratio": checks["bulk_ratio"]["value"],
        "full_handshake_p50_ratio": checks["full_p50_ratio"]["value"],
        "full_handshake_p95_ratio": checks["full_p95_ratio"]["value"],
        "resumed_rounds": len(resumed),
        "body_peak_growth_kib": body["peak_growth_kib"],
        "idle_kib_per_connection": idle["slope_kib_per_connection"],
    })
    return result


def validate_http1(document: Mapping[str, Any], limits: Mapping[str, Any],
                   expected_environment: Mapping[str, Any] | None = None) -> DomainResult:
    result = DomainResult("http1")
    result.check("source decision", document["decision"], "eq", "PASS")
    configuration = document["configuration"]
    result.check("optimization", configuration["optimization"], "eq", "-O2")
    result.check("alternating measured rounds", configuration["rounds"], "eq", limits["measured_rounds"])
    if expected_environment is not None:
        platform_data = document["platform"]
        result.check("HTTP/1 system", platform_data["system"], "eq", expected_environment["system"])
        result.check("HTTP/1 machine", platform_data["machine"], "eq", expected_environment["machine"])
        result.check("HTTP/1 stdx compile optimization", expected_environment["optimization"] in document["stdx_reference"]["compile_command"], "eq", True)
    comparison = document["stdx_comparison"]
    result.check("throughput decision", comparison["decision"], "eq", "PASS")
    result.check("throughput ratio", comparison["ratio"], "ge", limits["minimum_throughput_ratio"])
    result.check("Wirestack raw rounds", document["cases"]["keep_alive_small"]["round_count"], "eq", limits["measured_rounds"])
    result.check("stdx raw rounds", comparison["stdx_rounds"]["round_count"], "eq", limits["measured_rounds"])
    streamed = [document["cases"]["stream_16mib"]["bytes"], document["cases"]["stream_64mib"]["bytes"]]
    result.check("streamed body inventory", streamed, "eq", limits["streamed_body_bytes"])
    memory = document["streaming_memory"]
    result.check("memory decision", memory["decision"], "eq", "PASS")
    result.check("RSS growth", memory["rss_growth_kib"], "le", limits["maximum_rss_growth_kib"])
    result.check("RSS ratio", memory["rss_ratio"], "le", limits["maximum_rss_ratio"])
    result.metrics.update({
        "wirestack_requests_per_second": comparison["wirestack_requests_per_second"],
        "stdx_requests_per_second": comparison["stdx_requests_per_second"],
        "throughput_ratio": comparison["ratio"],
        "rss_growth_kib": memory["rss_growth_kib"],
        "rss_ratio": memory["rss_ratio"],
    })
    return result


def validate_http2(document: Mapping[str, Any], limits: Mapping[str, Any],
                   expected_environment: Mapping[str, Any] | None = None,
                   expected_source_sha256: str | None = None,
                   current_source_sha256: str | None = None) -> DomainResult:
    result = DomainResult("http2")
    result.check("source decision", document["decision"], "eq", "PASS")
    method = document["method"]
    result.check("measured rounds per pass", method["measured_rounds_per_pass"], "eq", limits["measured_rounds_per_pass"])
    result.check("pass count", len(method["pass_order"]), "eq", limits["passes"])
    if expected_environment is not None:
        platform_data = document["platform"]
        result.check("HTTP/2 system", platform_data["system"], "eq", expected_environment["system"])
        result.check("HTTP/2 machine", platform_data["machine"], "eq", expected_environment["machine"])
        check_toolchain(result, "HTTP/2", document["toolchain"]["cjc"], document["toolchain"]["cjpm"], expected_environment)
    if expected_source_sha256 is not None:
        result.check(
            "HTTP/2 report production source digest",
            document["source"]["production_source_sha256"],
            "eq",
            expected_source_sha256,
        )
        result.check(
            "HTTP/2 current production source digest",
            current_source_sha256,
            "eq",
            expected_source_sha256,
        )
    reduction = document["connection_reduction"]
    result.check("connection reduction decision", reduction["decision"], "eq", "PASS")
    result.check("HTTP/2 connection ratio", reduction["ratio"], "le", limits["maximum_connection_ratio"])
    cases = document["cases"]
    expected_keys = [f"streams_{value}" for value in limits["concurrency"]]
    result.check("concurrency inventory", list(cases.keys()), "eq", expected_keys)
    metrics: dict[str, Any] = {}
    for concurrency in limits["concurrency"]:
        key = f"streams_{concurrency}"
        case = cases[key]
        result.check(f"{key} concurrency", case["concurrency"], "eq", concurrency)
        result.check(f"{key} connections", case["connections"], "eq", 1)
        result.check(f"{key} measured requests", case["measured_requests"], "eq", limits["passes"] * limits["measured_rounds_per_pass"] * concurrency)
        result.check(f"{key} raw passes", len(case["raw_passes"]), "eq", limits["passes"])
        result.check(f"{key} queue writes", case["maximum_pending_writes"], "le", limits["maximum_pending_writes"])
        result.check(f"{key} queue bytes", case["maximum_pending_write_bytes"], "le", limits["maximum_pending_write_bytes"])
        result.check(f"{key} flow permits", case["maximum_observed_pending_flow_permits"], "le", limits["maximum_outstanding_flow_permits"])
        for pass_index, raw_pass in enumerate(case["raw_passes"]):
            result.check(f"{key} pass {pass_index + 1} request samples", len(raw_pass["latencies_ns"]), "eq", limits["measured_rounds_per_pass"] * concurrency)
            result.check(f"{key} pass {pass_index + 1} bounded writes", raw_pass["pending_writes"], "le", limits["maximum_pending_writes"])
            result.check(f"{key} pass {pass_index + 1} terminal flow permits", raw_pass["pending_flow_permits"], "eq", 0)
        metrics[key] = {
            "requests_per_second": case["requests_per_second"],
            "p50_latency_ns": case["p50_latency_ns"],
            "p95_latency_ns": case["p95_latency_ns"],
            "p99_latency_ns": case["p99_latency_ns"],
            "connections": case["connections"],
            "peak_rss_kib": case["peak_rss_kib"],
        }
    result.metrics["cases"] = metrics
    result.metrics["connection_ratio"] = reduction["ratio"]
    return result


def validate_cancellation(document: Mapping[str, Any], limits: Mapping[str, Any],
                          expected_environment: Mapping[str, Any] | None = None) -> DomainResult:
    result = DomainResult("cancellation")
    result.check("source decision", document["decision"], "eq", "PASS")
    configuration = document["configuration"]
    result.check("warmup samples", configuration["warmup"], "eq", limits["warmup_samples"])
    result.check("measured samples", configuration["repetitions"], "eq", limits["measured_samples"])
    if expected_environment is not None:
        result.check("cancellation profile", document["platform"], "eq", "linux-x86_64-glibc")
    summary = document["cancellation"]["summary"]
    result.check("scenario inventory", list(summary.keys()), "eq", limits["scenarios"])
    metrics: dict[str, Any] = {}
    for scenario in limits["scenarios"]:
        item = summary[scenario]
        result.check(f"{scenario} decision", item["decision"], "eq", "PASS")
        result.check(f"{scenario} sample count", item["sample_count"], "eq", limits["measured_samples"])
        result.check(f"{scenario} P99", item["p99_ns"], "le", limits["maximum_p99_ns"])
        measured = [sample for sample in item["samples"] if sample["measured"]]
        result.check(f"{scenario} retained measured samples", len(measured), "eq", limits["measured_samples"])
        result.check(f"{scenario} typed terminals", all(sample["terminal"] == "cancelled" and sample["completed"] is True for sample in measured), "eq", True)
        metrics[scenario] = {
            "p50_ns": item["p50_ns"],
            "p95_ns": item["p95_ns"],
            "p99_ns": item["p99_ns"],
            "max_ns": item["max_ns"],
        }
    result.metrics["scenarios"] = metrics
    return result


def validate_sse(document: Mapping[str, Any], limits: Mapping[str, Any],
                 expected_environment: Mapping[str, Any] | None = None) -> DomainResult:
    result = DomainResult("sse")
    result.check("source decision", document["decision"], "eq", "PASS")
    result.check("formal parameters", document["formal_parameters_met"], "eq", True)
    parameters = document["parameters"]
    result.check("duration parameter", parameters["duration_seconds"], "ge", limits["minimum_duration_seconds"])
    result.check("event parameter", parameters["minimum_events"], "ge", limits["minimum_events"])
    if expected_environment is not None:
        environment = document["environment"]
        result.check("SSE system", expected_environment["system"] in environment["platform"], "eq", True)
        result.check("SSE machine", expected_environment["machine"] in environment["platform"], "eq", True)
        result.check("SSE libc", f"{expected_environment['libc']}{expected_environment['libc_version']}" in environment["platform"], "eq", True)
        check_toolchain(result, "SSE", environment["cjc"], environment["cjpm"], expected_environment)
    profiles = document["profiles"]
    result.check("protocol inventory", [profile_data["protocol"] for profile_data in profiles], "eq", limits["protocols"])
    metrics: dict[str, Any] = {}
    for profile_data in profiles:
        protocol = profile_data["protocol"]
        observed = profile_data["result"]
        trend = profile_data["resources"]["trend"]
        result.check(f"{protocol} decision", profile_data["decision"], "eq", "PASS")
        result.check(f"{protocol} elapsed seconds", as_int(observed["elapsedMs"], f"{protocol}.elapsedMs") // 1000, "ge", limits["minimum_duration_seconds"])
        result.check(f"{protocol} events", as_int(observed["events"], f"{protocol}.events"), "ge", limits["minimum_events"])
        result.check(f"{protocol} cancellation latency", as_int(observed["cancelLatencyNs"], f"{protocol}.cancelLatencyNs"), "le", limits["maximum_cancel_latency_ns"])
        result.check(f"{protocol} sequence errors", as_int(observed["sequenceErrors"], f"{protocol}.sequenceErrors"), "le", limits["maximum_sequence_errors"])
        result.check(f"{protocol} application pending bytes", as_int(observed["applicationPendingBytes"], f"{protocol}.applicationPendingBytes"), "le", limits["maximum_application_pending_bytes"])
        result.check(f"{protocol} resource samples", trend["sample_count"], "ge", limits["minimum_resource_samples"])
        result.check(f"{protocol} FD growth", trend["fd_count"]["growth"], "le", limits["maximum_fd_growth"])
        result.check(f"{protocol} socket growth", trend["socket_count"]["growth"], "le", limits["maximum_socket_growth"])
        result.check(f"{protocol} thread growth", trend["thread_count"]["growth"], "le", limits["maximum_thread_growth"])
        result.check(f"{protocol} RSS growth", trend["rss_kib"]["growth"], "le", limits["maximum_rss_growth_kib"])
        metrics[protocol] = {
            "elapsed_ms": as_int(observed["elapsedMs"], f"{protocol}.elapsedMs"),
            "events": as_int(observed["events"], f"{protocol}.events"),
            "cancel_latency_ns": as_int(observed["cancelLatencyNs"], f"{protocol}.cancelLatencyNs"),
            "resource_samples": trend["sample_count"],
            "rss_growth_kib": trend["rss_kib"]["growth"],
        }
    result.metrics["profiles"] = metrics
    return result


def validate_memory(documents: Mapping[str, Any], manifest: Mapping[str, Any]) -> DomainResult:
    result = DomainResult("memory")
    net06 = documents["cancellation"]["net06"]
    result.check("Transport resource decision", net06["decision"], "eq", "PASS")
    result.check("Transport measured resource classes", len(net06["measured_resource_classes"]), "ge", 8)
    tls_limits = manifest["thresholds"]["tls"]
    tls_memory = documents["tls"]["memory"]
    result.check("TLS memory decision", tls_memory["decision"], "eq", "PASS")
    result.check("TLS body growth", tls_memory["body_scaling"]["peak_growth_kib"], "le", tls_limits["maximum_body_growth_kib"])
    result.check("TLS idle slope", tls_memory["idle_connections"]["slope_kib_per_connection"], "le", tls_limits["maximum_idle_kib_per_connection"])
    h1_limits = manifest["thresholds"]["http1"]
    h1_memory = documents["http1"]["streaming_memory"]
    result.check("HTTP/1 memory decision", h1_memory["decision"], "eq", "PASS")
    result.check("HTTP/1 RSS growth", h1_memory["rss_growth_kib"], "le", h1_limits["maximum_rss_growth_kib"])
    h2_limits = manifest["thresholds"]["http2"]
    for name, case in documents["http2"]["cases"].items():
        result.check(f"{name} pending writes", case["maximum_pending_writes"], "le", h2_limits["maximum_pending_writes"])
        result.check(f"{name} pending bytes", case["maximum_pending_write_bytes"], "le", h2_limits["maximum_pending_write_bytes"])
        result.check(f"{name} flow permits", case["maximum_observed_pending_flow_permits"], "le", h2_limits["maximum_outstanding_flow_permits"])
    sse_limits = manifest["thresholds"]["sse"]
    for profile_data in documents["sse"]["profiles"]:
        protocol = profile_data["protocol"]
        trend = profile_data["resources"]["trend"]
        result.check(f"SSE {protocol} resource trend", trend["decision"], "eq", "PASS")
        result.check(f"SSE {protocol} RSS growth", trend["rss_kib"]["growth"], "le", sse_limits["maximum_rss_growth_kib"])
    result.metrics.update({
        "transport_resource_classes": len(net06["measured_resource_classes"]),
        "tls_body_growth_kib": tls_memory["body_scaling"]["peak_growth_kib"],
        "tls_idle_kib_per_connection": tls_memory["idle_connections"]["slope_kib_per_connection"],
        "http1_rss_growth_kib": h1_memory["rss_growth_kib"],
        "http2_peak_rss_kib": {name: case["peak_rss_kib"] for name, case in documents["http2"]["cases"].items()},
        "sse_rss_growth_kib": {profile_data["protocol"]: profile_data["resources"]["trend"]["rss_kib"]["growth"] for profile_data in documents["sse"]["profiles"]},
    })
    return result


def evaluate(root: Path, manifest: Mapping[str, Any]) -> dict[str, Any]:
    documents, artifacts = load_artifacts(root, manifest)
    thresholds = manifest["thresholds"]
    environment = manifest["environment"]
    validators: list[tuple[str, Callable[[], DomainResult]]] = [
        ("raw-tcp", lambda: validate_raw_tcp(documents["raw_tcp"], thresholds["raw_tcp"], environment)),
        ("dns-to-connected", lambda: validate_dns(documents["dns_to_connected"], thresholds["dns_to_connected"], environment)),
        ("tls", lambda: validate_tls(documents["tls"], thresholds["tls"], environment)),
        ("http1", lambda: validate_http1(documents["http1"], thresholds["http1"], environment)),
        ("http2", lambda: validate_http2(
            documents["http2"], thresholds["http2"], environment,
            manifest["artifacts"]["http2"]["source_sha256"],
            http2_source_sha256(root),
        )),
        ("cancellation", lambda: validate_cancellation(documents["cancellation"], thresholds["cancellation"], environment)),
        ("sse", lambda: validate_sse(documents["sse"], thresholds["sse"], environment)),
        ("memory", lambda: validate_memory(documents, manifest)),
    ]
    domains = [run_validator(name, validator) for name, validator in validators]
    decision = "PASS" if all(domain["decision"] == "PASS" for domain in domains) else "FAIL"
    return {
        "schema_version": 1,
        "gate_id": manifest["gate_id"],
        "profile": manifest["profile"],
        "decision": decision,
        "generated_at_utc": utc_now(),
        "manifest_environment": manifest["environment"],
        "evaluation_environment": {
            "system": platform.system(),
            "machine": platform.machine(),
            "libc": list(platform.libc_ver()),
        },
        "artifacts": artifacts,
        "domains": domains,
        "failed_domains": [domain["name"] for domain in domains if domain["decision"] != "PASS"],
    }


def failure_report(manifest_path: Path, reason: str) -> dict[str, Any]:
    return {
        "schema_version": 1,
        "gate_id": "M7-024-LINUX-PERFORMANCE",
        "profile": "linux-glibc-x86_64",
        "decision": "FAIL",
        "generated_at_utc": utc_now(),
        "manifest": str(manifest_path),
        "gate_errors": [reason],
        "artifacts": [],
        "domains": [],
        "failed_domains": list(EXPECTED_DOMAINS),
    }


def write_report(path: Path, report: Mapping[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    temporary.replace(path)


def main(argv: Sequence[str] | None = None) -> int:
    root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--manifest",
        type=Path,
        default=root / "tools/gates/campaigns/m7-024-linux-performance.json",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=root / "docs/evidence/M7-024/linux_glibc_x86_64/performance-gate.json",
    )
    args = parser.parse_args(argv)
    try:
        manifest = load_manifest(root, args.manifest)
        report = evaluate(root, manifest)
    except GateError as error:
        report = failure_report(args.manifest, str(error))
    write_report(args.output.resolve(), report)
    print(json.dumps({
        "gate_id": report["gate_id"],
        "decision": report["decision"],
        "failed_domains": report["failed_domains"],
        "output": str(args.output.resolve()),
    }, sort_keys=True))
    return 0 if report["decision"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
