#!/usr/bin/env python3
"""Exercise the public WebSocket consumer from a fresh extracted production archive."""
from __future__ import annotations

import argparse
from collections import Counter
import json
import os
from pathlib import Path
import re
import select
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))
from tools import m7_021_linux_release as release
from tools.evidence_digest import artifact_byte_digest, text_evidence_digest

SOURCE = ROOT / "examples/linux/m11_003/websocket.cj"
CHECKS = Counter({name: 1 for name in (
    "ws_h1_host_target_fragments_ping", "wss_h2_authority_target_fragments_ping",
    "native_ipv4_ipv6", "native_explicit_default_ports", "h1_rejection_consume_close",
    "h2_rejection_consume_close", "h1_managed_subprotocol_abrupt_rollback",
    "h2_managed_subprotocol_abrupt_rollback", "tls_canonical_identity_mismatch",
    "native_proxy_auth_isolation", "h2_bounded_backpressure_sibling",
    "h2_cancel_close_races_sibling", "h2_blocked_sender_close_rollback", "native_wss_ip_san_no_dns_sni", "native_shutdown_resource_rollback")})


def public_imports(source: str) -> list[str]:
    imports = re.findall(r"^import (.+)$", source, re.MULTILINE)
    forbidden = {("wirestack", "internal"), ("std", "net")}
    if any(tuple(entry.split()[0].split(".")[:2]) in forbidden for entry in imports):
        raise RuntimeError("consumer imports provider-private or std.net APIs")
    return imports


def redact_output(text: str, replacements: list[tuple[str, str]]) -> str:
    """Remove complete URL tokens before saving evidence."""
    text = re.sub(r"\b[A-Za-z][A-Za-z0-9+.-]*://[^\s<>\"']+", "<redacted-url>", text)
    for actual, replacement in replacements:
        text = text.replace(actual, replacement)
    return text.replace("127.0.0.1", "192.0.2.1").replace("[::1]", "[2001:db8::1]").replace("IP:::1", "IP:2001:db8::1")



def client_hello_name(record: bytes) -> str | None:
    """Read the cleartext SNI extension, without terminating the fixture's TLS connection."""
    if len(record) < 9 or record[0] != 22 or record[5] != 1:
        raise RuntimeError("proxy did not observe a TLS ClientHello")
    hello = record[9:]
    pos = 34
    pos += 1 + hello[pos]
    size = int.from_bytes(hello[pos:pos + 2], "big")
    pos += 2 + size
    pos += 1 + hello[pos]
    end = pos + 2 + int.from_bytes(hello[pos:pos + 2], "big")
    pos += 2
    while pos < end:
        kind = int.from_bytes(hello[pos:pos + 2], "big")
        size = int.from_bytes(hello[pos + 2:pos + 4], "big")
        data = hello[pos + 4:pos + 4 + size]
        if kind == 0:
            if data[2] != 0 or int.from_bytes(data[3:5], "big") != len(data) - 5:
                raise RuntimeError("SNI extension does not contain one DNS name")
            return data[5:].decode("ascii")
        pos += 4 + size
    return None


class ProxyFixture:
    """A bounded real socket proxy. Credentials are consumed here, not at the origin."""
    def __init__(self) -> None:
        self.listener = socket.socket()
        self.listener.bind(("127.0.0.1", 0))
        self.listener.listen(4)
        self.listener.settimeout(120)
        self.port = self.listener.getsockname()[1]
        self.records: list[dict] = []
        self.errors: list[str] = []
        self.workers: list[threading.Thread] = []
        self.thread = threading.Thread(target=self.accept, daemon=True)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *_):
        self.listener.close()
        self.thread.join(2)
        for thread in self.workers:
            thread.join(5)

    def accept(self) -> None:
        try:
            for _ in range(4):
                peer, _ = self.listener.accept()
                thread = threading.Thread(target=self.forward, args=(peer,), daemon=True)
                self.workers.append(thread)
                thread.start()
        except OSError as error:
            self.errors.append(str(error))

    @staticmethod
    def exact(peer: socket.socket, size: int) -> bytes:
        result = b""
        while len(result) < size:
            block = peer.recv(size - len(result))
            if not block:
                raise RuntimeError("fixture TLS record ended early")
            result += block
        return result

    def forward(self, peer: socket.socket) -> None:
        try:
            with peer:
                peer.settimeout(30)
                raw = b""
                while not raw.endswith(b"\r\n\r\n"):
                    if len(raw) >= 32768:
                        raise RuntimeError("proxy request exceeded fixture header bound")
                    raw += self.exact(peer, 1)
                lines = raw.decode("ascii").split("\r\n")
                method, target, version = lines[0].split(" ")
                fields = [line.split(":", 1) for line in lines[1:] if line]
                auth = [value.strip() for name, value in fields if name.lower() == "proxy-authorization"]
                if auth != ["Basic dGVzdDp0ZXN0"]:
                    raise RuntimeError("proxy did not receive exactly its configured authorization")
                if method == "CONNECT":
                    host, port = target.rsplit(":", 1)
                    if host not in ("example.test", "127.0.0.1", "[::1]"):
                        raise RuntimeError("CONNECT did not preserve canonical DNS or literal authority")
                    destination = ("127.0.0.1" if host == "example.test" else host.strip("[]"), int(port))
                    origin_request = None
                else:
                    parsed = urlsplit(target)
                    if method != "GET" or parsed.scheme != "http" or parsed.hostname != "example.test" or parsed.port is None:
                        raise RuntimeError("plaintext proxy did not receive canonical HTTP absolute-form routing")
                    destination = ("127.0.0.1", parsed.port)
                    host = "example.test"
                    origin_target = parsed.path + ("?" + parsed.query if parsed.query else "")
                    kept = [name + ":" + value for name, value in fields if name.lower() != "proxy-authorization"]
                    origin_request = (f"GET {origin_target} {version}\r\n" + "\r\n".join(kept) + "\r\n\r\n").encode("ascii")
                with socket.create_connection(destination, timeout=10) as origin:
                    record = {"method": method, "authority": host + ":" + str(destination[1]), "authorization_present": True,
                        "identity_kind": "dns" if host == "example.test" else "ipv6" if host == "[::1]" else "ipv4"}
                    if origin_request is None:
                        peer.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
                        prefix = self.exact(peer, 5)
                        body = self.exact(peer, int.from_bytes(prefix[3:5], "big"))
                        record["sni"] = client_hello_name(prefix + body)
                        expected_name = "example.test" if host == "example.test" else None
                        if record["sni"] != expected_name:
                            raise RuntimeError("TLS SNI differs from canonical DNS/IP reference identity")
                        origin.sendall(prefix + body)
                    else:
                        record["target"] = origin_target
                        origin.sendall(origin_request)
                    self.records.append(record)
                    origin.settimeout(30)
                    while True:
                        readable, _, _ = select.select([peer, origin], [], [], 30)
                        if not readable:
                            raise RuntimeError("proxy forwarding stalled")
                        for source in readable:
                            data = source.recv(65536)
                            if not data:
                                return
                            (origin if source is peer else peer).sendall(data)
        except Exception as error:
            self.errors.append(str(error))

    def validate(self) -> list[dict]:
        self.thread.join(5)
        for worker in self.workers:
            worker.join(5)
        if self.thread.is_alive() or any(worker.is_alive() for worker in self.workers):
            raise RuntimeError("proxy fixture retained a listener or forwarding worker after consumer close")
        if self.errors or len(self.records) != 4 or Counter(row["method"] for row in self.records) != Counter({"GET": 1, "CONNECT": 3}):
            raise RuntimeError(f"native proxy fixture failed: {self.errors}; methods={[row['method'] for row in self.records]}")
        if next(row for row in self.records if row["method"] == "GET")["target"] != "/proxy%2Fpath?q=%25":
            raise RuntimeError("plaintext proxy changed encoded origin target")
        if Counter(row["identity_kind"] for row in self.records if row["method"] == "CONNECT") != Counter({"dns": 1, "ipv4": 1, "ipv6": 1}):
            raise RuntimeError("proxy failed to exercise DNS and both IP identity kinds")
        return sorted(self.records, key=lambda row: row["method"])


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "docs/evidence/M11-003/installed")
    parser.add_argument("--scratch-parent", type=Path, default=Path.home() / ".cache/agent-tmp")
    args = parser.parse_args()
    output = args.output.resolve()
    if output.relative_to(ROOT).parts[:3] != ("docs", "evidence", "M11-003"):
        raise ValueError("output must stay within M11-003 evidence")
    output.mkdir(parents=True, exist_ok=True)
    parent = args.scratch_parent.resolve()
    parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if shutil.disk_usage(parent).free < 2 * 1024**3:
        raise RuntimeError("scratch requires at least 2 GiB free")
    probe = subprocess.run(["findmnt", "-n", "-o", "FSTYPE", "-T", str(parent)], capture_output=True, text=True, check=True)
    if probe.stdout.strip() == "tmpfs":
        raise RuntimeError("scratch must be disk-backed")
    report = {"schema_version": 1, "task_id": "M11-003", "status": "INCOMPLETE",
        "platform": release.platform_identity(), "release_qualification": "NOT_QUALIFIED", "candidate_committed": False,
        "consumer_source": {"path": str(SOURCE.relative_to(ROOT)), "digest": text_evidence_digest(SOURCE).to_json()},
        "runner_source_digest": text_evidence_digest(Path(__file__)).to_json(), "commands": [],
        "non_claims": ["Working-tree source acceptance, not a qualified release or committed candidate.",
            "Native Linux x86_64 glibc only. No compression, reconnect, or heartbeat engine."]}
    with tempfile.TemporaryDirectory(prefix="wirestack-m11-003-installed-", dir=parent) as directory:
        work = Path(directory)
        os.chmod(work, 0o700)
        env = dict(os.environ, TMPDIR=str(work), TMP=str(work), TEMP=str(work), DISABLE_ZOXIDE="1")
        replacements = sorted(((a, b) for a, b in [(str(work), "<scratch>"), (str(ROOT), "<repo>"),
            (os.environ.get("CANGJIE_HOME", ""), "<sdk>"), (str(Path.home()), "$HOME")] if a), key=lambda row: -len(row[0]))

        def redact(text: str) -> str:
            return redact_output(text, replacements)

        def run(name: str, argv: list[str], cwd: Path, timeout: int = 60) -> str:
            code, timed_out = None, False
            try:
                result = subprocess.run(argv, cwd=cwd, env=env, capture_output=True, timeout=timeout, check=False)
                stdout, stderr, code = result.stdout, result.stderr, result.returncode
            except subprocess.TimeoutExpired as error:
                stdout, stderr, timed_out = error.stdout or b"", error.stderr or b"", True
            streams = {}
            for kind, data in (("stdout", stdout), ("stderr", stderr)):
                path = output / f"{name}.{kind}.log"
                path.write_text(redact(data.decode("utf-8", errors="replace")), encoding="utf-8")
                streams[kind] = {"path": str(path.relative_to(ROOT)), "digest": text_evidence_digest(path).to_json()}
            report["commands"].append({"id": name, "argv": [redact(v) for v in argv], "cwd": redact(str(cwd)),
                "exit_code": code, "timed_out": timed_out, **streams})
            if timed_out or code != 0:
                raise RuntimeError(f"{name} failed; see task evidence logs")
            return redact(stdout.decode("utf-8", errors="replace"))

        try:
            imports = public_imports(SOURCE.read_text())
            payload, manifest = release.collect_payload(ROOT)
            archive = work / "wirestack-m11-003-current.tar.gz"
            release.write_reproducible_archive(archive, payload)
            installed = release.extract_archive(archive, work / "install")
            if ROOT == installed or ROOT in installed.parents:
                raise RuntimeError("consumer installation is inside checkout")
            if json.loads((installed / "release-manifest.json").read_text()) != manifest:
                raise RuntimeError("extracted release manifest differs")
            production = {}
            for source in release.production_sources(installed):
                relative = source.relative_to(installed)
                digest = artifact_byte_digest(source).to_json()
                if digest != artifact_byte_digest(ROOT / relative).to_json():
                    raise RuntimeError(f"installed production source differs from checkout payload: {relative}")
                production[str(relative)] = digest
            report.update(archive_digest=artifact_byte_digest(archive).to_json(), payload_sha256=manifest["payload_sha256"],
                production_sources=production, source_digest_equality=True, public_only_imports=imports)
            run("certificate", ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj", "/CN=example.test",
                "-addext", "subjectAltName=DNS:example.test,IP:127.0.0.1,IP:::1", "-keyout", str(work / "key.pem"), "-out", str(work / "certificate.pem")], work)
            run("certificate-der", ["openssl", "x509", "-in", str(work / "certificate.pem"), "-outform", "DER", "-out", str(work / "certificate.der")], work)
            run("key-der", ["openssl", "pkcs8", "-topk8", "-nocrypt", "-in", str(work / "key.pem"), "-outform", "DER", "-out", str(work / "key.pk8")], work)
            report["toolchain"] = {"compiler": run("compiler", ["cjc", "--version"], work).strip(), "cjpm": run("cjpm", ["cjpm", "--version"], work).strip()}
            consumer = work / "consumer"
            (consumer / "src").mkdir(parents=True)
            consumer_manifest = release.consumer_manifest(installed).replace("wirestack_release_smoke", "wirestack_m11_003_websocket")
            if str(ROOT) in consumer_manifest:
                raise RuntimeError("consumer manifest references checkout")
            (consumer / "cjpm.toml").write_text(consumer_manifest, encoding="utf-8")
            shutil.copy2(SOURCE, consumer / "src/main.cj")
            run("websocket-build", ["cjpm", "build"], consumer, timeout=600)
            binary = consumer / "target/release/bin/main"
            dynamic = run("websocket-dependencies", ["readelf", "-d", str(binary)], consumer)
            needed = sorted(re.findall(r"\(NEEDED\).*?\[(.*?)\]", dynamic))
            if any(re.search(r"(?:libssl|libcrypto|libz[.-]|libzstd|libbz2|liblzma|libbrotli)", name, re.IGNORECASE) for name in needed):
                raise RuntimeError("consumer acquired an OpenSSL or compression dependency")
            with ProxyFixture() as proxy:
                text = run("websocket-run", [str(binary), str(work / "certificate.der"), str(work / "key.pk8"), str(proxy.port)], consumer, timeout=120)
                records = proxy.validate()
            checks = Counter(re.findall(r"^CHECK ([a-z0-9_]+) PASS$", text, re.MULTILINE))
            if checks != CHECKS or text.splitlines().count("M11_003_INSTALLED_WEBSOCKET_PASS") != 1:
                raise RuntimeError(f"consumer CHECK multiset differs: {dict(checks)}")
            capacity_rows = re.findall(r"^CAPACITY frame_limit=(\d+) retained=(\d+) high_water=(\d+) capacity=(\d+) connections=(\d+)$", text, re.MULTILINE)
            if len(capacity_rows) != 1:
                raise RuntimeError("consumer omitted its measured native capacity row")
            frame, retained, high_water, capacity, connections = map(int, capacity_rows[0])
            if frame != 32768 or not 0 < retained <= high_water <= capacity or capacity != 262144 or connections != 1:
                raise RuntimeError("native frame/aggregate/physical-connection capacity evidence differs")
            report["capacity_observation"] = dict(frame_limit=frame, retained_bytes=retained, high_water_bytes=high_water, capacity_bytes=capacity, physical_connections=connections)
            current = {str(path.relative_to(ROOT)): artifact_byte_digest(path).to_json() for path in release.production_sources(ROOT)}
            if current != production or text_evidence_digest(SOURCE).to_json() != report["consumer_source"]["digest"]:
                raise RuntimeError("source changed during installed proof; rerun against stabilized bytes")
            report.update(status="PASS", pass_checks=dict(checks), native_needed=needed, binary_digest=artifact_byte_digest(binary).to_json(),
                proxy_observations=[{key: redact(value) if isinstance(value, str) else value for key, value in row.items()} for row in records],
                checkout_path_dependency=False, external_openssl_dependencies=[], additional_compression_dependencies=[])
        except Exception as error:
            report.update(status="FAIL", error=redact(str(error)))
        finally:
            (output / "report.json").write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(json.dumps({"status": report["status"], "report": str((output / "report.json").relative_to(ROOT))}))
    return 0 if report["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
