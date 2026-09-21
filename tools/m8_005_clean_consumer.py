#!/usr/bin/env python3
"""Build and run a tiny external consumer of the M8-005 public HTTP facade."""

from __future__ import annotations

import json
import os
import platform
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REPORT = ROOT / "docs/evidence/M8-005/clean-consumer.json"
WRAPPER = Path("<home>/.codex/scripts/codex_cangjie_env")


def run(command: list[str], cwd: Path, timeout: int) -> str:
    result = subprocess.run(command, cwd=cwd, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=timeout, check=False)
    if result.returncode != 0:
        raise RuntimeError(f"command failed ({result.returncode}): {' '.join(command)}\n{result.stdout[-4000:]}")
    return result.stdout[-8000:]


def manifest() -> str:
    return f'''[package]
  cjc-version = "1.1.0"
  name = "wirestack_m8_005_consumer"
  organization = ""
  description = "M8-005 public HTTP parity consumer"
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
  wirestack = {{ path = "{ROOT}" }}
'''


SOURCE = '''package wirestack_m8_005_consumer

import wirestack.http.*

main(): Int64 {
    let jar = CookieJar()
    let writer = MultipartWriter("consumer-boundary")
    writer.add(MultipartPart("field", [1u8, 2u8]))
    let _ = writer.body()
    let frame = WebSocketFrame(true, WebSocketOpcode.Binary, [3u8])
    let _ = WebSocketFrame.decode(frame.encode(maskingKey: Some([1u8, 2u8, 3u8, 4u8])))
    let client = HttpClient.builder()
        .cookieJar(jar)
        .http2PushPolicy(DenyHttp2PushPolicy())
        .build()
    client.close()
    println("M8_005_PUBLIC_CONSUMER=PASS")
    0
}
'''


def main() -> int:
    if platform.system() != "Linux" or platform.machine() not in {"x86_64", "amd64"}:
        print(json.dumps({"status": "BLOCKED", "code": "UNSUPPORTED_PLATFORM"}, sort_keys=True))
        return 1
    try:
        with tempfile.TemporaryDirectory(prefix="wirestack-m8-005-") as temporary:
            consumer = Path(temporary) / "consumer"
            source = consumer / "src"
            source.mkdir(parents=True)
            (consumer / "cjpm.toml").write_text(manifest(), encoding="utf-8")
            (source / "main.cj").write_text(SOURCE, encoding="utf-8")
            run([str(WRAPPER), "cjpm", "build"], consumer, 300)
            binary = consumer / "target/release/bin/main"
            if not binary.is_file():
                raise RuntimeError("clean consumer executable was not produced")
            output = run([str(binary)], consumer, 60)
            if "M8_005_PUBLIC_CONSUMER=PASS" not in output or "SKIPPED" in output:
                raise RuntimeError("clean consumer marker was absent or skipped")
        report = {
            "schema_version": 1,
            "source_task": "M8-005",
            "status": "PASS",
            "acceptance_status": "PASS",
            "platform": "linux-x86_64-glibc",
            "public_imports_only": True,
            "build": "PASS",
            "run": "PASS",
            "skipped_as_pass": False,
        }
        REPORT.parent.mkdir(parents=True, exist_ok=True)
        temporary = REPORT.with_suffix(".tmp")
        temporary.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        os.replace(temporary, REPORT)
        print(json.dumps(report, sort_keys=True))
        return 0
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(json.dumps({"status": "FAIL", "source_task": "M8-005",
                          "code": type(error).__name__, "error": str(error)[-4000:]}, sort_keys=True))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
