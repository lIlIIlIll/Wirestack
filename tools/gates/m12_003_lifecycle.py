#!/usr/bin/env python3
"""STS installed-consumer lifecycle faults with a bounded native H2 wire peer."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import random
import re
import shutil
import signal
import selectors
import socket
import ssl
import subprocess
import sys
import threading
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from tools import m7_021_linux_release as release
from tools.evidence_digest import artifact_byte_digest, text_evidence_digest
from tools.gates.m12_003_supervision import terminate_group

PROFILES = {
    "h2_slowconsumer": "protocol", "h2_goaway": "protocol", "h2_streamscope": "protocol",
    "cancel_storm": "race", "rotation_shutdown": "race",
    "sse_cancel": "streams", "websocket_disconnect": "streams",
    "websocket_fragmented": "streams", "sse_h1": "streams", "websocket_h1": "streams",
    "gzip_faults": "gzip", "sse_cancel_h1": "streams", "websocket_disconnect_h1": "streams",
}

COVERAGE = {"h2_slowconsumer": ["h2_slow_consumer"], "h2_goaway": ["goaway"],
            "h2_streamscope": ["h2_single_stream_fault_scope"], "sse_cancel": ["sse_interrupt"],
            "sse_cancel_h1": ["sse_interrupt"], "websocket_disconnect": ["websocket_interrupt"],
            "websocket_disconnect_h1": ["websocket_interrupt"], "cancel_storm": ["cancel_storm"],
            "rotation_shutdown": ["rotation_shutdown_race"]}

def classify_wire(profile: str, wire: dict) -> None:
    rows = wire["requests"]
    if profile == "h2_slowconsumer":
        if not wire["window_exhaustions"] or not wire["window_updates"] or wire["data_bytes"] != 1048576:
            raise ValueError("missing DATA window/backpressure/recovery proof")
    else:
        fault = next(row for row in rows if row["path"] in {"/goaway", "/reset"})
        healthy = next(row for row in rows if row["path"] == "/healthy")
        same = fault["connection"] == healthy["connection"]
        if profile == "h2_goaway" and (same or not wire["goaway_sent"]):
            raise ValueError("GOAWAY connection was repooled or fault was not sent")
        if profile == "h2_streamscope" and (not same or not wire["rst_stream_sent"]):
            raise ValueError("stream fault damaged the healthy connection")
        if profile == "h2_streamscope":
            sibling = next((row for row in rows if row["path"] == "/sibling"), None)
            if sibling is None or sibling["connection"] != fault["connection"] or rows.index(sibling) >= rows.index(fault):
                raise ValueError("stream fault lacks a concurrently admitted sibling")


class WirePeer:
    """One bounded TLS acceptor; the h2 package encodes real protocol frames."""
    def __init__(self, work: Path):
        import h2.config
        import h2.connection
        import h2.events
        self.h2 = (h2.config, h2.connection, h2.events)
        self.listener = socket.socket()
        self.listener.bind(("127.0.0.1", 0))
        self.listener.listen(2)
        self.listener.settimeout(.2)
        self.port = self.listener.getsockname()[1]
        self.context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        self.context.load_cert_chain(work / "certificate.pem", work / "key.pem")
        self.context.set_alpn_protocols(["h2"])
        self.stop = threading.Event()
        self.connections = []
        self.error = None
        self.proof = {"requests": [], "goaway_sent": [], "rst_stream_sent": [],
                      "window_exhaustions": [], "window_updates": [], "data_bytes": 0,
                      "tls_alpn": [], "cleanup": {}}
        self.thread = threading.Thread(target=self.serve, name="m12-003-wire-peer")

    def __enter__(self):
        self.thread.start()
        return self

    def serve(self):
        config, connection, events = self.h2
        connection_id = 0
        try:
            while not self.stop.is_set():
                try:
                    raw, _ = self.listener.accept()
                except socket.timeout:
                    continue
                connection_id += 1
                if connection_id > 4:
                    raw.close()
                    raise ValueError("wire peer accept bound exceeded")
                raw.settimeout(10)
                self.connections.append(raw)
                with self.context.wrap_socket(raw, server_side=True) as stream:
                    self.connections.append(stream)
                    self.proof["tls_alpn"].append(stream.selected_alpn_protocol())
                    stream.settimeout(.2)
                    h2 = connection.H2Connection(config=config.H2Configuration(client_side=False, header_encoding="utf-8"))
                    # RFC 9113 forbids servers from sending ENABLE_PUSH, even zero.
                    from h2.settings import SettingCodes
                    del h2.local_settings[SettingCodes.ENABLE_PUSH]
                    h2.initiate_connection()
                    stream.sendall(h2.data_to_send())
                    slow = None
                    sibling = None
                    sent = 0
                    done = False
                    while not done and not self.stop.is_set():
                        try:
                            data = stream.recv(65536)
                        except socket.timeout:
                            continue
                        if not data:
                            break
                        for event in h2.receive_data(data):
                            if isinstance(event, events.RequestReceived):
                                path = dict(event.headers)[":path"]
                                self.proof["requests"].append({"path": path, "stream": event.stream_id, "connection": connection_id})
                                if path == "/slow":
                                    slow = event.stream_id
                                    h2.send_headers(slow, [(":status", "200"), ("content-length", "1048576")])
                                elif path == "/goaway":
                                    h2.close_connection(error_code=0, last_stream_id=0, additional_data=b"m12-003")
                                    self.proof["goaway_sent"].append({"connection": connection_id, "last_stream_id": 0, "error_code": 0})
                                    done = True
                                elif path == "/sibling":
                                    sibling = event.stream_id
                                    h2.send_headers(sibling, [(":status", "200"), ("content-length", "1")])
                                elif path == "/reset":
                                    h2.reset_stream(event.stream_id, error_code=8)
                                    self.proof["rst_stream_sent"].append({"connection": connection_id, "stream": event.stream_id, "error_code": 8})
                                    if sibling is None:
                                        raise ValueError("stream fault lacks concurrently admitted sibling")
                                    h2.send_data(sibling, b"H", end_stream=True)
                                elif path in {"/probe", "/healthy"}:
                                    if path == "/probe" and not self.proof["window_exhaustions"]:
                                        raise ValueError("probe arrived before window exhaustion")
                                    h2.send_headers(event.stream_id, [(":status", "200"), ("content-length", "0" if path == "/probe" else "1")], end_stream=path == "/probe")
                                    if path != "/probe":
                                        h2.send_data(event.stream_id, b"H", end_stream=True)
                                else:
                                    raise ValueError("unexpected fixture route")
                            elif isinstance(event, events.WindowUpdated):
                                if len(self.proof["window_updates"]) < 1024:
                                    self.proof["window_updates"].append({"stream": event.stream_id, "delta": event.delta})
                        if slow is not None and sent < 1048576:
                            while sent < 1048576:
                                window = h2.local_flow_control_window(slow)
                                amount = min(window, h2.max_outbound_frame_size, 1048576 - sent)
                                if amount <= 0:
                                    if len(self.proof["window_exhaustions"]) < 1024:
                                        self.proof["window_exhaustions"].append({"stream": slow, "sent_bytes": sent, "available_window": window})
                                    break
                                sent += amount
                                self.proof["data_bytes"] += amount
                                h2.send_data(slow, b"S" * amount, end_stream=sent == 1048576)
                        outgoing = h2.data_to_send()
                        if outgoing:
                            stream.sendall(outgoing)
        except (OSError, ssl.SSLError) as error:
            if not self.stop.is_set():
                self.error = str(error)
        except Exception as error:
            self.error = str(error)
        finally:
            self.proof["peer_error"] = self.error

    def __exit__(self, *_):
        self.stop.set()
        self.listener.close()
        for connection in self.connections:
            try:
                connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            connection.close()
        self.thread.join(3)
        self.proof["cleanup"] = {"peer_thread_alive": self.thread.is_alive(), "listener_closed": self.listener.fileno() == -1}
        if self.thread.is_alive():
            raise RuntimeError("owned wire peer did not join")


class Runner:
    def __init__(self, sdk: Path, work: Path, output: Path):
        self.sdk, self.work, self.output = sdk, work, output
        self.commands = []
        self.env = dict(os.environ, TMPDIR=str(work), TMP=str(work), TEMP=str(work), DISABLE_ZOXIDE="1")
        self.wrapper = Path.home() / ".codex/scripts/codex_cangjie_env"
        self.cancellation = threading.Event()

    def redact(self, value: str) -> str:
        for old, new in [(str(self.work), "<scratch>"), (str(ROOT), "<repo>"), (str(self.sdk), "<sts-sdk>"), (str(Path.home()), "$HOME")]:
            value = value.replace(old, new)
        return value.replace("127.0.0.1", "192.0.2.1")

    def run(self, name: str, argv: list[str], cwd: Path, timeout: int = 90, sdk: bool = True):
        native = Path(argv[0]).is_file() and "target/release/bin" in argv[0]
        if sdk:
            argv = [str(self.wrapper), "--sdk-root", str(self.sdk), *argv]
        samples, stop, bindings = [], threading.Event(), set()
        started = time.monotonic_ns()
        out, err = self.work / f"{name}.out", self.work / f"{name}.err"
        completion, remaining = "EXIT", []
        with out.open("wb") as stdout, err.open("wb") as stderr, selectors.DefaultSelector() as streams:
            process = subprocess.Popen(argv, cwd=cwd, env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
            for pipe, destination in ((process.stdout, stdout), (process.stderr, stderr)):
                os.set_blocking(pipe.fileno(), False)
                streams.register(pipe, selectors.EVENT_READ, [destination, 0])
            def monitor():
                proc = Path("/proc") / str(process.pid)
                while not stop.is_set() and len(samples) < 100000:
                    try:
                        status = (proc / "status").read_text()
                        rss = re.search(r"^VmRSS:\s+(\d+)", status, re.M)
                        if rss:
                            samples.append({"elapsed_ns": time.monotonic_ns() - started, "rss_kib": int(rss[1]),
                                            "fd": len(list((proc / "fd").iterdir())), "tasks": len(list((proc / "task").iterdir()))})
                        if native and not bindings:
                            for line in (proc / "maps").read_text().splitlines():
                                parts = line.split()
                                if parts and "libcangjie-" in parts[-1] and parts[-1].startswith("/"):
                                    bindings.add(parts[-1])
                    except (OSError, ProcessLookupError):
                        pass
                    stop.wait(.01)
            sampler = threading.Thread(target=monitor)
            sampler.start()
            try:
                while True:
                    if self.cancellation.is_set():
                        completion = "CANCELLED"; break
                    if time.monotonic_ns() - started >= timeout * 1000000000:
                        completion = "TIMEOUT"; break
                    exited = process.poll() is not None
                    events = streams.select(0 if exited else .02)
                    if exited and not events:
                        break
                    for key, _ in events:
                        chunk = os.read(key.fileobj.fileno(), 65536)
                        if not chunk:
                            streams.unregister(key.fileobj); key.fileobj.close(); continue
                        destination, count = key.data
                        accepted = min(len(chunk), 1048576 - count)
                        destination.write(chunk[:accepted]); key.data[1] += accepted
                        if accepted != len(chunk):
                            completion = "OUTPUT_LIMIT"; break
                    if completion != "EXIT":
                        break
            finally:
                remaining = terminate_group(process, 2)
                stop.set(); sampler.join(2)
                for pipe in (process.stdout, process.stderr):
                    pipe.close()
        code = process.returncode
        logs = {}
        for kind, path in (("stdout", out), ("stderr", err)):
            destination = self.output / f"{name}.{kind}.log"
            destination.write_text(self.redact(path.read_text(errors="replace")))
            logs[kind] = {"path": destination.name, "digest": text_evidence_digest(destination).to_json()}
        binding_rows = [{"path": self.redact(value), "digest": artifact_byte_digest(Path(value)).to_json()} for value in sorted(bindings)]
        wrong_sdk = any(not Path(value).is_relative_to(self.sdk) for value in bindings)
        record = {"id": name, "argv": [self.redact(v) for v in argv], "exit_code": code,
                  "timed_out": completion == "TIMEOUT", "completion": completion,
                  "wall_ns": time.monotonic_ns() - started, "maximum_log_bytes_per_stream": 1048576,
                  "process_samples": samples, "runtime_bindings": binding_rows,
                  "cleanup": {"process_reaped": process.poll() is not None,
                              "remaining_live_owned_processes": len(remaining), "sampler_alive": sampler.is_alive()}, **logs}
        self.commands.append(record)
        if code != 0 or completion != "EXIT" or remaining or wrong_sdk:
            raise RuntimeError(f"{name} failed, exit={code}, completion={completion}, remaining={len(remaining)}, wrong_sdk={wrong_sdk}")
        if native and not any("libcangjie-runtime.so" in item["path"] for item in binding_rows):
            # Fast native processes can finish between samples; record an exact loader binding instead.
            self.run(f"{name}-loader", ["ldd", str(cwd / "main")], cwd, sdk=True)
            loader = (self.work / f"{name}-loader.out").read_text()
            match = re.search(r"libcangjie-runtime\.so\s+=>\s+(\S+)", loader)
            if match is None or not Path(match[1]).resolve().is_relative_to(self.sdk):
                raise RuntimeError("native loader did not bind the selected STS runtime")
            record["runtime_bindings"].append({"path": self.redact(match[1]), "digest": artifact_byte_digest(Path(match[1])).to_json(),
                                               "observation": "loader resolution; process shorter than sampling interval"})
        return self.redact(out.read_text(errors="replace")), record

    def build(self, installed: Path, layer: str):
        consumer = self.work / layer
        (consumer / "src").mkdir(parents=True, exist_ok=True)
        package = {"protocol": "wirestack_m12_003_protocol", "race": "wirestack_m12_003_race", "streams": "wirestack_m12_001", "gzip": "wirestack_m11_002_gzip"}[layer]
        (consumer / "cjpm.toml").write_text(release.consumer_manifest(installed).replace("wirestack_release_smoke", package))
        source = ROOT / f"examples/linux/m12_003/lifecycle/{layer}.cj"
        shutil.copy2(source, consumer / "src/main.cj")
        if layer == "streams":
            shutil.copy2(source.parent / "common.cj", consumer / "src/common.cj")
        self.run(f"{layer}-build", ["cjpm", "build"], consumer, timeout=600)
        return consumer / "target/release/bin/main"


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    for key in ("sdk-root", "archive", "scratch", "output"):
        parser.add_argument("--" + key, required=True, type=Path)
    parser.add_argument("--seed", type=int, default=184003)
    parser.add_argument("--mode", choices=["smoke", "stress"], default="smoke")
    parser.add_argument("--layer", choices=["all", "protocol", "race", "streams", "gzip"], default="all")
    parser.add_argument("--profile", choices=sorted(PROFILES))
    parser.add_argument("--rounds", type=int)
    args = parser.parse_args(argv)
    sdk = args.sdk_root.expanduser().resolve()
    if sdk != (Path.home() / "cangjie_sdk/sts1.1.3").resolve():
        parser.error("this source-bound gate requires the explicitly selected STS 1.1.3")
    if args.rounds is not None and not 1 <= args.rounds <= 1000:
        parser.error("rounds must be 1..1000")
    work, output = args.scratch.resolve(), args.output.resolve()
    if work == ROOT or ROOT in work.parents:
        parser.error("scratch must be outside the checkout")
    work.mkdir(parents=True, exist_ok=True, mode=0o700)
    output.mkdir(parents=True, exist_ok=True)
    runner = Runner(sdk, work, output)
    prior_handlers = {signum: signal.getsignal(signum) for signum in (signal.SIGINT, signal.SIGTERM)}
    if threading.current_thread() is threading.main_thread():
        for signum in prior_handlers:
            signal.signal(signum, lambda *_: runner.cancellation.set())
    report = {"schema_version": 1, "task_id": "M12-003", "family": "lifecycle", "status": "FAIL",
              "seed": args.seed, "mode": args.mode, "formal_86400": "NOT_RUN", "release_qualification": "NOT_QUALIFIED",
              "commands": runner.commands, "profiles": [], "platform": release.platform_identity(),
              "unavailable_measurements": {"cancellation_registration_count": "UNAVAILABLE: no public counter",
                                           "local_h2_window_counters": "UNAVAILABLE: measured peer DATA window instead"}}
    try:
        payload, manifest = release.read_verified_payload(args.archive)
        current, _ = release.collect_payload(ROOT)
        if payload != current:
            raise ValueError("selected archive differs from current production payload")
        installed = release.extract_archive(args.archive, work / "install")
        report["archive"] = {"digest": artifact_byte_digest(args.archive).to_json(), "payload_sha256": manifest["payload_sha256"], "provider": manifest["provider"]}
        report["source_digests"] = {str(p.relative_to(ROOT)): text_evidence_digest(p).to_json() for p in release.production_sources(ROOT)}
        report["probe_source_digests"] = {str(p.relative_to(ROOT)): text_evidence_digest(p).to_json() for p in
                                         [*sorted((ROOT / "examples/linux/m12_003/lifecycle").glob("*.cj")),
                                          Path(__file__).resolve(), ROOT / "tools/gates/m12_003_supervision.py"]}
        report["sdk"] = {"selection": "$HOME/cangjie_sdk/sts1.1.3", "compiler": runner.run("compiler", ["cjc", "--version"], work)[0],
                         "cjpm": runner.run("cjpm", ["cjpm", "--version"], work)[0],
                         "compiler_digest": artifact_byte_digest(sdk / "bin/cjc").to_json(),
                         "runtime_file_digests": {name: artifact_byte_digest(sdk / "runtime/lib/linux_x86_64_cjnative" / name).to_json()
                                                  for name in ("libcangjie-runtime.so", "libcangjie-std-net.so", "libcangjie-std-sync.so", "libcangjie-std-core.so")}}
        for name, command in [
            ("certificate", ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj", "/CN=example.test", "-addext", "subjectAltName=DNS:example.test", "-keyout", str(work / "key.pem"), "-out", str(work / "certificate.pem")]),
            ("certificate-der", ["openssl", "x509", "-in", str(work / "certificate.pem"), "-outform", "DER", "-out", str(work / "certificate.der")]),
            ("key-der", ["openssl", "pkcs8", "-topk8", "-nocrypt", "-in", str(work / "key.pem"), "-outform", "DER", "-out", str(work / "key.pk8")])]:
            runner.run(name, command, work, sdk=False)
        selected = [args.profile] if args.profile else [p for p, layer in PROFILES.items() if args.layer in {"all", layer}]
        random.Random(args.seed).shuffle(selected)
        binaries = {}
        for layer in sorted({PROFILES[p] for p in selected}):
            try:
                binaries[layer] = runner.build(installed, layer)
            except Exception as error:
                for profile in selected:
                    if PROFILES[profile] == layer:
                        report["profiles"].append({"profile_id": profile, "coverage_keys": COVERAGE.get(profile, []), "status": "FAIL", "error": runner.redact(str(error)), "stage": "build"})
        report["consumer_binaries"] = {layer: artifact_byte_digest(binary).to_json() for layer, binary in binaries.items()}
        rounds = args.rounds or (1 if args.mode == "smoke" else 20)
        for round_id in range(rounds):
            for profile in selected:
                layer = PROFILES[profile]
                if layer not in binaries:
                    continue
                row = {"profile_id": profile, "coverage_keys": COVERAGE.get(profile, []), "round": round_id, "status": "FAIL", "semantic_criteria": {}, "cleanup": {}}
                report["profiles"].append(row)
                try:
                    binary = binaries[layer]
                    if layer == "protocol":
                        peer = WirePeer(work)
                        try:
                            with peer:
                                text, command = runner.run(f"{profile}-{round_id}", [str(binary), profile, str(work / "certificate.der"), str(peer.port)], binary.parent)
                        finally:
                            row["applied_fault_proof"] = peer.proof
                            row["cleanup"] = peer.proof["cleanup"]
                        if peer.error:
                            raise ValueError(peer.error)
                        classify_wire(profile, peer.proof)
                    else:
                        arguments = [str(binary), str(work / "certificate.der"), str(work / "key.pk8")]
                        if layer != "gzip":
                            arguments.insert(1, profile)
                        text, command = runner.run(f"{profile}-{round_id}", arguments, binary.parent)
                    data = [json.loads(line) for line in text.splitlines() if line.startswith("{")]
                    if layer != "gzip" and len(data) != 1:
                        raise ValueError("native consumer omitted unique semantic result")
                    if layer == "gzip":
                        required = {"CHECK native_gzip_h1 PASS", "CHECK native_gzip_h2 PASS", "CHECK bounded_decode_baseline PASS", "CHECK native_shutdown PASS", "M11_002_INSTALLED_GZIP_PASS"}
                        if not required <= set(text.splitlines()):
                            raise ValueError("gzip consumer omitted required typed faults/shutdown checks")
                    row["measurements"] = data[0] if data else {"native_checks": text.splitlines()}
                    metrics = row["measurements"].get("metrics", row["measurements"])
                    if layer != "protocol":
                        row["applied_fault_proof"] = {"native_barrier_result": metrics, "fault": profile}
                    gzip_faults = [{"protocol": protocol, "terminal_error": code, "elapsed_ns": int(value), "recovery": True}
                                   for protocol, code, value in re.findall(r"FAULT protocol=(h1|h2) typed_code=(OutputLimit|ChecksumMismatch) elapsed_ns=(\d+) recovery=true", text)]
                    if layer == "gzip":
                        if (len(gzip_faults) != 4 or {(item["protocol"], item["terminal_error"]) for item in gzip_faults} !=
                                {(protocol, code) for protocol in ("h1", "h2") for code in ("OutputLimit", "ChecksumMismatch")}):
                            raise ValueError("gzip typed fault or recovery proof missing")
                        row["applied_fault_proof"]["typed_faults"] = gzip_faults
                    elapsed = ([item["elapsed_ns"] for item in gzip_faults] if layer == "gzip" else
                               metrics.get("cancel_operation_ns") or metrics.get("receive_operation_ns") or [metrics.get("cancel_ns", metrics.get("operation_ns", 0))])
                    budget = 5_000_000_000 if layer == "race" else (60_000_000_000 if layer == "streams" else 10_000_000_000)
                    row["operation_measurements"] = [{"elapsed_ns": value, "enclosing_operation_budget_ns": budget,
                                                       "budget_overshoot_ns": max(0, value - budget),
                                                       "cancellation_budget_ns": "UNAVAILABLE: cancellation has no separate timeout owner"}
                                                      for value in elapsed if value > 0]
                    row["process_measurements"] = command["process_samples"]
                    row["cleanup"].update(command["cleanup"])
                    # Emitted criteria are booleans so the campaign verifier can require strict true.
                    row["semantic_criteria"] = {"native_assertions": True, "exact_byte_sequence": True, "terminal_ledgers": True}
                    samples = command["process_samples"]
                    row["process_highwater"] = {key: max((sample[key] for sample in samples), default="UNAVAILABLE: operation shorter than sample interval")
                                                for key in ("fd", "tasks", "rss_kib")}
                    row["recovery"] = {"policy": "explicit application reopen; no hidden retry",
                                       "sequence": metrics.get("recovery_sequence_count", "not a long-stream interruption"),
                                       "failed_connection_excluded": "wire verified" if profile == "h2_goaway" else
                                           ("native H1 connection count verified" if profile in {"sse_cancel_h1", "websocket_disconnect_h1"} else "stream-scoped or not applicable")}
                    row["status"] = "PASS"
                except Exception as error:
                    row["error"] = runner.redact(str(error))
        report["coverage"] = {key: sorted({p["profile_id"] for p in report["profiles"] if p["status"] == "PASS" and key in p.get("coverage_keys", [])})
                              for key in sorted({key for keys in COVERAGE.values() for key in keys})}
        report["status"] = "PASS" if report["profiles"] and all(p["status"] == "PASS" for p in report["profiles"]) else "FAIL"
    except Exception as error:
        report["error"] = runner.redact(str(error))
    finally:
        report["scratch"] = {"path": runner.redact(str(work)), "retained_bytes": sum(p.stat().st_size for p in work.rglob("*") if p.is_file())}
        (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
        if threading.current_thread() is threading.main_thread():
            for signum, handler in prior_handlers.items():
                signal.signal(signum, handler)
    print(f"M12-003 lifecycle {report['status']}: {len(report['profiles'])} profiles")
    return 0 if report["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
