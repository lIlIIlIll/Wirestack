#!/usr/bin/env python3
"""Install a source-bound candidate and exercise native correlated observation APIs."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import selectors
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))
from tools import m7_021_linux_release as release
from tools.evidence_digest import artifact_byte_digest, text_evidence_digest

SOURCE = ROOT / "examples/linux/m10_005/observability.cj"
SECRET = "M10_005_SECRET_MARKER"
CHECKS = frozenset({"logical_retry_redirect", "h1_reuse_resources", "h2_reuse_resources",
    "pool_wait", "dns_cap", "custom_resolver_unknown", "tls_cap", "headers_cap",
    "h2_backpressure", "secret_safe_proxy_tls", "bounded_exporter_measurement", "native_shutdown"})


class Peer:
    """Real TCP fixtures: silent TLS peer or bounded CONNECT authentication rejection."""
    def __init__(self, proxy: bool = False):
        self.proxy = proxy
        self.listener = socket.socket()
        self.listener.bind(("127.0.0.1", 0))
        self.listener.listen(4)
        self.listener.settimeout(.1)
        self.port = self.listener.getsockname()[1]
        self.stop = threading.Event()
        self.authenticated_407 = False
        self.accepted = 0
        self.thread = threading.Thread(target=self._serve, daemon=True)
        self.thread.start()

    def _serve(self):
        while not self.stop.is_set():
            try:
                connection, _ = self.listener.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            with connection:
                self.accepted += 1
                if not self.proxy:
                    self.stop.wait(1)
                    continue
                connection.settimeout(2)
                received = bytearray()
                try:
                    while b"\r\n\r\n" not in received and len(received) < 65536:
                        chunk = connection.recv(4096)
                        if not chunk:
                            break
                        received.extend(chunk)
                    self.authenticated_407 = (received.startswith(b"CONNECT ") and
                        b"Proxy-Authorization: Basic " + SECRET.encode() in received)
                    connection.sendall(b'HTTP/1.1 407 Proxy Authentication Required\r\n'
                        b'Proxy-Authenticate: Basic realm="fixture"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n')
                except OSError:
                    pass

    def close(self):
        self.stop.set()
        self.listener.close()
        self.thread.join(3)


def child_resources(pid: int) -> dict[str, int]:
    process = Path("/proc") / str(pid)
    rss = next(int(line.split()[1]) for line in (process / "status").read_text().splitlines()
        if line.startswith("VmRSS:"))
    return {"fds": len(list((process / "fd").iterdir())),
        "tasks": len(list((process / "task").iterdir())), "rss_kib": rss}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="Report JSON file; logs are sibling files")
    args = parser.parse_args()
    output = args.output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    report = {"schema_version": 1, "task": "M10-005", "status": "INCOMPLETE",
        "qualification": "NOT_QUALIFIED", "candidate_committed": False,
        "platform": release.platform_identity(), "commands": [], "checks": {},
        "consumer": {"source": "examples/linux/m10_005/observability.cj",
            "source_digest": text_evidence_digest(SOURCE).to_json()}}
    with tempfile.TemporaryDirectory(prefix="wirestack-m10-005-installed-") as scratch:
        work = Path(scratch)
        replacements = [(str(work), "<scratch>"), (str(ROOT), "<repo>"),
            (str(Path.home()), "$HOME"), (SECRET, "<fixture-secret>")]
        if os.environ.get("CANGJIE_HOME"):
            replacements.append((os.environ["CANGJIE_HOME"], "<sdk>"))
        replacements.sort(key=lambda pair: len(pair[0]), reverse=True)
        def redact(text):
            for original, replacement in replacements:
                text = text.replace(original, replacement)
            return text
        def save_log(name, suffix, data):
            target = output.parent / f"{output.stem}.{name}.{suffix}.log"
            content = redact(data.decode(errors="replace"))
            target.write_text(content)
            return {"file": target.name, "digest": text_evidence_digest(target).to_json()}
        def record(name, argv, cwd, code, stdout, stderr, timed_out=False):
            report["commands"].append({"name": name, "argv": [redact(str(part)) for part in argv],
                "cwd": redact(str(cwd)), "exit_code": code, "timed_out": timed_out,
                "stdout": save_log(name, "stdout", stdout), "stderr": save_log(name, "stderr", stderr)})
        def run(name, argv, cwd=work, timeout=120):
            try:
                result = subprocess.run([str(part) for part in argv], cwd=cwd, capture_output=True, timeout=timeout)
            except subprocess.TimeoutExpired as error:
                record(name, argv, cwd, None, error.stdout or b"", error.stderr or b"", True)
                raise RuntimeError(f"{name} exceeded its bounded deadline") from error
            record(name, argv, cwd, result.returncode, result.stdout, result.stderr)
            if result.returncode:
                raise RuntimeError(f"{name} failed with exit code {result.returncode}")
            return result.stdout
        silent = proxy = refused = None
        try:
            payload, manifest = release.collect_payload(ROOT)
            archive = work / "wirestack-source-candidate.tar.gz"
            release.write_reproducible_archive(archive, payload)
            installed = release.extract_archive(archive, work / "installation")
            if installed == ROOT or ROOT in installed.parents:
                raise RuntimeError("consumer installation is inside source checkout")
            actual = json.loads((installed / "release-manifest.json").read_text())
            if actual != manifest:
                raise RuntimeError("extracted release manifest changed")
            report["candidate"] = {"archive_digest": artifact_byte_digest(archive).to_json(),
                "payload_sha256": manifest["payload_sha256"], "manifest_verified": True,
                "installation_outside_checkout": True,
                "production_sources": [{"file": str(path.relative_to(ROOT)),
                    "digest": text_evidence_digest(installed / path.relative_to(ROOT)).to_json()}
                    for path in release.production_sources(ROOT)]}
            consumer = work / "consumer"
            (consumer / "src").mkdir(parents=True)
            (consumer / "cjpm.toml").write_text(release.consumer_manifest(installed)
                .replace("wirestack_release_smoke", "wirestack_m10_005_observation"))
            shutil.copy2(SOURCE, consumer / "src/main.cj")
            report["consumer"]["dependency_kind"] = "extracted_installation_path_only"
            run("certificate", ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                "-subj", f"/CN=example.test/OU={SECRET}", "-addext", "subjectAltName=DNS:example.test",
                "-keyout", work / "key.pem", "-out", work / "certificate.pem"])
            run("certificate_der", ["openssl", "x509", "-in", work / "certificate.pem", "-outform", "DER", "-out", work / "certificate.der"])
            run("key_der", ["openssl", "pkcs8", "-topk8", "-nocrypt", "-in", work / "key.pem", "-outform", "DER", "-out", work / "key.pk8"])
            run("compiler", ["cjc", "--version"])
            run("package_manager", ["cjpm", "--version"])
            run("consumer_build", ["cjpm", "build"], cwd=consumer, timeout=600)
            binary = consumer / "target/release/bin/main"
            report["consumer"]["binary_digest"] = artifact_byte_digest(binary).to_json()
            silent = Peer(); proxy = Peer(proxy=True)
            refused = socket.socket(); refused.bind(("127.0.0.1", 0))  # bound, deliberately not listening
            argv = [str(binary), str(work / "certificate.der"), str(work / "key.pk8"),
                str(silent.port), str(proxy.port), str(refused.getsockname()[1])]
            process = subprocess.Popen(argv, cwd=consumer, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            selector = selectors.DefaultSelector()
            selector.register(process.stdout, selectors.EVENT_READ, "stdout")
            selector.register(process.stderr, selectors.EVENT_READ, "stderr")
            captured = {"stdout": bytearray(), "stderr": bytearray()}
            line_buffer = bytearray()
            resources = {}
            deadline = time.monotonic() + 120
            timed_out = False
            try:
                while selector.get_map():
                    if time.monotonic() >= deadline:
                        timed_out = True; process.kill()
                    for key, _ in selector.select(.1):
                        chunk = os.read(key.fileobj.fileno(), 65536)
                        if not chunk:
                            selector.unregister(key.fileobj)
                            continue
                        captured[key.data].extend(chunk)
                        if key.data == "stdout":
                            line_buffer.extend(chunk)
                            while b"\n" in line_buffer:
                                line, _, remainder = line_buffer.partition(b"\n")
                                line_buffer = bytearray(remainder)
                                if line in (b"MARK baseline", b"MARK after_load"):
                                    resources[line.decode().split()[1]] = child_resources(process.pid)
                code = process.wait(timeout=5)
            finally:
                selector.close()
                if process.poll() is None:
                    process.kill(); process.wait(timeout=5)
                record("consumer_run", argv[:3] + ["<silent-port>", "<proxy-port>", "<refused-port>"],
                    consumer, process.returncode, bytes(captured["stdout"]), bytes(captured["stderr"]), timed_out)
            stdout, stderr = bytes(captured["stdout"]), bytes(captured["stderr"])
            if code or timed_out:
                raise RuntimeError("native observation consumer failed or exceeded its deadline")
            if SECRET.encode() in stdout or SECRET.encode() in stderr:
                raise RuntimeError("native default output leaked a secret fixture")
            lines = stdout.decode().splitlines()
            found = {line.split()[1] for line in lines if line.startswith("CHECK ") and line.endswith(" PASS")}
            if found != CHECKS or "M10_005_INSTALLED_OBSERVATION_PASS" not in lines:
                raise RuntimeError(f"consumer checks incomplete: {sorted(CHECKS - found)}")
            report["checks"] = {name: "PASS" for name in sorted(found)}
            if not proxy.authenticated_407 or silent.accepted == 0:
                raise RuntimeError("real native silent-TLS/authenticated-407 peer was not exercised")
            report["fixtures"] = {"silent_tcp_accepted": silent.accepted,
                "authenticated_connect_407": proxy.authenticated_407, "secret_output_absent": True}
            if set(resources) != {"baseline", "after_load"}:
                raise RuntimeError("child resource markers were not sampled")
            report["native_resources"] = resources
            before, after = resources["baseline"], resources["after_load"]
            if after["fds"] != before["fds"] or after["tasks"] != before["tasks"]:
                raise RuntimeError("native FD/task ownership did not stabilize after warmup/load")
            report["checks"]["native_fd_task_stability"] = "PASS"
            samples = []
            for line in lines:
                if line.startswith("SAMPLE "):
                    fields = dict(part.split("=", 1) for part in line.split()[1:])
                    samples.append({key: value if key == "mode" else int(value) for key, value in fields.items()})
            modes = ("disabled", "root_buffer", "async_exporter")
            if len(samples) != 9 or any(sum(row["mode"] == mode for row in samples) != 3 for mode in modes):
                raise RuntimeError("bounded three-sample per-mode measurements are incomplete")
            fields = {"mode", "index", "duration_ns", "requests", "events", "drops"}
            if any(set(row) != fields or row["mode"] not in modes or row["index"] not in (0, 1, 2)
                    or row["duration_ns"] <= 0 or row["requests"] != 30 or row["events"] < 0
                    or row["drops"] < 0 or (row["mode"] == "disabled" and row["events"] != 0)
                    or (row["mode"] != "disabled" and row["events"] == 0) for row in samples):
                raise RuntimeError("measurement counters violate the fixed finite schema")
            report["measurement"] = {"samples": samples, "request_count_per_sample": 30,
                "warmup_requests_per_mode": 12, "identical_workload_warmed_before_baseline": True,
                "drop_counter_scope": "cumulative_per_mode_sink_and_collector", "sla_claim": False}
            mean = {mode: sum(row["duration_ns"] for row in samples if row["mode"] == mode) / 3 for mode in modes}
            report["measurement"]["measured_mean_overhead_ratio"] = {
                mode: mean[mode] / mean["disabled"] - 1 for mode in modes if mode != "disabled"}
            report["status"] = "PASS"
        except Exception as error:
            report["status"] = "FAIL"
            report["error"] = redact(str(error) or type(error).__name__)
        finally:
            if silent: silent.close()
            if proxy: proxy.close()
            if refused: refused.close()
    output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(f"M10-005 installed observation {report['status']}")
    return 0 if report["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
