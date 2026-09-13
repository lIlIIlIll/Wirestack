#!/usr/bin/env python3
"""Qualify native public HTTP APIs from an extracted Linux release archive."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile
import tomllib
from typing import Any, Sequence

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from tools import m7_021_linux_release as release
from tools import m7_027_linux_examples as examples
from tools.evidence_digest import (
    TextEvidenceDigest,
    artifact_byte_digest,
    text_evidence_digest,
)

TASK_ID = "M8-005"
SOURCE = ROOT / "examples/linux/m8_005/native_http.cj"
DEFAULT_REPORT = ROOT / "docs/evidence/M8-005/native-http.json"
DEFAULT_OUTPUT = ROOT / "docs/evidence/M8-005/native-http"
ARCHIVE_NAME = release.ARTIFACT_NAME
COMMAND_TIMEOUT_SECONDS = 30
BUILD_TIMEOUT_SECONDS = 600
NATIVE_TIMEOUT_SECONDS = 1800
SCENARIOS = (
    ("cookies-hooks", "COOKIES_HOOKS_PASS", (
        "stored_cookie", "explicit_cookie_precedence", "custom_connector",
        "pool_acquire_release_hooks", "service_before_after_hooks",
    )),
    ("files-multipart", "FILES_MULTIPART_PASS", (
        "quoted_multipart_boundary", "binary_upload", "rooted_file_publish",
        "binary_download",
    )),
    ("upgrade-http1", "UPGRADE_HTTP1_PASS", (
        "http1_generic_upgrade", "duplex_binary_exchange", "upgrade_close",
    )),
    ("websocket-http1", "WEBSOCKET_HTTP1_PASS", (
        "http1_websocket_upgrade", "uncompressed_binary_exchange", "graceful_close",
    )),
    ("websocket-http2-push", "WEBSOCKET_HTTP2_PUSH_PASS", (
        "http2_extended_connect_websocket", "uncompressed_binary_exchange",
        "same_origin_queued_push_after_parent_eof", "request_authority_host_port",
        "sibling_after_push", "graceful_close",
    )),
)


def bounded_path(path: Path, label: str) -> Path:
    resolved = path.resolve()
    try:
        relative = resolved.relative_to(ROOT)
    except ValueError as error:
        raise ValueError(f"{label} must remain under the repository root") from error
    if relative.parts[:2] == ("docs", "evidence") and (
        len(relative.parts) < 3 or relative.parts[2] != TASK_ID
    ):
        raise ValueError(f"{label} must not rewrite another task's evidence")
    if resolved in {SOURCE.resolve(), Path(__file__).resolve()}:
        raise ValueError(f"{label} must not overwrite qualification sources")
    return resolved


def text_artifact(path: Path) -> dict[str, object]:
    return {
        "path": path.resolve().relative_to(ROOT).as_posix(),
        "digest": text_evidence_digest(path).to_json(),
    }


def command(
    argv: Sequence[str],
    cwd: Path,
    output: Path,
    name: str,
    timeout: int,
    records: list[dict[str, object]],
) -> None:
    stdout = output / f"{name}.stdout.log"
    stderr = output / f"{name}.stderr.log"
    timed_out = False
    return_code: int | None = None
    try:
        with stdout.open("w", encoding="utf-8") as out, stderr.open("w", encoding="utf-8") as err:
            try:
                completed = subprocess.run(
                    list(argv), cwd=cwd, stdout=out, stderr=err,
                    timeout=timeout, check=False,
                )
                return_code = completed.returncode
            except subprocess.TimeoutExpired:
                timed_out = True
    finally:
        records.append({
            "id": name,
            "argv": [str(value) for value in argv],
            "cwd": str(cwd.resolve()),
            "timeout_seconds": timeout,
            "timed_out": timed_out,
            "exit_code": return_code,
            "stdout": text_artifact(stdout),
            "stderr": text_artifact(stderr),
        })
    if timed_out:
        raise RuntimeError(f"{name} exceeded its {timeout}-second command budget")
    if return_code != 0:
        raise RuntimeError(f"{name} exited {return_code}; see {stderr}")


def prepare_native(output: Path, records: list[dict[str, object]], *, offline: bool) -> None:
    provider = [sys.executable, str(ROOT / "tools/build_tls_provider.py")]
    if offline:
        provider.append("--offline")
    command(provider, ROOT, output, "tls-native-build", NATIVE_TIMEOUT_SECONDS, records)
    command(
        [sys.executable, str(ROOT / "tools/build_linux_resolver.py"), "--quiet"],
        ROOT, output, "resolver-native-build", NATIVE_TIMEOUT_SECONDS, records,
    )
    command(
        [sys.executable, str(ROOT / "tools/build_linux_http_files.py"),
         "--root", str(ROOT), "--quiet"],
        ROOT, output, "http-files-native-build", NATIVE_TIMEOUT_SECONDS, records,
    )


def installed_source_digest(installed: Path) -> dict[str, str]:
    return TextEvidenceDigest(release.source_tree_sha256(installed)).to_json()


def validate_marker(path: Path, expected: str) -> None:
    lines = path.read_text(encoding="utf-8").splitlines()
    markers = [line for line in lines if line.endswith("_PASS")]
    if markers != [expected]:
        raise RuntimeError(f"expected only {expected!r}, received markers {markers!r}")
    if any("SKIP" in line.upper() for line in lines):
        raise RuntimeError("consumer output attempted to treat a skipped check as evidence")


def build_archive(output: Path, archive: Path, records: list[dict[str, object]], *, offline: bool) -> tuple[Path, dict[str, Any]]:
    prepare_native(output, records, offline=offline)
    payload, release_manifest = release.collect_payload(ROOT)
    release.write_reproducible_archive(archive, payload)
    if not archive.is_file() or archive.stat().st_size == 0:
        raise RuntimeError("fresh release archive was not created")
    return archive, release_manifest


def qualify(report: dict[str, object], output: Path, *, offline: bool) -> None:
    records = report["commands"]
    scenarios = report["scenarios"]
    assert isinstance(records, list) and isinstance(scenarios, list)

    release.platform_identity()
    if not SOURCE.is_file():
        raise RuntimeError(f"native public consumer source is absent: {SOURCE}")
    command(["cjc", "-v"], ROOT, output, "toolchain", 10, records)

    with tempfile.TemporaryDirectory(prefix="wirestack-m8-005-installed-") as temporary:
        work = Path(temporary)
        archive, expected_manifest = build_archive(output, work / ARCHIVE_NAME, records, offline=offline)
        report["release_archive"] = {
            "filename": archive.name,
            "retained": False,
            "bytes": archive.stat().st_size,
            "digest": artifact_byte_digest(archive).to_json(),
            "release_manifest_payload_digest": TextEvidenceDigest(
                expected_manifest["payload_sha256"]
            ).to_json(),
            "http_files": expected_manifest["httpFiles"],
        }
        installed = release.extract_archive(archive, work / "install")
        actual_manifest_path = installed / "release-manifest.json"
        actual_manifest = json.loads(actual_manifest_path.read_text(encoding="utf-8"))
        if actual_manifest != expected_manifest:
            raise RuntimeError("extracted release manifest differs from the collected payload")
        report["installation"] = {
            "method": "extract fresh release archive and use only its root as the CJPM path dependency",
            "installed_source_digest": installed_source_digest(installed),
            "installed_release_manifest_digest": text_evidence_digest(actual_manifest_path).to_json(),
            "checkout_path_dependency": False,
        }
        if ROOT.resolve() == installed.resolve() or ROOT.resolve() in installed.resolve().parents:
            raise RuntimeError("release archive was extracted inside the source checkout")

        consumer = work / "consumer"
        (consumer / "src").mkdir(parents=True)
        manifest = release.consumer_manifest(installed)
        manifest = manifest.replace("wirestack_release_smoke", "wirestack_m8_005_native_http")
        manifest = manifest.replace(
            "M7-021 installed Wirestack release smoke", "M8-005 installed native HTTP consumer"
        )
        parsed_manifest = tomllib.loads(manifest)
        dependencies = parsed_manifest.get("dependencies")
        wirestack_dependency = dependencies.get("wirestack") if isinstance(dependencies, dict) else None
        if (
            str(ROOT.resolve()) in manifest
            or not isinstance(dependencies, dict)
            or set(dependencies) != {"wirestack"}
            or not isinstance(wirestack_dependency, dict)
            or wirestack_dependency.get("path") != str(installed.resolve())
        ):
            raise RuntimeError("consumer manifest does not contain only the extracted Wirestack dependency")
        manifest_path = consumer / "cjpm.toml"
        manifest_path.write_text(manifest, encoding="utf-8")
        report["installation"]["consumer_manifest_digest"] = text_evidence_digest(manifest_path).to_json()
        shutil.copy2(SOURCE, consumer / "src/main.cj")
        command(["cjpm", "build"], consumer, output, "consumer-build", BUILD_TIMEOUT_SECONDS, records)
        binary = consumer / "target/release/bin/main"
        if not binary.is_file():
            raise RuntimeError("installed consumer build produced no executable")
        report["consumer_binary_digest"] = artifact_byte_digest(binary).to_json()

        for mode, marker, checks in SCENARIOS:
            record_name = f"consumer-{mode}"
            scenario: dict[str, object] = {
                "mode": mode,
                "status": "FAIL",
                "marker": marker,
                "checks": list(checks),
            }
            scenarios.append(scenario)
            command([str(binary), mode], binary.parent, output, record_name,
                    COMMAND_TIMEOUT_SECONDS, records)
            stdout = output / f"{record_name}.stdout.log"
            validate_marker(stdout, marker)
            scenario["status"] = "PASS"
            scenario["stdout"] = text_artifact(stdout)
            scenario["stderr"] = text_artifact(output / f"{record_name}.stderr.log")

    if not scenarios or not all(item.get("status") == "PASS" for item in scenarios):
        raise RuntimeError("one or more native public HTTP scenarios failed")
    report["status"] = "PASS"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", type=Path, default=DEFAULT_REPORT)
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--offline", action="store_true")
    args = parser.parse_args()

    try:
        report_path = bounded_path(args.report, "report path")
        output = bounded_path(args.output_dir, "output directory")
        if report_path == output or output in report_path.parents:
            raise ValueError("report path must not be inside the raw output directory")
        output.mkdir(parents=True, exist_ok=True)
    except (OSError, ValueError) as error:
        print(json.dumps({"source_task": TASK_ID, "status": "FAIL", "error": str(error)}, sort_keys=True))
        return 1

    report: dict[str, object] = {
        "schema_version": 1,
        "source_task": TASK_ID,
        "status": "FAIL",
        "platform": {
            "system": platform.system(),
            "machine": platform.machine(),
            "libc": platform.libc_ver(),
        },
        "invocation": {
            "argv": [sys.executable, str(Path(__file__).resolve()), *sys.argv[1:]],
            "cwd": str(Path.cwd().resolve()),
            "report": str(report_path),
            "output_dir": str(output),
            "offline": args.offline,
        },
        "limits": {
            "consumer_timeout_seconds": COMMAND_TIMEOUT_SECONDS,
            "consumer_build_timeout_seconds": BUILD_TIMEOUT_SECONDS,
            "native_build_timeout_seconds": NATIVE_TIMEOUT_SECONDS,
            "consumer_operation_deadline_seconds": 5,
            "response_and_file_read_bytes": 4096,
            "file_handler_maximum_bytes": 64,
            "http2_stream_limit": 8,
            "http2_push_concurrent": 2,
            "http2_push_pending": 2,
            "http2_push_per_request": 2,
        },
        "commands": [],
        "scenarios": [],
        "source_digests": {
            "tools/m8_005_native_http.py": text_evidence_digest(Path(__file__)).to_json(),
            "examples/linux/m8_005/native_http.cj": text_evidence_digest(SOURCE).to_json()
                if SOURCE.is_file() else None,
        },
    }
    try:
        qualify(report, output, offline=args.offline)
    except (
        OSError, RuntimeError, ValueError, KeyError, TypeError, AttributeError, AssertionError,
        subprocess.TimeoutExpired, release.ReleaseError, examples.ExampleGateError,
    ) as error:
        report["error"] = f"{type(error).__name__}: {error}"

    examples.atomic_json(report_path, report)
    print(json.dumps(report, sort_keys=True))
    return 0 if report["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
