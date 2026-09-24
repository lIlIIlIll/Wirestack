#!/usr/bin/env python3
"""Qualify typed options and the current capability map from a fresh installed package."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
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

TASK = "M9-002"
SOURCE = ROOT / "examples/linux/m9_002/socket_options.cj"
DEFAULT_OUTPUT = ROOT / "docs/evidence/M9-002/native-options"
DEFAULT_REPORT = ROOT / "docs/evidence/M9-002/native-options.json"
SCENARIOS = (*support.SCENARIO_IDS, "socket-options", "http-option-connector",
             "invalid-option-admission", "active-send-control")


def qualify(report: dict, output: Path, sdk_archive: Path, offline: bool) -> None:
    report["platform_details"] = release.platform_identity()
    report.update(native_execution=True, cross_compiled=False, source_state="WORKING_TREE_UNSEALED")
    report["base_revision"] = support.git_value("rev-parse", "HEAD")
    report["source_digest"] = support.typed_source_tree_digest(ROOT)
    report["sdk"] = development_baseline.sdk_identity(ROOT, sdk_archive.resolve())
    description = json.loads((ROOT / capabilities.DESCRIPTION).read_text())
    report["capability_description_digest"] = text_evidence_digest(ROOT / capabilities.DESCRIPTION).to_json()
    inputs = capabilities.native_inputs(ROOT, description) | {
        "tools/m9_001_native_capabilities.py", "tools/m9_002_native_options.py",
        "examples/linux/m9_002/socket_options.cj",
    }
    report["input_digests"] = {name: text_evidence_digest(ROOT / name).to_json() for name in sorted(inputs)}
    commands, scenarios = report["commands"], report["scenarios"]
    support.command(["cjc", "-v"], ROOT, output, "toolchain", 10, commands)
    archive = ROOT / "dist/m9-002" / release.ARTIFACT_NAME
    archive.parent.mkdir(parents=True, exist_ok=True)
    archive, expected = installed_support.build_archive(output, archive, commands, offline=offline)
    report["artifact"] = {"path": support.relative(archive), "digest": artifact_byte_digest(archive).to_json(),
                          "payload_digest": TextEvidenceDigest(expected["payload_sha256"]).to_json()}
    work = None
    try:
        with tempfile.TemporaryDirectory(prefix="wirestack-m9-002-installed-") as temporary:
            work = Path(temporary)
            installed = release.extract_archive(archive, work / "install")
            support.require(not installed.resolve().is_relative_to(ROOT), "consumer installation is inside checkout")
            actual = json.loads((installed / "release-manifest.json").read_text())
            support.require(actual == expected, "installed payload manifest differs")
            report["installed_source_digest"] = support.typed_source_tree_digest(installed)
            report["installation"] = {
                "method": "fresh archive outside checkout; sole dependency is extracted Wirestack",
                "checkout_path_dependency": False,
                "release_manifest_digest": text_evidence_digest(installed / "release-manifest.json").to_json(),
            }
            binaries = {}
            report["consumer_binaries"] = {}
            for key, source, package in (
                ("internet", support.INTERNET_SOURCE, "wirestack_m8_002_native"),
                ("unix", support.UNIX_SOURCE, "wirestack_m8_003_native"),
                ("dns", support.DNS_SOURCE, "wirestack_m8_004_native_dns"),
                ("capabilities", support.CAPABILITY_SOURCE, "wirestack_m9_001_native_capabilities"),
                ("options", SOURCE, "wirestack_m9_002_socket_options"),
            ):
                binary, identity = support.build_consumer(installed, source, package,
                    "M9-002 installed public network consumer", work, output, key + "-build", commands)
                binaries[key] = binary
                report["consumer_binaries"][key] = identity.to_json()
            directories = {key: output / key for key in ("internet", "unix", "dns", "contract", "options")}
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
                    (directories["contract"] / "capability-contract.stdout.log").read_text().splitlines())
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
                    argv = [str(binaries["options"]), mode]
                    trace = directories["options"] / (scenario + ".syscalls.log")
                    if mode in {"invalid", "send-control"}:
                        prefix = ["strace", "-f", "-e", "trace=socket,sendto,setsockopt,getsockopt", "-o", str(trace)]
                        if mode == "send-control":
                            prefix += ["-e", "inject=sendto:delay_enter=500ms:when=1"]
                        argv = prefix + argv
                    support.command(argv, binaries["options"].parent,
                        directories["options"], scenario, 30, commands)
                    if mode == "invalid":
                        support.require("socket(" not in trace.read_text(), "invalid admission allocated a native socket")
                    if mode == "send-control":
                        support.require("DELAYED" in trace.read_text(), "native send delay injection did not execute")
                    stdout = directories["options"] / (scenario + ".stdout.log")
                    installed_support.validate_marker(stdout, marker)
                    result = {"status": "PASS", "stdout": support.text_artifact(stdout),
                              "stderr": support.text_artifact(directories["options"] / (scenario + ".stderr.log"))}
                    if mode in {"invalid", "send-control"}:
                        result["syscalls"] = support.text_artifact(trace)
                    return result
                support.run_scenario(scenarios, scenario, run_option_case)
            support.require(tuple(case.get("id") for case in scenarios) == SCENARIOS,
                            "native scenario inventory differs")
            support.require(all(case.get("status") == "PASS" for case in scenarios), "native scenario failed")
            report["status"] = "PASS"
    finally:
        replacements = ((str(work.resolve()), "<work>"),) if work else ()
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
    parser.add_argument("--offline", action="store_true")
    args = parser.parse_args()
    report = {"schema_version": 1, "source_task": TASK, "status": "FAIL",
              "platform": "linux-x86_64-glibc", "native_execution": False, "cross_compiled": True,
              "commands": [], "scenarios": []}
    DEFAULT_OUTPUT.mkdir(parents=True, exist_ok=True)
    try:
        support.require(args.sdk_archive is not None, "set WIRESTACK_BASELINE_SDK_ARCHIVE or --sdk-archive")
        qualify(report, DEFAULT_OUTPUT, args.sdk_archive, args.offline)
    except (OSError, RuntimeError, ValueError, KeyError, TypeError, AssertionError,
            subprocess.TimeoutExpired, release.ReleaseError) as error:
        report["status"] = "FAIL"
        report["error"] = support.normalize_text(f"{type(error).__name__}: {error}")
    DEFAULT_REPORT.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(json.dumps({"source_task": TASK, "status": report["status"], "report": support.relative(DEFAULT_REPORT),
                      "scenarios": report["scenarios"]}, indent=2))
    return 0 if report["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
