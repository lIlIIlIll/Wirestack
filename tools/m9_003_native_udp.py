#!/usr/bin/env python3
"""Qualify installed UDP lifecycle behavior and the current Linux network contract."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from tools import check_network_capabilities as capabilities
from tools import development_baseline
from tools import m7_021_linux_release as release
from tools import m8_005_native_http as installed_support
from tools import m9_001_native_capabilities as support
from tools.evidence_digest import TextEvidenceDigest, artifact_byte_digest, text_evidence_digest

TASK = "M9-003"
PLATFORM = "linux-x86_64-glibc"
SOURCE = ROOT / "examples/linux/m9_003/udp_lifecycle.cj"
DEFAULT_OUTPUT = ROOT / "docs/evidence/M9-003/native-udp"
DEFAULT_REPORT = ROOT / "docs/evidence/M9-003/native-udp.json"
SCENARIOS = (
    *support.SCENARIO_IDS,
    "socket-options",
    "http-option-connector",
    "invalid-option-admission",
    "active-send-control",
    "udp-disconnect",
    "udp-broadcast",
    "udp-multicast-ipv4",
    "udp-multicast-ipv6",
    "udp-membership-errors",
    "udp-active-receive",
    "udp-active-send",
)
UDP_CASES = (
    ("udp-disconnect", "disconnect", "M9_003_DISCONNECT_PASS"),
    ("udp-broadcast", "broadcast", "M9_003_BROADCAST_PASS"),
    ("udp-multicast-ipv4", "ipv4-multicast", "M9_003_IPV4_MULTICAST_PASS"),
    ("udp-multicast-ipv6", "ipv6-multicast", "M9_003_IPV6_MULTICAST_PASS"),
    ("udp-membership-errors", "membership-cleanup", "M9_003_MEMBERSHIP_ERRORS_CLEANUP_PASS"),
    ("udp-active-receive", "active-receive", "M9_003_DISCONNECT_ACTIVE_RECEIVE_PASS"),
    ("udp-active-send", "active-send", "M9_003_DISCONNECT_ACTIVE_SEND_PASS"),
)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def relative(path: Path) -> str:
    return path.resolve().relative_to(ROOT).as_posix()


def bounded_path(path: Path, label: str) -> Path:
    resolved = path.resolve()
    try:
        relative_path = resolved.relative_to(ROOT)
    except ValueError as error:
        raise ValueError(f"{label} must remain under the repository root") from error
    if relative_path.parts[:2] == ("docs", "evidence") and (
        len(relative_path.parts) < 3 or relative_path.parts[2] != TASK
    ):
        raise ValueError(f"{label} must not rewrite another task's evidence")
    if resolved in {Path(__file__).resolve(), SOURCE.resolve()}:
        raise ValueError(f"{label} must not overwrite qualification sources")
    return resolved


def ipv4_loopback_index() -> int:
    try:
        return socket.if_nametoindex("lo")
    except OSError as error:
        raise support.EnvironmentFailure("native IPv4 loopback interface is unavailable") from error


def ipv6_link_local_index() -> int:
    try:
        entries = Path("/proc/net/if_inet6").read_text(encoding="ascii").splitlines()
    except OSError as error:
        raise support.EnvironmentFailure("native IPv6 interface inventory is unavailable") from error
    for entry in entries:
        fields = entry.split()
        if len(fields) < 5:
            continue
        address, index, _, scope, _ = fields[:5]
        if address.lower().startswith("fe80") and scope.lower() == "20":
            value = int(index, 16)
            if value > 0:
                return value
    raise support.EnvironmentFailure("native link-local IPv6 multicast interface is unavailable")


def with_environment(values: dict[str, str], operation) -> None:
    previous = {name: os.environ.get(name) for name in values}
    os.environ.update(values)
    try:
        operation()
    finally:
        for name, value in previous.items():
            if value is None:
                os.environ.pop(name, None)
            else:
                os.environ[name] = value


def validate_marker(path: Path, marker: str) -> None:
    installed_support.validate_marker(path, marker)


def profile_consumers(binaries: dict[str, Path], output: Path, commands: list[dict],
                      scenarios: list[dict], report: dict) -> None:
    directories = {name: output / name for name in ("internet", "unix", "dns", "contract", "options", "udp")}
    for directory in directories.values():
        directory.mkdir(parents=True, exist_ok=True)
    support.ensure_ipv6_loopback()
    for scenario, mode in (("internet-ipv4", "ipv4"), ("internet-ipv6", "ipv6")):
        details = support.run_scenario(scenarios, scenario,
            lambda mode=mode: support.internet_support.profile(binaries["internet"], directories["internet"], mode))
        if details is not None:
            support.record_profile_command(commands, scenario, details)
    for scenario, mode in (("unix-pathname", "pathname"), ("unix-abstract", "abstract")):
        details = support.run_scenario(scenarios, scenario,
            lambda mode=mode: support.unix_support.profile(binaries["unix"], directories["unix"], mode))
        if details is not None:
            support.record_profile_command(commands, scenario, details)
    details = support.run_scenario(scenarios, "capability-contract",
        lambda: support.capability_profile(binaries["capabilities"], directories["contract"])[0])
    if details is not None:
        observed, instances = support.parse_capability_observations(
            (directories["contract"] / "capability-contract.stdout.log").read_text(encoding="utf-8").splitlines())
        report["observed_capabilities"] = observed
        report["capability_observations"] = instances
        support.record_profile_command(commands, "capability-contract", details)
    support.run_scenario(scenarios, "dns-basic", lambda: support.dns_support.run_case(
        binaries["dns"], directories["dns"], commands, "basic", support.dns_support.basic_fixture))
    support.run_scenario(scenarios, "dns-connect", lambda: support.dns_support.run_connect_case(
        binaries["dns"], directories["dns"], commands))

    for scenario, mode, marker in (
        ("socket-options", "options", "M9_002_OPTIONS_PASS"),
        ("http-option-connector", "http", "M9_002_HTTP_CONNECTOR_PASS"),
        ("invalid-option-admission", "invalid", "M9_002_INVALID_ADMISSION_PASS"),
        ("active-send-control", "send-control", "M9_002_SEND_CONTROL_PASS"),
    ):
        def run_option_case(mode=mode, marker=marker, scenario=scenario):
            command_id = scenario + "-consumer"
            argv = [str(binaries["options"]), mode]
            trace = directories["options"] / (scenario + ".syscalls.log")
            if mode in {"invalid", "send-control"}:
                prefix = ["strace", "-f", "-e", "trace=socket,sendto,setsockopt,getsockopt", "-o", str(trace)]
                if mode == "send-control":
                    prefix += ["-e", "inject=sendto:delay_enter=500ms:when=1"]
                argv = prefix + argv
            support.command(argv, binaries["options"].parent, directories["options"], command_id, 30, commands)
            if mode == "invalid":
                support.require("socket(" not in trace.read_text(encoding="utf-8"),
                                "invalid option admission allocated a native socket")
            if mode == "send-control":
                support.require("DELAYED" in trace.read_text(encoding="utf-8"),
                                "native send delay injection did not execute")
            stdout = directories["options"] / (command_id + ".stdout.log")
            validate_marker(stdout, marker)
            result = {"status": "PASS", "stdout": support.text_artifact(stdout),
                      "stderr": support.text_artifact(directories["options"] / (command_id + ".stderr.log"))}
            if mode in {"invalid", "send-control"}:
                result["syscalls"] = support.text_artifact(trace)
            return result
        support.run_scenario(scenarios, scenario, run_option_case)

    ipv4_index = ipv4_loopback_index()
    ipv6_index = ipv6_link_local_index()
    for scenario, mode, marker in UDP_CASES:
        def run_udp_case(scenario=scenario, mode=mode, marker=marker):
            command_id = scenario + "-consumer"
            trace = directories["udp"] / (scenario + ".syscalls.log")
            argv = [str(binaries["udp"])]
            delayed_syscall = False
            if mode == "active-receive":
                argv = ["strace", "-f", "-e", "trace=recvfrom,recvmsg", "-o", str(trace),
                        "-e", "inject=recvfrom:delay_enter=500ms:when=1",
                        "-e", "inject=recvmsg:delay_enter=500ms:when=1", *argv]
                delayed_syscall = True
            elif mode == "active-send":
                argv = ["strace", "-f", "-e", "trace=sendto", "-o", str(trace),
                        "-e", "inject=sendto:delay_enter=500ms:when=1", *argv]
                delayed_syscall = True
            values = {"WIRESTACK_M9_003_MODE": mode}
            if mode in {"ipv4-multicast", "membership-cleanup"}:
                values["WIRESTACK_M9_003_IPV4_INTERFACE_INDEX"] = str(ipv4_index)
            if mode == "ipv6-multicast":
                values["WIRESTACK_M9_003_IPV6_INTERFACE_INDEX"] = str(ipv6_index)
            with_environment(values, lambda: support.command(argv, binaries["udp"].parent,
                directories["udp"], command_id, 30, commands))
            stdout = directories["udp"] / (command_id + ".stdout.log")
            validate_marker(stdout, marker)
            result = {"status": "PASS", "stdout": support.text_artifact(stdout),
                      "stderr": support.text_artifact(directories["udp"] / (command_id + ".stderr.log"))}
            if delayed_syscall:
                trace_text = trace.read_text(encoding="utf-8")
                support.require("DELAYED" in trace_text,
                                f"native {mode} syscall delay injection did not execute")
                result["syscalls"] = support.text_artifact(trace)
            return result
        support.run_scenario(scenarios, scenario, run_udp_case)


def qualify(report: dict, output: Path, sdk_archive: Path, offline: bool) -> None:
    report["platform_details"] = release.platform_identity()
    report.update(native_execution=True, cross_compiled=False, source_state="WORKING_TREE_UNSEALED")
    report["base_revision"] = support.git_value("rev-parse", "HEAD")
    try:
        report["merge_base"] = support.git_value("merge-base", "HEAD", "origin/main")
    except RuntimeError:
        report["merge_base"] = None
    report["source_digest"] = support.typed_source_tree_digest(ROOT)
    report["sdk"] = development_baseline.sdk_identity(ROOT, sdk_archive.resolve())
    description = json.loads(capabilities.relative_file(ROOT, capabilities.DESCRIPTION).read_text(encoding="utf-8"))
    report["capability_description_digest"] = text_evidence_digest(ROOT / capabilities.DESCRIPTION).to_json()
    inputs = capabilities.native_inputs(ROOT, description) | {
        "tools/m9_001_native_capabilities.py",
        "tools/m9_003_native_udp.py",
        "examples/linux/m9_002/socket_options.cj",
        "examples/linux/m9_003/udp_lifecycle.cj",
        "src/net/m8_002_udp_test.cj",
        "src/net/m9_003_udp_test.cj",
        "src/internal/transport_stdnet/m9_003_udp_lifecycle_test.cj",
    }
    report["input_digests"] = {name: text_evidence_digest(ROOT / name).to_json() for name in sorted(inputs)}
    commands, scenarios = report["commands"], report["scenarios"]
    support.command(["cjc", "-v"], ROOT, output, "toolchain", 10, commands)
    archive = ROOT / "dist/m9-003" / release.ARTIFACT_NAME
    archive.parent.mkdir(parents=True, exist_ok=True)
    archive, expected = installed_support.build_archive(output, archive, commands, offline=offline)
    report["artifact"] = {"path": relative(archive), "digest": artifact_byte_digest(archive).to_json(),
                          "payload_digest": TextEvidenceDigest(expected["payload_sha256"]).to_json()}
    work_path: Path | None = None
    try:
        with tempfile.TemporaryDirectory(prefix="wirestack-m9-003-installed-") as temporary:
            work_path = Path(temporary)
            installed = release.extract_archive(archive, work_path / "install")
            support.require(not installed.resolve().is_relative_to(ROOT),
                            "consumer installation is inside the source checkout")
            actual = json.loads((installed / "release-manifest.json").read_text(encoding="utf-8"))
            support.require(actual == expected, "installed release manifest differs from its archive")
            report["installed_source_digest"] = support.typed_source_tree_digest(installed)
            report["installation"] = {
                "method": "fresh release archive extracted outside checkout; sole package dependency is Wirestack",
                "checkout_path_dependency": False,
                "release_manifest_digest": text_evidence_digest(installed / "release-manifest.json").to_json(),
            }
            binaries: dict[str, Path] = {}
            report["consumer_binaries"] = {}
            for key, source, package in (
                ("internet", support.INTERNET_SOURCE, "wirestack_m8_002_native"),
                ("unix", support.UNIX_SOURCE, "wirestack_m8_003_native"),
                ("dns", support.DNS_SOURCE, "wirestack_m8_004_native_dns"),
                ("capabilities", support.CAPABILITY_SOURCE, "wirestack_m9_001_native_capabilities"),
                ("options", ROOT / "examples/linux/m9_002/socket_options.cj", "wirestack_m9_002_socket_options"),
                ("udp", SOURCE, "wirestack_m9_003_udp_lifecycle"),
            ):
                binary, identity = support.build_consumer(installed, source, package,
                    "M9-003 installed public network consumer", work_path, output, key + "-build", commands)
                binaries[key] = binary
                report["consumer_binaries"][key] = identity.to_json()
            profile_consumers(binaries, output, commands, scenarios, report)
            support.require(tuple(case.get("id") for case in scenarios) == SCENARIOS,
                            "native scenario inventory differs")
            support.require(all(case.get("status") == "PASS" for case in scenarios),
                            "one or more installed native scenarios failed")
            report["status"] = "PASS"
    finally:
        replacements = ((str(work_path.resolve()), "<work>"),) if work_path else ()
        support.sanitize_logs(output, replacements)
        normalized = support.normalize_value(report, replacements)
        report.clear()
        report.update(normalized)
        for command in report["commands"]:
            command.setdefault("timed_out", False)
        support.refresh_text_artifacts(report)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sdk-archive", type=Path, default=os.environ.get("WIRESTACK_BASELINE_SDK_ARCHIVE"))
    parser.add_argument("--report", type=Path, default=DEFAULT_REPORT)
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--offline", action="store_true")
    args = parser.parse_args()
    try:
        report_path = bounded_path(args.report, "report path")
        output = bounded_path(args.output_dir, "output directory")
        require(args.sdk_archive is not None, "set WIRESTACK_BASELINE_SDK_ARCHIVE or --sdk-archive")
        require(report_path != output and output not in report_path.parents,
                "report path must not be inside raw output directory")
        output.mkdir(parents=True, exist_ok=True)
    except (OSError, RuntimeError, ValueError) as error:
        print(json.dumps({"source_task": TASK, "status": "FAIL", "error": support.normalize_text(str(error))}))
        return 1
    report: dict[str, object] = {
        "schema_version": 1,
        "source_task": TASK,
        "status": "FAIL",
        "platform": PLATFORM,
        "native_execution": False,
        "cross_compiled": True,
        "commands": [],
        "scenarios": [],
        "observed_capabilities": {},
        "invocation": {"argv": ["python3", relative(Path(__file__)), *sys.argv[1:]],
                       "cwd": "<repo>", "offline": args.offline},
    }
    try:
        qualify(report, output, args.sdk_archive, args.offline)
    except (OSError, RuntimeError, ValueError, KeyError, TypeError, AttributeError, AssertionError,
            subprocess.TimeoutExpired, release.ReleaseError) as error:
        report["status"] = "FAIL"
        report["error"] = support.normalize_text(f"{type(error).__name__}: {error}")
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps({"source_task": TASK, "status": report["status"], "report": relative(report_path),
                      "scenarios": report["scenarios"]}, sort_keys=True))
    return 0 if report["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
