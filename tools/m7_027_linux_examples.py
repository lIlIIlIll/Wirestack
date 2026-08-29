#!/usr/bin/env python3
"""Validate the M7-027 Linux migration guide and runnable public examples."""

from __future__ import annotations

import argparse
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any, Callable, Sequence

ROOT = Path(__file__).resolve().parents[1]
TASK_ID = "M7-027"
PROFILE = "linux-x86_64-glibc"
EXAMPLE_ROOT = ROOT / "examples/linux/m7_027"
GUIDE = ROOT / "docs/guides/migrate-to-wirestack-linux.md"
REPORT = ROOT / "docs/evidence/M7-027/linux_x86_64/examples.json"
ENV_WRAPPER = Path("/home/elliot/.codex/scripts/codex_cangjie_env")
PACKAGE_DECLARATION = "package wirestack_m7_027_examples"
SOURCE_NAMES = (
    "fixtures.cj",
    "http_examples.cj",
    "main.cj",
    "transport_tls_example.cj",
)
EXPECTED_MARKERS = (
    "HTTP1_SERVER=PASS",
    "SSE=PASS",
    "SCOPED_CANCELLATION=PASS",
    "CONNECT_TLS=PASS",
    "HTTPS_CLIENT=PASS",
    "CUSTOM_CA=PASS",
    "HTTP2_SERVER=PASS",
    "EXISTING_TRANSPORT_TLS=PASS",
    "MTLS=PASS",
)
GUIDE_TOPICS = (
    "## Map old APIs to Wirestack",
    "## Replace relative timeouts with a Deadline",
    "## Choose a cancellation scope",
    "## Configure a custom CA",
    "## Configure mutual TLS",
    "## Stream request and response bodies",
    "## Configure bounded retries",
    "## Handle structured errors",
    "## Remove OpenSSL build configuration",
)
FORBIDDEN_IMPORT = re.compile(r"(?m)^\s*import\s+wirestack\.internal(?:\.|\s|$)")
MAX_OUTPUT_CHARS = 20_000


class ExampleGateError(RuntimeError):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


def require_platform(system: str | None = None, machine: str | None = None,
                     libc_name: str | None = None) -> None:
    actual_system = system or platform.system()
    actual_machine = (machine or platform.machine()).lower()
    actual_libc = libc_name if libc_name is not None else platform.libc_ver()[0]
    if actual_system != "Linux" or actual_machine not in {"x86_64", "amd64"}:
        raise ExampleGateError(
            "UNSUPPORTED_PLATFORM",
            f"requires Linux x86_64, got {actual_system}/{actual_machine}",
        )
    if "musl" in actual_libc.lower():
        raise ExampleGateError("UNSUPPORTED_LIBC", "the M7-027 profile requires glibc")


def load_and_validate_sources(root: Path = EXAMPLE_ROOT) -> dict[str, str]:
    actual = tuple(sorted(path.name for path in root.glob("*.cj"))) if root.is_dir() else ()
    if actual != SOURCE_NAMES:
        raise ExampleGateError(
            "EXAMPLE_INVENTORY",
            f"expected sources {list(SOURCE_NAMES)}, got {list(actual)}",
        )
    result: dict[str, str] = {}
    for name in SOURCE_NAMES:
        text = (root / name).read_text(encoding="utf-8")
        if text.count(PACKAGE_DECLARATION) != 1:
            raise ExampleGateError("PACKAGE_DECLARATION", f"invalid package declaration in {name}")
        if FORBIDDEN_IMPORT.search(text):
            raise ExampleGateError("INTERNAL_IMPORT", f"internal Wirestack import in {name}")
        result[name] = text
    return result


def validate_guide(text: str) -> None:
    missing = [topic for topic in GUIDE_TOPICS if topic not in text]
    if missing:
        raise ExampleGateError("GUIDE_TOPIC", f"migration guide is missing {missing}")
    required = (
        "OperationContext", "Deadline.after", "HttpRequestCancellationHandle",
        "HttpConnectionCancellationHandle", "HttpStreamCancellationHandle",
        "TrustPolicy.customRoots", "ClientAuthentication.Required", "HttpBodyStream",
        "HttpRetryPolicy", "NetworkException", "HttpException", "-lssl", "-lcrypto",
    )
    absent = [token for token in required if token not in text]
    if absent:
        raise ExampleGateError("GUIDE_CONTRACT", f"migration guide is missing {absent}")
    forbidden_recommendations = (
        "setGlobalTlsKit(", "getGlobalTlsKit(", "TrustAll(", "SSL_CTX", "SSL*",
    )
    present = [token for token in forbidden_recommendations if token in text]
    if present:
        raise ExampleGateError("LEGACY_RECOMMENDATION", f"legacy API appears in guide: {present}")


def validate_markers(output: str, expected: Sequence[str] = EXPECTED_MARKERS) -> None:
    markers = [line for line in output.splitlines() if line.endswith("=PASS")]
    if markers != list(expected):
        raise ExampleGateError(
            "EXAMPLE_MARKERS",
            f"expected markers {list(expected)}, got {markers}",
        )
    if "SKIPPED" in output:
        raise ExampleGateError("SKIPPED_AS_PASS", "example output contains SKIPPED")


def bounded_output(value: str, limit: int = MAX_OUTPUT_CHARS) -> str:
    return value[-limit:]


def atomic_json(
    path: Path,
    value: dict[str, Any],
    replace: Callable[[str | bytes | os.PathLike[str] | os.PathLike[bytes],
                       str | bytes | os.PathLike[str] | os.PathLike[bytes]], None] = os.replace,
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = json.dumps(value, indent=2, sort_keys=True) + "\n"
    temporary: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            "w", encoding="utf-8", dir=path.parent, delete=False
        ) as stream:
            temporary = Path(stream.name)
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
        replace(temporary, path)
        temporary = None
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def run(command: Sequence[str], cwd: Path, timeout: int) -> str:
    completed = subprocess.run(
        list(command), cwd=cwd, text=True, stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT, timeout=timeout, check=False,
    )
    output = bounded_output(completed.stdout)
    if completed.returncode != 0:
        raise ExampleGateError(
            "COMMAND_FAILED",
            f"command exited {completed.returncode}: {' '.join(command)}\n{output}",
        )
    return output


def tool_command(
    command: Sequence[str],
    cwd: Path,
    wrapper: Path = ENV_WRAPPER,
    which: Callable[[str], str | None] = shutil.which,
) -> list[str]:
    if wrapper.is_file():
        return [str(wrapper), "--cwd", str(cwd), *command]
    executable = command[0]
    if os.sep in executable:
        available = Path(executable).is_file()
    else:
        available = which(executable) is not None
    if not available:
        raise ExampleGateError(
            "MISSING_TOOLCHAIN",
            f"missing environment wrapper and executable {executable}",
        )
    return list(command)


def consumer_manifest() -> str:
    dependency = json.dumps(str(ROOT))
    return f'''[package]
  cjc-version = "1.1.0"
  name = "wirestack_m7_027_examples"
  organization = ""
  description = "M7-027 clean migration example consumer"
  version = "1.0.0"
  target-dir = ""
  script-dir = ""
  src-dir = "src"
  output-type = "executable"
  compile-option = ""
  override-compile-option = ""
  link-option = ""
  package-configuration = {{}}

[dependencies]
  wirestack = {{ path = {dependency} }}
'''


def validate() -> dict[str, Any]:
    require_platform()
    sources = load_and_validate_sources()
    validate_guide(GUIDE.read_text(encoding="utf-8"))
    run([sys.executable, "tools/build_linux_tls_provider.py", "--offline"], ROOT, 600)
    run([sys.executable, "tools/build_linux_resolver.py", "--quiet"], ROOT, 120)
    with tempfile.TemporaryDirectory(prefix="wirestack-m7-027-") as temporary:
        consumer = Path(temporary) / "consumer"
        source_root = consumer / "src"
        source_root.mkdir(parents=True)
        (consumer / "cjpm.toml").write_text(consumer_manifest(), encoding="utf-8")
        for name, text in sources.items():
            (source_root / name).write_text(text, encoding="utf-8")
        run(tool_command(["cjpm", "build"], consumer), consumer, 300)
        binary = consumer / "target/release/bin/main"
        if not binary.is_file():
            raise ExampleGateError("MISSING_EXECUTABLE", "clean consumer produced no main executable")
        output = run(tool_command([str(binary)], consumer), consumer, 60)
        validate_markers(output)
    report = {
        "schemaVersion": 1,
        "taskId": TASK_ID,
        "source_task": TASK_ID,
        "acceptance_status": "PASS",
        "status": "PASS",
        "decision": "PASS",
        "platform": PROFILE,
        "checks": {
            "migrationGuide": "PASS",
            "publicImportsOnly": "PASS",
            "cleanConsumerBuild": "PASS",
            "cleanConsumerRun": "PASS",
            "exampleMarkers": list(EXPECTED_MARKERS),
            "skippedAsPass": False,
        },
        "commands": [
            "tools/build_linux_tls_provider.py --offline",
            "tools/build_linux_resolver.py --quiet",
            "cjpm build (temporary clean consumer)",
            "temporary clean consumer executable",
        ],
    }
    atomic_json(REPORT, report)
    return report


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    try:
        report = validate()
    except (ExampleGateError, OSError, subprocess.TimeoutExpired) as error:
        code = error.code if isinstance(error, ExampleGateError) else type(error).__name__
        print(json.dumps({
            "taskId": TASK_ID, "decision": "FAIL", "code": code,
            "error": bounded_output(str(error), 4000),
        }, sort_keys=True))
        return 1
    print(
        json.dumps(report, sort_keys=True)
        if args.json else f"{TASK_ID} PASS: Linux migration examples accepted"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
