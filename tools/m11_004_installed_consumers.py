#!/usr/bin/env python3
"""Build and exercise independent applications against an extracted package, with checkout hidden."""
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
import time
from contextlib import contextmanager
import tomllib

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))
from tools import m7_021_linux_release as release
from tools.evidence_digest import artifact_byte_digest, text_evidence_digest, schema_artifact_sha256_equal
from tools.m11_003_native_websocket import ProxyFixture, client_hello_name

APPS = ROOT / "examples/linux/m11_004"
GUIDE = ROOT / "docs/guides/installed-applications-linux.md"
APP_NAMES = ("cli", "decoded", "streams", "service")
REQUIRED_CHECKS = {app: {f"{app}_{scenario}" for scenario in (
    "success", "pre_cancel", "active_cancel", "deadline", "capacity",
    "peer_disconnect", "explicit_close", "cleanup")} for app in APP_NAMES}
for app, extras in {
    "cli": ("output_failure", "raw_gzip", "proxy_connect"),
    "decoded": ("output_failure", "decoded_gzip"),
    "streams": ("cursor_duplicate_explicit_recover", "post_exactly_once_after_peer_failure", "bounded_slow_consumer_h2_sibling", "untrusted_chain"),
    "service": ("untrusted_rejected", "server_capacity", "ordinary_rotation", "security_cancel", "security_rotation", "graceful_stop"),
}.items():
    REQUIRED_CHECKS[app].update(f"{app}_{scenario}" for scenario in extras)
NATIVE_ARCHIVES = (
    "target/native/current/lib/libwirestack_tls_provider.a",
    "target/native/resolver/current/lib/libwirestack_resolver.a",
    "target/native/http_files/current/lib/libwirestack_http_files.a",
)
ALLOWED_NEEDED = frozenset(("libboundscheck.so", "libcangjie-runtime.so", "libc.so.6", "libm.so.6",
    "libdl.so.2", "libpthread.so.0", "libstdc++.so.6", "libgcc_s.so.1"))

M9_PASS_MARKERS = {
    ("options", "options"): "M9_002_OPTIONS_PASS",
    ("options", "http"): "M9_002_HTTP_CONNECTOR_PASS",
    ("options", "invalid"): "M9_002_INVALID_ADMISSION_PASS",
    ("udp", "disconnect"): "M9_003_DISCONNECT_PASS",
    ("udp", "broadcast"): "M9_003_BROADCAST_PASS",
    ("udp", "ipv4-multicast"): "M9_003_IPV4_MULTICAST_PASS",
    ("udp", "ipv6-multicast"): "M9_003_IPV6_MULTICAST_PASS",
    ("udp", "membership-cleanup"): "M9_003_MEMBERSHIP_ERRORS_CLEANUP_PASS",
    ("udp", "active-receive"): "M9_003_DISCONNECT_ACTIVE_RECEIVE_PASS",
}


def app_files(app: Path) -> list[Path]:
    return [app / "cjpm.toml", *sorted((app / "src").rglob("*.cj"))]


def validate_app(app: Path, name: str) -> list[str]:
    manifest = tomllib.loads((app / "cjpm.toml").read_text())
    package = manifest["package"]
    if package.get("name") != f"wirestack_m11_004_{name}" or package.get("output-type") != "executable":
        raise ValueError("application must be its independent named CJPM executable")
    if manifest.get("dependencies") != {"wirestack": {"path": "../../install/wirestack"}}:
        raise ValueError("application must depend only on its relative extracted package")
    if set(manifest) != {"package", "dependencies"}:
        raise ValueError("application may not override installed native or SDK linkage")
    imports = []
    for path in sorted((app / "src").rglob("*.cj")):
        text = path.read_text()
        imports.extend(re.findall(r"^\s*import\s+([^\n]+)", text, re.MULTILINE))
        if re.search(r"\bforeign\s+func\b", text):
            raise ValueError("application may not declare provider/native accessors")
    if not imports or any(re.search(r"\b(?:wirestack\.internal|std\.net|stdx\.)", line) for line in imports):
        raise ValueError("application imports an internal or legacy network API")
    if name == "cli" and any(re.search(r"\bwirestack\.(?:sse|gzip|observability)\b", line) for line in imports):
        raise ValueError("base CLI imported an optional feature module")
    return imports


def source_regions(apps: Path) -> dict[str, str]:
    regions = {}
    for name in APP_NAMES:
        for path in sorted((apps / name / "src").rglob("*.cj")):
            text = path.read_text()
            for match in re.finditer(r"^[ \t]*// DOC-BEGIN ([a-z0-9-]+)\n(.*?)^[ \t]*// DOC-END \1[ \t]*$", text, re.MULTILINE | re.DOTALL):
                key = f"{path.relative_to(apps).as_posix()}#{match[1]}"
                if key in regions:
                    raise ValueError("duplicate compiled documentation region")
                regions[key] = match[2].rstrip("\n")
    if not regions:
        raise ValueError("compiled applications have no documentation regions")
    return regions


def validate_docs(guide: Path, apps: Path) -> dict[str, str]:
    regions = source_regions(apps)
    snippets = re.findall(r"<!-- compiled: ([^\n]+) -->\n```cangjie\n(.*?)\n```", guide.read_text(), re.DOTALL)
    if not snippets or len({key for key, _ in snippets}) != len(snippets):
        raise ValueError("documentation requires distinct bound compiled snippets")
    if any(key not in regions or regions[key] != body for key, body in snippets):
        raise ValueError("documentation code drifted from its compiled application")
    documented = {key.split("/", 1)[0] for key, _ in snippets}
    if documented != set(APP_NAMES):
        raise ValueError("documentation omitted a compiled application")
    return {key: body for key, body in snippets}


def validate_installed(installed: Path, manifest: dict) -> None:
    for entry in manifest["payload"]:
        path = installed / entry["path"]
        if not path.is_file() or path.stat().st_size != entry["bytes"] or not schema_artifact_sha256_equal(entry.get("sha256"), artifact_byte_digest(path).sha256):
            raise ValueError("installed archive inventory is missing or changed")
    if not all((installed / name).is_file() for name in NATIVE_ARCHIVES):
        raise ValueError("installed package lacks a required static native archive")


def validate_needed(names: list[str]) -> None:
    if not names or set(names) - ALLOWED_NEEDED:
        raise ValueError("application has an undeclared implicit system dependency")


def validate_checks(text: str, app: str) -> dict[str, int]:
    checks = Counter(re.findall(r"^CHECK ([a-z0-9_]+) PASS$", text, re.MULTILINE))
    if REQUIRED_CHECKS[app] != checks.keys() or any(count != 1 for count in checks.values()):
        raise ValueError("application omitted or duplicated native acceptance scenarios")
    if text.splitlines().count("APP_ACCEPTANCE_PASS") != 1:
        raise ValueError("application did not complete acceptance")
    return dict(checks)


class SingleConnectProxy(ProxyFixture):
    """Reuse the tested bounded wire forwarder for exactly one CLI CONNECT."""
    def __init__(self) -> None:
        super().__init__()
        self.stopping = threading.Event()
        self.peers = []
        self.listener.settimeout(0.2)

    def __exit__(self, *_):
        self.stopping.set()
        self.listener.close()
        for peer in self.peers:
            try:
                peer.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
        self.thread.join(2)
        for worker in self.workers:
            worker.join(5)
        if self.thread.is_alive() or any(worker.is_alive() for worker in self.workers):
            raise ValueError("CLI proxy failed bounded shutdown")

    def accept(self) -> None:
        expires = time.monotonic() + 180
        while not self.stopping.is_set() and time.monotonic() < expires:
            try:
                peer, _ = self.listener.accept()
                self.peers.append(peer)
                worker = threading.Thread(target=self.forward, args=(peer,), daemon=True)
                self.workers.append(worker)
                worker.start()
                return
            except socket.timeout:
                continue
            except OSError:
                if not self.stopping.is_set():
                    self.errors.append("proxy accept failed")
                return
        if not self.stopping.is_set():
            self.errors.append("proxy accept deadline exceeded")

    def forward(self, peer: socket.socket) -> None:
        try:
            with peer:
                peer.settimeout(30)
                raw = b""
                while not raw.endswith(b"\r\n\r\n"):
                    if len(raw) >= 32768:
                        raise ValueError("proxy request exceeded the header bound")
                    raw += self.exact(peer, 1)
                lines = raw.decode("ascii").split("\r\n")
                method, target, _ = lines[0].split(" ")
                fields = [line.split(":", 1) for line in lines[1:] if line]
                authorization = [value.strip() for name, value in fields if name.lower() == "proxy-authorization"]
                host, port = target.rsplit(":", 1)
                if method != "CONNECT" or host != "example.test" or authorization != ["Basic dGVzdDp0ZXN0"]:
                    raise ValueError("CLI proxy authority or explicit credentials differ")
                with socket.create_connection(("127.0.0.1", int(port)), timeout=10) as origin:
                    peer.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
                    prefix = self.exact(peer, 5)
                    size = int.from_bytes(prefix[3:5], "big")
                    if size > 18432:
                        raise ValueError("TLS record exceeded its wire bound")
                    hello = prefix + self.exact(peer, size)
                    if client_hello_name(hello) != "example.test":
                        raise ValueError("CLI proxy TLS SNI differs from DNS identity")
                    origin.sendall(hello)
                    record = {"method": method, "identity_kind": "dns", "sni": "example.test", "authorization_present": True}
                    self.records.append(record)
                    while True:
                        readable, _, _ = select.select([peer, origin], [], [], 30)
                        if not readable:
                            raise TimeoutError("CLI proxy forwarding deadline exceeded")
                        for source in readable:
                            terminal_side = "consumer" if source is peer else "origin"
                            try:
                                data = source.recv(65536)
                                if not data:
                                    record.update(terminal="eof", terminal_side="consumer" if source is peer else "origin")
                                    return
                                terminal_side = "origin" if source is peer else "consumer"
                                (origin if source is peer else peer).sendall(data)
                            except ConnectionResetError as error:
                                record.update(terminal="reset", native_code=error.errno, terminal_side=terminal_side)
                                return
        except Exception as error:
            self.errors.append(type(error).__name__ + ": " + str(error))
    def validate(self) -> list[dict]:
        self.thread.join(5)
        for worker in self.workers:
            worker.join(5)
        if self.thread.is_alive() or any(worker.is_alive() for worker in self.workers) or self.errors:
            raise ValueError(f"CLI proxy retained a worker or failed forwarding: {self.errors}")
        if len(self.records) != 1 or self.records[0]["method"] != "CONNECT":
            raise ValueError("CLI did not execute exactly one real proxy CONNECT")
        return self.records


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "docs/evidence/M11-004/installed")
    parser.add_argument("--scratch-parent", type=Path, default=Path.home() / ".cache/agent-tmp")
    parser.add_argument("--include-m9", action="store_true", help="Run actual M9 option and UDP probes on their qualified SDK.")
    parser.add_argument("--validate-only", action="store_true")
    args = parser.parse_args()
    if args.validate_only:
        for name in APP_NAMES:
            validate_app(APPS / name, name)
        validate_docs(GUIDE, APPS)
        print("M11_004_APPLICATION_CONTRACT_PASS")
        return 0
    output = args.output.resolve()
    if output.relative_to(ROOT).parts[:3] != ("docs", "evidence", "M11-004"):
        raise ValueError("output must remain in this task's evidence")
    output.mkdir(parents=True, exist_ok=True)
    parent = args.scratch_parent.resolve()
    parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if shutil.disk_usage(parent).free < 2 * 1024**3:
        raise ValueError("installed acceptance needs 2 GiB of disk-backed scratch")
    if subprocess.check_output(["findmnt", "-n", "-o", "FSTYPE", "-T", str(parent)], text=True).strip() == "tmpfs":
        raise ValueError("installed acceptance scratch cannot be tmpfs")
    report = {"schema_version": 1, "task_id": "M11-004", "status": "INCOMPLETE",
        "platform": release.platform_identity(), "release_qualification": "NOT_QUALIFIED", "candidate_committed": False,
        "runner_digest": text_evidence_digest(Path(__file__)).to_json(), "commands": [], "consumers": {}}
    with tempfile.TemporaryDirectory(prefix="wirestack-m11-004-installed-", dir=parent) as directory:
        work = Path(directory)
        os.chmod(work, 0o700)
        env = dict(os.environ, TMPDIR=str(work), TMP=str(work), TEMP=str(work), DISABLE_ZOXIDE="1")
        substitutions = sorted(((a, b) for a, b in (
            (str(work), "<scratch>"), (str(ROOT), "<repo>"),
            (os.environ.get("CANGJIE_HOME", ""), "<sdk>"), (str(Path.home()), "$HOME")) if a), key=lambda pair: -len(pair[0]))

        def redact(text: str) -> str:
            for actual, replacement in substitutions:
                text = text.replace(actual, replacement)
            text = re.sub(r"https?://[^\s\"']+|wss?://[^\s\"']+", "<controlled-url>", text)
            return text.replace("test:test", "<fixture-credentials>").replace("127.0.0.1", "192.0.2.1")

        def hidden(argv: list[str], cwd: Path) -> list[str]:
            return ["bwrap", "--die-with-parent", "--ro-bind", "/", "/", "--bind", str(work), str(work), "--tmpfs", str(ROOT), "--chdir", str(cwd), "--", *argv]

        def run(name: str, argv: list[str], cwd: Path, timeout: int = 60, *, isolated: bool = True, extra_env: dict | None = None, expected_exit: int = 0, private_ipv6_route: bool = False) -> str:
            command = hidden(argv, cwd) if isolated else argv
            if private_ipv6_route:
                command = ["unshare", "--user", "--map-root-user", "--net", "--", "python3", "-c", "import os,sys,fcntl,struct,socket,subprocess\nfd=os.open('/dev/net/tun',os.O_RDWR)\ntry:\n fcntl.ioctl(fd,0x400454ca,struct.pack('16sH',b'ws-mcast',0x1002))\n for command in (['ip','link','set','lo','up'],['ip','link','set','ws-mcast','up'],['ip','-6','addr','add','fe80::1/64','dev','ws-mcast','nodad'],['ip','-6','route','add','ff00::/8','dev','ws-mcast']): subprocess.run(command,check=True)\n environment=dict(os.environ,WIRESTACK_M9_003_IPV6_INTERFACE_INDEX=str(socket.if_nametoindex('ws-mcast')))\n result=subprocess.run(sys.argv[1:],env=environment).returncode\nfinally:\n os.close(fd)\nsys.exit(result)\n", *command]
            files = {kind: work / f"{name}.{kind}.raw" for kind in ("stdout", "stderr")}
            code, timed_out = None, False
            with files["stdout"].open("wb") as stdout, files["stderr"].open("wb") as stderr:
                try:
                    completed = subprocess.run(command, cwd=cwd, env=env | (extra_env or {}), stdout=stdout, stderr=stderr, timeout=timeout)
                    code = completed.returncode
                except subprocess.TimeoutExpired:
                    timed_out = True
            records = {}
            text = ""
            for kind, path in files.items():
                destination = output / f"{name}.{kind}.log"
                # Real command streams remain file-backed. Published diagnostics are normalized line by line.
                with path.open("r", errors="replace") as source, destination.open("w") as target:
                    for line in source:
                        target.write(redact(line))
                records[kind] = {"path": str(destination.relative_to(ROOT)), "digest": text_evidence_digest(destination).to_json()}
                if kind == "stdout":
                    text = destination.read_text()
            report["commands"].append({"id": name, "argv": [redact(value) for value in command], "cwd": redact(str(cwd)),
                "checkout_hidden": isolated, "exit_code": code, "expected_exit_code": expected_exit, "timed_out": timed_out, **records})
            if timed_out or code != expected_exit:
                raise RuntimeError(f"{name} failed; exact command and logs retained")
            return text
        @contextmanager
        def endpoint(name: str, argv: list[str], cwd: Path, ready: str, stopped: str):
            command = hidden(argv, cwd)
            stderr_path = work / f"{name}.stderr.raw"
            captured = bytearray()
            process = None
            timed_out = False
            try:
                with stderr_path.open("wb") as stderr:
                    process = subprocess.Popen(command, cwd=cwd, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=stderr)
                    expires = time.monotonic() + 5
                    port = None
                    while port is None:
                        if time.monotonic() >= expires or process.poll() is not None:
                            raise RuntimeError("operational endpoint did not become ready within five seconds")
                        readable, _, _ = select.select([process.stdout], [], [], 0.1)
                        if readable:
                            captured.extend(os.read(process.stdout.fileno(), 8192))
                            if len(captured) > 16384:
                                raise ValueError("operational endpoint readiness output exceeded its bound")
                            match = re.search(rb"^" + ready.encode() + rb" port=(\d+)\r?$", captured, re.MULTILINE)
                            if match:
                                port = int(match[1])
                    yield port
                    process.stdin.write(b"stop\n")
                    process.stdin.flush()
                    try:
                        remaining, _ = process.communicate(timeout=10)
                        captured.extend(remaining)
                    except subprocess.TimeoutExpired:
                        timed_out = True
                        raise RuntimeError("operational endpoint failed bounded stop")
                    if process.returncode != 0 or captured.decode(errors="replace").splitlines().count(stopped) != 1:
                        raise ValueError("operational endpoint did not close successfully")
            finally:
                if process is not None and process.poll() is None:
                    process.kill()
                    remaining, _ = process.communicate(timeout=5)
                    captured.extend(remaining)
                records = {}
                for kind, raw in (("stdout", captured.decode(errors="replace")), ("stderr", stderr_path.read_text(errors="replace"))):
                    path = output / f"{name}.{kind}.log"
                    path.write_text(redact(raw))
                    records[kind] = {"path": str(path.relative_to(ROOT)), "digest": text_evidence_digest(path).to_json()}
                report["commands"].append({"id": name, "argv": [redact(value) for value in command], "cwd": redact(str(cwd)),
                    "checkout_hidden": True, "exit_code": None if process is None else process.returncode, "timed_out": timed_out, **records})

        try:
            report["documented_regions"] = {key: text_evidence_digest(APPS / key.split("#")[0]).to_json() for key in validate_docs(GUIDE, APPS)}
            imports = {name: validate_app(APPS / name, name) for name in APP_NAMES}
            payload, manifest = release.collect_payload(ROOT)
            archive = work / "wirestack-current.tar.gz"
            release.write_reproducible_archive(archive, payload)
            extracted = release.extract_archive(archive, work / "install")
            installed = work / "install/wirestack"
            extracted.rename(installed)
            validate_installed(installed, manifest)
            production = {str(path.relative_to(installed)): artifact_byte_digest(path).to_json() for path in release.production_sources(installed)}
            if production != {str(path.relative_to(ROOT)): artifact_byte_digest(path).to_json() for path in release.production_sources(ROOT)}:
                raise ValueError("installed production source differs from the checkout")
            report.update(archive_digest=artifact_byte_digest(archive).to_json(), payload_sha256=manifest["payload_sha256"],
                production_sources=production, source_digest_equality=True)
            probe = run("checkout-hidden", ["python3", "-c", f"from pathlib import Path; p=Path({str(ROOT)!r}); assert p.is_dir() and not any(p.iterdir()); print('CHECKOUT_HIDDEN_PASS')"], work)
            if probe.strip() != "CHECKOUT_HIDDEN_PASS":
                raise ValueError("checkout hiding probe did not complete")
            report["checkout_hidden"] = {"mechanism": "private bubblewrap mount namespace", "probe": "PASS", "build_and_runtime": True}
            report["toolchain"] = {"compiler": run("compiler", ["cjc", "--version"], work).strip(),
                "cjpm": run("cjpm", ["cjpm", "--version"], work).strip(),
                "compiler_binary_digest": artifact_byte_digest(Path(shutil.which("cjc"))).to_json()}
            run("certificate", ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj", "/CN=example.test",
                "-addext", "subjectAltName=DNS:example.test,IP:127.0.0.1", "-keyout", str(work / "key.pem"), "-out", str(work / "certificate.pem")], work, isolated=False)
            run("certificate-der", ["openssl", "x509", "-in", str(work / "certificate.pem"), "-outform", "DER", "-out", str(work / "certificate.der")], work, isolated=False)
            run("key-der", ["openssl", "pkcs8", "-topk8", "-nocrypt", "-in", str(work / "key.pem"), "-outform", "DER", "-out", str(work / "key.pk8")], work, isolated=False)
            run("untrusted", ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj", "/CN=other.test",
                "-keyout", str(work / "unused-key.pem"), "-out", str(work / "untrusted.pem")], work, isolated=False)
            run("untrusted-der", ["openssl", "x509", "-in", str(work / "untrusted.pem"), "-outform", "DER", "-out", str(work / "untrusted.der")], work, isolated=False)
            certificates = [str(work / "certificate.der"), str(work / "key.pk8"), str(work / "untrusted.der")]
            for name in APP_NAMES:
                source = APPS / name
                consumer = work / "consumers" / name
                shutil.copytree(source, consumer, ignore=shutil.ignore_patterns("target", "cjpm.lock"))
                source_digests = {str(path.relative_to(ROOT)): text_evidence_digest(path).to_json() for path in app_files(source)}
                run(f"{name}-build", ["cjpm", "build"], consumer, timeout=600)
                binary = consumer / "target/release/bin/main"
                run(f"{name}-help", [str(binary), "--help"], consumer)
                dynamic = run(f"{name}-dependencies", ["readelf", "-d", str(binary)], consumer)
                needed = sorted(re.findall(r"\(NEEDED\).*?\[(.*?)\]", dynamic))
                validate_needed(needed)
                if name == "cli":
                    with SingleConnectProxy() as proxy:
                        text = run(f"{name}-acceptance", [str(binary), "self-check", *certificates, str(proxy.port)], consumer, timeout=180)
                        report["proxy_observations"] = proxy.validate()
                else:
                    text = run(f"{name}-acceptance", [str(binary), "self-check", *certificates], consumer, timeout=180)
                checks = validate_checks(text, name)
                symbols = run(f"{name}-symbols", ["nm", "--defined-only", str(binary)], consumer)
                feature_symbols = {feature: bool(re.search(rf"wirestack[.$_:]+{feature}(?:[.$_:]|[0-9])", symbols)) for feature in ("sse", "gzip", "observability")}
                if name == "cli" and any(feature_symbols.values()):
                    raise ValueError("base CLI linked an optional module")
                if name == "decoded" and not feature_symbols["gzip"] or name == "streams" and not feature_symbols["sse"]:
                    raise ValueError("optional-module symbol probe did not observe the enabled feature")
                report["consumers"][name] = {"source_digests": source_digests, "public_imports": imports[name], "binary_digest": artifact_byte_digest(binary).to_json(),
                    "native_needed": needed, "pass_checks": checks, "feature_symbols": feature_symbols, "checkout_hidden_build_and_run": True}
            oversized_trust = work / "oversized-trust.der"
            oversized_trust.write_bytes(bytes(65537))
            operational = {}
            service = work / "consumers/service"
            service_binary = service / "target/release/bin/main"
            with endpoint("service-operational", [str(service_binary), "serve", "--port", "0", "--certificate", certificates[0], "--key", certificates[1], "--budget-ms", "20000"], service, "SERVICE_READY", "SERVICE_STOPPED") as port:
                for name in ("cli", "decoded"):
                    app = work / "consumers" / name
                    path = work / f"{name}-download.bin"
                    text = run(f"{name}-operational-download", [str(app / "target/release/bin/main"), "download", "--url", f"https://127.0.0.1:{port}/download", "--output", str(path), "--trust", certificates[0], "--budget-ms", "5000"], app)
                    if path.read_bytes() != b"download" or "DOWNLOAD_PASS bytes=8" not in text:
                        raise ValueError("operational CLI/service download bytes differ")
                    operational[name] = {"status": "PASS", "bytes": 8, "output_digest": artifact_byte_digest(path).to_json(), "partial_file_absent": not Path(str(path) + ".partial").exists()}
                    stopped_path = work / f"{name}-cancelled.bin"
                    run(f"{name}-operational-pre-cancel", [str(app / "target/release/bin/main"), "download", "--url", f"https://127.0.0.1:{port}/download", "--output", str(stopped_path), "--trust", certificates[0], "--pre-cancel"], app, expected_exit=1)
                    diagnostic = (output / f"{name}-operational-pre-cancel.stderr.log").read_text()
                    if "category=network phase=http_body code=1" not in diagnostic or stopped_path.exists() or Path(str(stopped_path) + ".partial").exists():
                        raise ValueError("pre-cancel CLI failed typed phase diagnostics or output cleanup")
                    oversized_path = work / f"{name}-oversized-trust.bin"
                    run(f"{name}-oversized-trust", [str(app / "target/release/bin/main"), "download", "--url", f"https://127.0.0.1:{port}/download", "--output", str(oversized_path), "--trust", str(oversized_trust), "--budget-ms", "5000"], app, expected_exit=1)
                    diagnostic = (output / f"{name}-oversized-trust.stderr.log").read_text()
                    if "ERROR category=application code=90" not in diagnostic or oversized_path.exists() or Path(str(oversized_path) + ".partial").exists():
                        raise ValueError("oversized trust file was not rejected by the bounded reader")
                    operational[name]["oversized_trust_rejected"] = True
            stream_app = work / "consumers/streams"
            stream_binary = stream_app / "target/release/bin/main"
            with endpoint("streams-operational-fixture", [str(stream_binary), "fixture", *certificates[:2]], stream_app, "STREAM_READY", "STREAM_STOPPED") as port:
                sse_text = run("streams-operational-sse", [str(stream_binary), "sse", f"https://127.0.0.1:{port}/stream", "--trust", certificates[0], "--budget-ms", "5000", "--max-events", "1", "--recover", "0"], stream_app)
                socket_text = run("streams-operational-websocket", [str(stream_binary), "websocket", f"wss://127.0.0.1:{port}/socket", "--trust", certificates[0], "--budget-ms", "5000", "--max-frames", "1", "--recover", "0", "--command", "echo"], stream_app)
                run("streams-oversized-trust", [str(stream_binary), "sse", f"https://127.0.0.1:{port}/stream", "--trust", str(oversized_trust), "--budget-ms", "5000", "--max-events", "1", "--recover", "0"], stream_app, expected_exit=1)
                diagnostic = (output / "streams-oversized-trust.stderr.log").read_text()
                if "ERROR category=application phase=operation code=1" not in diagnostic:
                    raise ValueError("oversized stream trust file did not produce the expected application failure")
                operational["streams"] = {"status": "PASS", "sse_output": sse_text.strip(), "websocket_output": socket_text.strip(), "oversized_trust_rejected": True}
            operational["service"] = {"status": "PASS", "stdin_stop": "SERVICE_STOPPED", "fixture_bytes_verified": True}
            report["operational_commands"] = operational
            if args.include_m9:
                run_m9(installed, work, env, run, report)
            else:
                report["m9_integration"] = {"status": "NOT_RUN", "reason": "Separate SDK-qualified native probe profile is required; no support claim from this omission."}
            validate_installed(installed, manifest)
            if production != {str(path.relative_to(ROOT)): artifact_byte_digest(path).to_json() for path in release.production_sources(ROOT)}:
                raise ValueError("production source changed during installed proof")
            for name, consumer in report["consumers"].items():
                if consumer["source_digests"] != {str(path.relative_to(ROOT)): text_evidence_digest(path).to_json() for path in app_files(APPS / name)}:
                    raise ValueError("application source changed during installed proof")
            report.update(status="PASS", pass_check_count=sum(len(item["pass_checks"]) for item in report["consumers"].values()))
        except Exception as error:
            report.update(status="FAIL", error=redact(str(error)))
        finally:
            (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"status": report["status"], "report": str((output / "report.json").relative_to(ROOT))}))
    return 0 if report["status"] == "PASS" else 1



def validate_m9_pass_marker(text: str, consumer: str, mode: str) -> None:
    expected = M9_PASS_MARKERS.get((consumer, mode))
    if expected is None:
        raise ValueError(f"unknown installed M9 mode {consumer}/{mode}")
    markers = [line for line in text.splitlines() if re.fullmatch(r"M9_00[23]_[A-Z0-9_]+_PASS", line)]
    if markers != [expected]:
        raise ValueError(f"installed M9 {consumer}/{mode} marker mismatch: expected exactly {expected}")


def run_m9(installed: Path, work: Path, env: dict, run, report: dict) -> None:
    """Run existing public probes from this exact installed archive, not historical reports."""
    if "Compiler: 1.1.3 " not in report["toolchain"]["compiler"]:
        raise ValueError("M9 native option/UDP probes require the SDK1.1.3 qualification profile")
    entries = {"options": (ROOT / "examples/linux/m9_002/socket_options.cj", "wirestack_m9_002_socket_options"),
        "udp": (ROOT / "examples/linux/m9_003/udp_lifecycle.cj", "wirestack_m9_003_udp_lifecycle")}
    m9 = {"status": "INCOMPLETE", "consumers": {}}
    for name, (source, package) in entries.items():
        consumer = work / "consumers" / f"m9-{name}"
        (consumer / "src").mkdir(parents=True)
        (consumer / "cjpm.toml").write_text(release.consumer_manifest(installed).replace("wirestack_release_smoke", package).replace(json.dumps(str(installed.resolve())), json.dumps("../../install/wirestack")))
        shutil.copy2(source, consumer / "src/main.cj")
        run(f"m9-{name}-build", ["cjpm", "build"], consumer, timeout=600)
        binary = consumer / "target/release/bin/main"
        modes = ("options", "http", "invalid") if name == "options" else ("disconnect", "broadcast", "ipv4-multicast", "ipv6-multicast", "membership-cleanup", "active-receive")
        outputs = {}
        for mode in modes:
            extra = {} if name == "options" else dict(WIRESTACK_M9_003_MODE=mode, WIRESTACK_M9_003_IPV4_INTERFACE_INDEX=str(socket.if_nametoindex("lo")), WIRESTACK_M9_003_IPV6_INTERFACE_INDEX=str(socket.if_nametoindex("lo")))
            argv = [str(binary), *([mode] if name == "options" else [])]
            text = run(f"m9-{name}-{mode}", argv, consumer, extra_env=extra, private_ipv6_route=name == "udp" and mode == "ipv6-multicast")
            validate_m9_pass_marker(text, name, mode)
            outputs[mode] = "PASS"
        m9["consumers"][name] = {"source": str(source.relative_to(ROOT)), "digest": text_evidence_digest(source).to_json(),
            "binary_digest": artifact_byte_digest(binary).to_json(), "modes": outputs, "checkout_hidden_build_and_run": True}
    m9["status"] = "PASS"
    report["m9_integration"] = m9


if __name__ == "__main__":
    raise SystemExit(main())
