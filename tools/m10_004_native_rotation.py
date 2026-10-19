#!/usr/bin/env python3
"""Exercise current configuration rotation from an extracted Linux package."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from tools import m7_021_linux_release as release
from tools.evidence_digest import artifact_byte_digest, text_evidence_digest

TASK = "M10-004"
SOURCE = ROOT / "examples/linux/m10_004/configuration_rotation.cj"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "docs/evidence/M10-004/installed")
    args = parser.parse_args()
    output = args.output.resolve()
    relative = output.relative_to(ROOT)
    if relative.parts[:2] == ("docs", "evidence") and relative.parts[2:3] != (TASK,):
        raise ValueError("output must not overwrite another task's evidence")
    output.mkdir(parents=True, exist_ok=True)
    report = {"schema_version": 1, "task_id": TASK, "status": "INCOMPLETE",
              "platform": release.platform_identity(), "release_qualification": "NOT_QUALIFIED",
              "candidate_committed": False, "consumer_source": str(SOURCE.relative_to(ROOT)),
              "consumer_source_digest": text_evidence_digest(SOURCE).to_json(), "commands": []}
    with tempfile.TemporaryDirectory(prefix="wirestack-m10-004-installed-") as directory:
        work = Path(directory)
        replacements = [(str(work), "<scratch>"), (str(ROOT), "<repo>"),
                        (os.environ.get("CANGJIE_HOME", ""), "<sdk>"),
                        (str(Path.home()), "$HOME")]
        replacements = sorted(((a, b) for a, b in replacements if a), key=lambda pair: -len(pair[0]))

        def redact(value: str) -> str:
            for actual, placeholder in replacements:
                value = value.replace(actual, placeholder)
            return value

        def run(name: str, argv: list[str], cwd: Path, timeout: int = 60) -> str:
            timed_out = False
            code = None
            try:
                result = subprocess.run(argv, cwd=cwd, capture_output=True, timeout=timeout, check=False)
                stdout, stderr, code = result.stdout, result.stderr, result.returncode
            except subprocess.TimeoutExpired as error:
                stdout, stderr, timed_out = error.stdout or b"", error.stderr or b"", True
            text = redact(stdout.decode("utf-8", errors="replace"))
            error_text = redact(stderr.decode("utf-8", errors="replace"))
            stdout_path, stderr_path = output / f"{name}.stdout.log", output / f"{name}.stderr.log"
            stdout_path.write_text(text, encoding="utf-8")
            stderr_path.write_text(error_text, encoding="utf-8")
            report["commands"].append({"id": name, "argv": [redact(v) for v in argv],
                "cwd": redact(str(cwd)), "exit_code": code, "timed_out": timed_out,
                "stdout": {"path": str(stdout_path.relative_to(ROOT)),
                           "digest": text_evidence_digest(stdout_path).to_json()},
                "stderr": {"path": str(stderr_path.relative_to(ROOT)),
                           "digest": text_evidence_digest(stderr_path).to_json()}})
            if timed_out or code != 0:
                raise RuntimeError(f"{name} failed; see task evidence logs")
            return text

        try:
            payload, manifest = release.collect_payload(ROOT)
            archive = work / "wirestack-current.tar.gz"
            release.write_reproducible_archive(archive, payload)
            installed = release.extract_archive(archive, work / "install")
            if installed == ROOT or ROOT in installed.parents:
                raise RuntimeError("consumer installation must be outside checkout")
            actual_manifest = json.loads((installed / "release-manifest.json").read_text())
            if actual_manifest != manifest:
                raise RuntimeError("extracted payload manifest differs")
            report["archive_digest"] = artifact_byte_digest(archive).to_json()
            report["payload_sha256"] = manifest["payload_sha256"]
            report["production_sources"] = {str(path.relative_to(ROOT)): text_evidence_digest(path).to_json()
                                             for path in release.production_sources(ROOT)}
            consumer = work / "consumer"
            (consumer / "src").mkdir(parents=True)
            (consumer / "cjpm.toml").write_text(release.consumer_manifest(installed).replace(
                "wirestack_release_smoke", "wirestack_m10_004_rotation"), encoding="utf-8")
            shutil.copy2(SOURCE, consumer / "src/main.cj")
            for identity in ("trusted", "untrusted"):
                run(f"{identity}-certificate", ["openssl", "req", "-x509", "-newkey", "rsa:2048",
                    "-nodes", "-days", "1", "-subj", "/CN=example.test",
                    "-addext", "subjectAltName=DNS:example.test", "-keyout", str(work / f"{identity}.pem"),
                    "-out", str(work / f"{identity}.crt")], work)
                run(f"{identity}-der", ["openssl", "x509", "-in", str(work / f"{identity}.crt"),
                    "-outform", "DER", "-out", str(work / f"{identity}.der")], work)
            run("key-der", ["openssl", "pkcs8", "-topk8", "-nocrypt", "-in", str(work / "trusted.pem"),
                            "-outform", "DER", "-out", str(work / "key.pk8")], work)
            report["toolchain"] = {"compiler": run("compiler", ["cjc", "--version"], consumer).strip(),
                                   "cjpm": run("cjpm", ["cjpm", "--version"], consumer).strip()}
            run("consumer-build", ["cjpm", "build"], consumer, timeout=600)
            binary = consumer / "target/release/bin/main"
            report["consumer_binary_digest"] = artifact_byte_digest(binary).to_json()
            stdout = run("consumer-run", [str(binary), str(work / "trusted.der"),
                         str(work / "key.pk8"), str(work / "untrusted.der")], consumer, timeout=90)
            markers = [line for line in stdout.splitlines() if line.endswith("_PASS")]
            if markers != ["M10_004_INSTALLED_ROTATION_PASS"]:
                raise RuntimeError("consumer omitted successful rotation and cleanup marker")
            report.update(status="PASS", checkout_path_dependency=False,
                          acceptance=["graceful-active-exchange", "server-security-cancellation",
                                      "h2-obsolete-authentication-rejected", "client-identity-replacement",
                                      "removed-trust-rejected", "dns-new-admission", "zero-terminal-owners"])
        except Exception as error:
            report.update(status="FAIL", error=redact(str(error)))
        finally:
            (output / "report.json").write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n",
                                               encoding="utf-8")
    print(f"{TASK} installed rotation: {report['status']}")
    return 0 if report["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
