#!/usr/bin/env python3
"""Build and run the public SSE consumer from an extracted production archive."""
from __future__ import annotations

import argparse
from collections import Counter
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))
from tools import m7_021_linux_release as release
from tools.evidence_digest import artifact_byte_digest, text_evidence_digest

SOURCE = ROOT / "examples/linux/m11_001/sse.cj"
CHECKS = Counter({"writer_unicode_literal": 2, "h1_unread_close": 1,
    "h2_sibling_close": 1, "reconnect_duplicate_cursor": 1,
    "terminal_and_post_no_replay": 1, "cancel_then_new_request": 1, "native_shutdown": 1})


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "docs/evidence/M11-001/installed")
    parser.add_argument("--scratch-parent", type=Path, default=Path.home() / ".cache/agent-tmp")
    args = parser.parse_args()
    output = args.output.resolve()
    relative = output.relative_to(ROOT)
    if relative.parts[:3] != ("docs", "evidence", "M11-001"):
        raise ValueError("output must stay within this task's evidence")
    output.mkdir(parents=True, exist_ok=True)
    parent = args.scratch_parent.resolve()
    parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if shutil.disk_usage(parent).free < 2 * 1024**3:
        raise RuntimeError("scratch filesystem needs at least 2 GiB free")
    probe = subprocess.run(["findmnt", "-n", "-o", "FSTYPE", "-T", str(parent)],
        capture_output=True, text=True, check=True)
    if probe.stdout.strip() == "tmpfs":
        raise RuntimeError("scratch filesystem must be disk-backed")
    report = {"schema_version": 1, "task_id": "M11-001", "status": "INCOMPLETE",
        "platform": release.platform_identity(), "release_qualification": "NOT_QUALIFIED",
        "candidate_committed": False, "consumer_source": str(SOURCE.relative_to(ROOT)),
        "consumer_source_digest": text_evidence_digest(SOURCE).to_json(), "commands": []}
    report["runner_source_digest"] = text_evidence_digest(Path(__file__)).to_json()
    with tempfile.TemporaryDirectory(prefix="wirestack-m11-001-installed-", dir=parent) as directory:
        work = Path(directory)
        replacements = [(str(work), "<scratch>"), (str(ROOT), "<repo>"),
            (os.environ.get("CANGJIE_HOME", ""), "<sdk>"), (str(Path.home()), "$HOME")]
        replacements = sorted(((a, b) for a, b in replacements if a), key=lambda pair: -len(pair[0]))
        env = dict(os.environ, TMPDIR=str(work), TMP=str(work), TEMP=str(work), DISABLE_ZOXIDE="1")

        def redact(text: str) -> str:
            for actual, placeholder in replacements:
                text = text.replace(actual, placeholder)
            return text.replace("127.0.0.1", "192.0.2.1")

        def run(name: str, argv: list[str], cwd: Path, timeout: int = 60) -> str:
            code, timed_out = None, False
            try:
                result = subprocess.run(argv, cwd=cwd, env=env, capture_output=True, timeout=timeout, check=False)
                stdout, stderr, code = result.stdout, result.stderr, result.returncode
            except subprocess.TimeoutExpired as error:
                stdout, stderr, timed_out = error.stdout or b"", error.stderr or b"", True
            text, errors = redact(stdout.decode("utf-8", errors="replace")), redact(stderr.decode("utf-8", errors="replace"))
            streams = {}
            for kind, value in (("stdout", text), ("stderr", errors)):
                path = output / f"{name}.{kind}.log"
                path.write_text(value, encoding="utf-8")
                streams[kind] = {"path": str(path.relative_to(ROOT)), "digest": text_evidence_digest(path).to_json()}
            report["commands"].append({"id": name, "argv": [redact(v) for v in argv],
                "cwd": redact(str(cwd)), "exit_code": code, "timed_out": timed_out, **streams})
            if timed_out or code != 0:
                raise RuntimeError(f"{name} failed; see task evidence logs")
            return text

        try:
            payload, manifest = release.collect_payload(ROOT)
            archive = work / "wirestack-current.tar.gz"
            release.write_reproducible_archive(archive, payload)
            installed = release.extract_archive(archive, work / "install")
            if installed == ROOT or ROOT in installed.parents:
                raise RuntimeError("installation must be outside checkout")
            actual = json.loads((installed / "release-manifest.json").read_text())
            if actual != manifest:
                raise RuntimeError("extracted archive manifest differs")
            report.update(archive_digest=artifact_byte_digest(archive).to_json(), payload_sha256=manifest["payload_sha256"],
                production_sources={str(path.relative_to(installed)): text_evidence_digest(path).to_json()
                    for path in release.production_sources(installed)})
            consumer = work / "consumer"
            (consumer / "src").mkdir(parents=True)
            consumer_manifest = release.consumer_manifest(installed).replace("wirestack_release_smoke", "wirestack_m11_001_sse")
            if str(ROOT) in consumer_manifest:
                raise RuntimeError("consumer manifest references checkout")
            (consumer / "cjpm.toml").write_text(consumer_manifest, encoding="utf-8")
            shutil.copy2(SOURCE, consumer / "src/main.cj")
            run("certificate", ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                "-subj", "/CN=example.test", "-addext", "subjectAltName=DNS:example.test",
                "-keyout", str(work / "key.pem"), "-out", str(work / "certificate.pem")], work)
            run("certificate-der", ["openssl", "x509", "-in", str(work / "certificate.pem"),
                "-outform", "DER", "-out", str(work / "certificate.der")], work)
            run("key-der", ["openssl", "pkcs8", "-topk8", "-nocrypt", "-in", str(work / "key.pem"),
                "-outform", "DER", "-out", str(work / "key.pk8")], work)
            report["toolchain"] = {"compiler": run("compiler", ["cjc", "--version"], consumer).strip(),
                "cjpm": run("cjpm", ["cjpm", "--version"], consumer).strip()}
            run("consumer-build", ["cjpm", "build"], consumer, timeout=600)
            binary = consumer / "target/release/bin/main"
            report["consumer_binary_digest"] = artifact_byte_digest(binary).to_json()
            text = run("consumer-run", [str(binary), str(work / "certificate.der"), str(work / "key.pk8")], consumer, timeout=90)
            checks = Counter(re.findall(r"^CHECK ([a-z0-9_]+) PASS$", text, flags=re.MULTILINE))
            if checks != CHECKS or text.splitlines().count("M11_001_INSTALLED_SSE_PASS") != 1:
                raise RuntimeError(f"consumer check counts differ: {dict(checks)}")
            server = re.search(r"^SERVER requests=(\d+) flushed=(\d+) producers=(\d+)$", text, re.MULTILINE)
            if not server or int(server[1]) != 14 or int(server[2]) <= 0 or int(server[3]) != 0:
                raise RuntimeError("server request/flush/producer evidence missing")
            active = re.findall(r"^RESOURCE active buffers=(\d+) session_reservation=(\d+)$", text, re.MULTILINE)
            terminal = re.findall(r"^RESOURCE (?!active)([a-z0-9-]+) buffers=(\d+) requests=(\d+) streams=(\d+) admission_waiters=(\d+) pool_waiters=(\d+)$", text, re.MULTILINE)
            if len(active) != 2 or any(int(a) < int(b) or int(b) <= 0 for a, b in active):
                raise RuntimeError("real active session reservations missing")
            if len(terminal) != 7 or any(any(int(v) != 0 for v in row[1:]) for row in terminal):
                raise RuntimeError("terminal owner or wait counters are not zero")
            h1 = re.search(r"^CONNECTION h1 old=(\d+) replacement=(\d+)$", text, re.MULTILINE)
            h2 = re.search(r"^CONNECTION h2 closed=(\d+) surviving=(\d+)$", text, re.MULTILINE)
            events = re.findall(r"^EVENT request_id=(\d+) connection_id=(\d+) stream_id=(\d+)$", text, re.MULTILINE)
            if not h1 or h1[1] == h1[2] or not h2 or h2[1] != h2[2]:
                raise RuntimeError("physical connection scope evidence differs")
            siblings = [row for row in events if row[1] == h2[1] and int(row[2]) > 0]
            if len(siblings) != 2 or siblings[0][2] == siblings[1][2]:
                raise RuntimeError("actual distinct H2 stream events missing")
            report.update(status="PASS", checkout_path_dependency=False, pass_checks=dict(checks),
                pass_check_count=sum(checks.values()), server_requests=int(server[1]))
        except Exception as error:
            report.update(status="FAIL", error=redact(str(error)))
        finally:
            (output / "report.json").write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(json.dumps({"status": report["status"], "report": str((output / "report.json").relative_to(ROOT))}))
    return 0 if report["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
