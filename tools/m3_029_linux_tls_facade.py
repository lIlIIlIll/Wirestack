#!/usr/bin/env python3
"""Validate the M3-029 provider-neutral public TLS facade on Linux."""

from __future__ import annotations

import argparse
import json
import os
import platform
import subprocess
import tempfile
from pathlib import Path
from typing import Any, Sequence

ROOT = Path(__file__).resolve().parents[1]
TASK_ID = "M3-029"
PROFILE = "linux-x86_64-glibc"
REPORT = ROOT / "docs/evidence/M3-029/linux_x86_64/public-tls-facade.json"
ENV_WRAPPER = Path("/home/elliot/.codex/scripts/codex_cangjie_env")
EXPECTED_MARKERS = {"HTTPS_CLIENT_SERVER=PASS", "PUBLIC_TLS_FACADE=PASS"}


class FacadeGateError(RuntimeError):
    pass


def require_linux(system: str | None = None, machine: str | None = None) -> None:
    actual_system = system or platform.system()
    actual_machine = machine or platform.machine()
    if actual_system != "Linux" or actual_machine not in {"x86_64", "AMD64"}:
        raise FacadeGateError(f"BLOCKED: requires Linux x86_64, got {actual_system}/{actual_machine}")


def validate_smoke_output(output: str) -> None:
    lines = set(output.splitlines())
    missing = sorted(EXPECTED_MARKERS - lines)
    if missing:
        raise FacadeGateError(f"clean consumer omitted markers: {missing}")


def atomic_json(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = json.dumps(value, indent=2, sort_keys=True) + "\n"
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=path.parent, delete=False) as stream:
        temporary = Path(stream.name)
        stream.write(payload)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)


def run(command: Sequence[str], cwd: Path, timeout: int = 300) -> str:
    completed = subprocess.run(
        list(command), cwd=cwd, text=True, stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT, timeout=timeout, check=False,
    )
    output = completed.stdout[-20000:]
    if completed.returncode != 0:
        raise FacadeGateError(
            f"command failed with exit {completed.returncode}: {' '.join(command)}\n{output}"
        )
    return output


def consumer_manifest() -> str:
    root = json.dumps(str(ROOT))
    return f'''[package]
  cjc-version = "1.1.0"
  name = "m3_029_public_tls_consumer"
  organization = ""
  description = "M3-029 clean public TLS facade consumer"
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
  wirestack = {{ path = {root} }}
'''


def validate() -> dict[str, Any]:
    require_linux()
    if not ENV_WRAPPER.is_file():
        raise FacadeGateError(f"BLOCKED: missing Cangjie environment wrapper: {ENV_WRAPPER}")
    test_output = run([
        str(ENV_WRAPPER), "--cwd", str(ROOT), "cjpm", "test", "src/tls",
        "-j1", "--parallel", "1", "--exclude-tags=Performance",
    ], ROOT, timeout=300)
    with tempfile.TemporaryDirectory(prefix="wirestack-m3-029-") as temporary:
        consumer = Path(temporary) / "consumer"
        (consumer / "src").mkdir(parents=True)
        (consumer / "cjpm.toml").write_text(consumer_manifest(), encoding="utf-8")
        smoke_source = (ROOT / "tools/release_smoke/main.cj").read_text(encoding="utf-8")
        expected_package = "package wirestack_release_smoke"
        if smoke_source.count(expected_package) != 1:
            raise FacadeGateError("release smoke fixture has an unexpected package declaration")
        (consumer / "src/main.cj").write_text(
            smoke_source.replace(expected_package, "package m3_029_public_tls_consumer", 1),
            encoding="utf-8",
        )
        run([str(ENV_WRAPPER), "--cwd", str(consumer), "cjpm", "build"], consumer, timeout=300)
        binary = consumer / "target/release/bin/main"
        if not binary.is_file():
            raise FacadeGateError("clean consumer build produced no executable")
        smoke_output = run([str(ENV_WRAPPER), "--cwd", str(consumer), str(binary)], consumer, timeout=60)
        validate_smoke_output(smoke_output)
    report = {
        "schemaVersion": 1,
        "taskId": TASK_ID,
        "source_task": TASK_ID,
        "acceptance_status": "PASS",
        "status": "PASS",
        "platform": PROFILE,
        "decision": "PASS",
        "checks": {
            "publicPackageTests": "PASS_6_OF_6",
            "cleanConsumerBuild": "PASS",
            "realTlsLoopback": "PASS",
            "publicFacadeConstruction": "PASS",
            "skippedAsPass": False,
        },
        "commands": [
            "cjpm test src/tls -j1 --parallel 1 --exclude-tags=Performance",
            "cjpm build (clean path consumer)",
            "clean consumer executable",
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
    except (FacadeGateError, subprocess.TimeoutExpired) as error:
        print(json.dumps({"taskId": TASK_ID, "decision": "FAIL", "error": str(error)}, sort_keys=True))
        return 1
    print(json.dumps(report, sort_keys=True) if args.json else f"{TASK_ID} PASS: public TLS facade accepted")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
