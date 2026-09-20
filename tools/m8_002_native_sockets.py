#!/usr/bin/env python3
"""Qualify the public Linux TCP/UDP consumer against independent Python peers."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import queue
import re
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time

import m7_027_linux_examples as examples

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from tools.evidence_digest import artifact_byte_digest, text_evidence_digest

SOURCE = ROOT / "examples/linux/m8_002/main.cj"
PAYLOAD = bytes(index % 251 for index in range(32 * 1024))


def artifact(path: Path) -> dict[str, object]:
    return {"path": str(path.relative_to(ROOT)), "digest": text_evidence_digest(path).to_json()}


def command(argv: list[str], cwd: Path, output: Path, name: str, timeout: int,
            records: list[dict[str, object]]) -> None:
    stdout = output / f"{name}.stdout.log"
    stderr = output / f"{name}.stderr.log"
    with stdout.open("w", encoding="utf-8") as out, stderr.open("w", encoding="utf-8") as err:
        result = subprocess.run(argv, cwd=cwd, stdout=out, stderr=err, timeout=timeout, check=False)
    records.append({"argv": argv, "exit_code": result.returncode,
                    "stdout": artifact(stdout), "stderr": artifact(stderr)})
    if result.returncode:
        raise RuntimeError(f"{name} exited {result.returncode}; see {stderr}")


def receive_exact(peer: socket.socket, size: int) -> bytes:
    data = bytearray()
    while len(data) < size:
        block = peer.recv(size - len(data))
        if not block:
            raise RuntimeError("Python peer received premature TCP EOF")
        data.extend(block)
    return bytes(data)


def socket_fds(pid: int) -> list[str]:
    result = []
    for entry in (Path("/proc") / str(pid) / "fd").iterdir():
        try:
            target = os.readlink(entry)
        except FileNotFoundError:
            continue
        if target.startswith("socket:["):
            result.append(entry.name)
    return sorted(result)


def trace_flags(path: Path) -> dict[str, int]:
    counts = {"tcp_created": 0, "udp_created": 0, "tcp_accepted": 0}
    for line in path.read_text(encoding="utf-8").splitlines():
        if not re.search(r"= \d+$", line):
            continue
        if "socket(" in line:
            if "SOCK_STREAM" in line:
                key = "tcp_created"
            elif "SOCK_DGRAM" in line:
                key = "udp_created"
            else:
                continue
        elif "accept4(" in line or " accept(" in line:
            key = "tcp_accepted"
        else:
            continue
        if "SOCK_CLOEXEC" not in line or "SOCK_NONBLOCK" not in line:
            raise RuntimeError(f"descriptor creation omitted required flags: {line}")
        counts[key] += 1
    if counts["tcp_created"] < 66 or counts["udp_created"] < 65 or counts["tcp_accepted"] < 1:
        raise RuntimeError(f"incomplete native descriptor trace: {counts}")
    return counts


def profile(binary: Path, output: Path, name: str) -> dict[str, object]:
    family = socket.AF_INET6 if name == "ipv6" else socket.AF_INET
    host = "::1" if name == "ipv6" else "127.0.0.1"
    trace = output / f"{name}.syscalls.log"
    stdout = output / f"{name}.stdout.log"
    stderr = output / f"{name}.stderr.log"
    peer_result: queue.Queue[object] = queue.Queue(maxsize=1)
    lines: queue.Queue[str | None] = queue.Queue(maxsize=256)
    deadline = time.monotonic() + 60
    process: subprocess.Popen[str] | None = None
    reader: threading.Thread | None = None
    worker: threading.Thread | None = None
    checkpoints: dict[str, list[str]] = {}

    with socket.socket(family, socket.SOCK_STREAM) as server, \
            socket.socket(family, socket.SOCK_DGRAM) as udp, \
            socket.socket(family, socket.SOCK_DGRAM) as other:
        for peer in (server, udp, other):
            peer.settimeout(10)
            peer.bind((host, 0))
        server.listen(1)

        def serve() -> None:
            try:
                connection, _ = server.accept()
                with connection:
                    connection.settimeout(10)
                    if receive_exact(connection, len(PAYLOAD)) != PAYLOAD:
                        raise RuntimeError("outgoing TCP payload differed")
                    for offset in range(0, len(PAYLOAD), 1021):
                        connection.sendall(PAYLOAD[offset:offset + 1021])
                    connection.shutdown(socket.SHUT_WR)
                    if receive_exact(connection, 5) != b"after":
                        raise RuntimeError("post-EOF TCP write differed")
                peer_result.put(None)
            except Exception as error:
                peer_result.put(error)

        def read_output(stream: object) -> None:
            with stdout.open("w", encoding="utf-8") as log:
                for line in stream:
                    log.write(line)
                    log.flush()
                    try:
                        lines.put(line.rstrip("\r\n"), timeout=1)
                    except queue.Full:
                        return
            lines.put(None, timeout=1)

        def next_line() -> str:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise RuntimeError("native consumer exceeded its 60-second protocol budget")
            value = lines.get(timeout=remaining)
            if value is None:
                raise RuntimeError("native consumer exited before completing its protocol")
            return value

        env = os.environ.copy()
        env["WIRESTACK_TCP_PEER_PORT"] = str(server.getsockname()[1])
        env["WIRESTACK_UDP_PEER_PORT"] = str(udp.getsockname()[1])
        env["WIRESTACK_NATIVE_FAMILY"] = name
        worker = threading.Thread(target=serve, daemon=True)
        worker.start()
        try:
            with stderr.open("w", encoding="utf-8") as err:
                process = subprocess.Popen(
                    ["strace", "-f", "-e", "trace=socket,accept,accept4,close,sendto,recvfrom",
                     "-o", str(trace), str(binary)], cwd=binary.parent, env=env,
                    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=err,
                    text=True, bufsize=1, start_new_session=True,
                )
                assert process.stdout is not None and process.stdin is not None
                reader = threading.Thread(target=read_output, args=(process.stdout,), daemon=True)
                reader.start()
                ready = next_line().split()
                if len(ready) != 3 or ready[0] != "READY":
                    raise RuntimeError(f"unexpected native readiness: {ready}")
                tcp_port, udp_port = map(int, ready[1:])
                children = (Path("/proc") / str(process.pid) / "task" / str(process.pid) / "children").read_text().split()
                if len(children) != 1:
                    raise RuntimeError(f"cannot identify the traced consumer: {children}")
                consumer_pid = int(children[0])
                with socket.socket(family, socket.SOCK_STREAM) as client:
                    client.settimeout(10)
                    client.connect((host, tcp_port))
                    for offset in range(0, len(PAYLOAD), 1021):
                        client.sendall(PAYLOAD[offset:offset + 1021])
                    if receive_exact(client, len(PAYLOAD)) != PAYLOAD or client.recv(1) != b"":
                        raise RuntimeError("accepted TCP stream echo or graceful EOF differed")
                if next_line() != "TCP_NATIVE_PASS":
                    raise RuntimeError("native TCP assertions did not complete")
                udp.sendto(b"", (host, udp_port))
                udp.sendto(bytes(range(1, 9)), (host, udp_port))
                udp.sendto(bytes(range(9, 13)), (host, udp_port))
                acknowledgement, _ = udp.recvfrom(8)
                if acknowledgement != b"AB" or next_line() != "UDP_CONNECTED":
                    raise RuntimeError("connected UDP send or empty-send recovery differed")
                other.sendto(b"\xff", (host, udp_port))
                udp.sendto(b"D", (host, udp_port))
                maximum = bytes(index % 251 for index in range(65507))
                packet, source = udp.recvfrom(65508)
                if packet != maximum or source[1] != udp_port:
                    raise RuntimeError("maximum UDP send did not preserve one complete packet")
                udp.sendto(maximum, source)
                if next_line() != "UDP_NATIVE_PASS":
                    raise RuntimeError("native UDP assertions did not complete")
                if next_line() != "CHECKPOINT baseline":
                    raise RuntimeError("missing baseline resource checkpoint")
                checkpoints["baseline"] = socket_fds(consumer_pid)
                trace_offset = trace.stat().st_size
                process.stdin.write("continue\n")
                process.stdin.flush()
                for mode in ("cancel", "close"):
                    waiting = next_line().split()
                    if len(waiting) != 3 or waiting[:2] != ["WAIT_READY", mode]:
                        raise RuntimeError(f"missing active UDP wait: {waiting}")
                    descriptors = socket_fds(consumer_pid)
                    if len(descriptors) != 1:
                        raise RuntimeError(f"expected one waiting UDP socket: {descriptors}")
                    wait_deadline = time.monotonic() + 2
                    while True:
                        with trace.open("r", encoding="utf-8") as syscalls:
                            syscalls.seek(trace_offset)
                            observed = syscalls.read()
                        if any(f"recvfrom({descriptors[0]}," in line and "EAGAIN" in line
                               for line in observed.splitlines()):
                            break
                        if time.monotonic() >= wait_deadline:
                            raise RuntimeError(f"{mode} did not reach a native receive wait")
                        time.sleep(0.005)
                    process.stdin.write("stop\n")
                    process.stdin.flush()
                    if mode == "cancel":
                        packet, source = udp.recvfrom(8)
                        if packet != b"live" or source[1] != int(waiting[2]):
                            raise RuntimeError("opposite-direction UDP send did not reach its peer")
                    if next_line() != f"WAIT_PASS {mode}":
                        raise RuntimeError(f"active UDP {mode} did not finish")
                    trace_offset = trace.stat().st_size
                    process.stdin.write("next\n")
                    process.stdin.flush()
                if next_line() != "CHECKPOINT after":
                    raise RuntimeError("missing final resource checkpoint")
                checkpoints["after"] = socket_fds(consumer_pid)
                process.stdin.write("continue\n")
                process.stdin.flush()
                if next_line() != "NATIVE_NETWORK_PASS":
                    raise RuntimeError("native consumer did not complete")
                process.stdin.close()
                if process.wait(timeout=max(1, deadline - time.monotonic())) != 0:
                    raise RuntimeError("native consumer failed")
                result = peer_result.get(timeout=10)
                if result is not None:
                    raise RuntimeError(f"independent TCP peer failed: {result}")
        finally:
            if process is not None and process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=2)
            if reader is not None:
                reader.join(timeout=2)
            if process is not None and process.stdout is not None:
                process.stdout.close()
            if process is not None and process.stdin is not None and not process.stdin.closed:
                process.stdin.close()
            if worker is not None:
                worker.join(timeout=11)
    if checkpoints != {"baseline": [], "after": []}:
        raise RuntimeError(f"native sockets leaked across 64 create/close cycles: {checkpoints}")
    return {"status": "PASS", "family": name, "resource_cycles": 64,
            "socket_fds": checkpoints, "descriptor_creation": trace_flags(trace),
            "empty_receive": "PASS", "empty_send": "UNSUPPORTED_BACKEND",
            "empty_send_rejection_and_reuse": "PASS", "connected_peer_filter": "PASS",
            "active_receive_cancellation": "PASS", "active_receive_graceful_close": "PASS",
            "overlapping_receive_and_connect_rejection": "PASS",
            "opposite_direction_send_during_receive": "PASS",
            "stdout": artifact(stdout), "stderr": artifact(stderr), "syscalls": artifact(trace)}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", type=Path, default=ROOT / "docs/evidence/M8-002/native-sockets.json")
    args = parser.parse_args()
    report_path = args.report.resolve()
    output = report_path.parent / "native-sockets"
    output.mkdir(parents=True, exist_ok=True)
    report: dict[str, object] = {"schema_version": 1, "source_task": "M8-002", "status": "FAIL",
                                "commands": [], "profiles": []}
    try:
        examples.require_platform()
        command(["cjc", "-v"], ROOT, output, "toolchain", 10, report["commands"])
        with tempfile.TemporaryDirectory(prefix="wirestack-m8-002-consumer-") as temporary:
            consumer = Path(temporary)
            (consumer / "src").mkdir()
            manifest = examples.consumer_manifest().replace("wirestack_m7_027_examples", "wirestack_m8_002_native")
            manifest = manifest.replace("M7-027 clean migration example consumer", "M8-002 native socket consumer")
            (consumer / "cjpm.toml").write_text(manifest, encoding="utf-8")
            (consumer / "src/main.cj").write_text(SOURCE.read_text(encoding="utf-8"), encoding="utf-8")
            command(["cjpm", "build"], consumer, output, "consumer-build", 600, report["commands"])
            binary = consumer / "target/release/bin/main"
            report["binary_digest"] = artifact_byte_digest(binary).to_json()
            for family in ("ipv4", "ipv6"):
                report["profiles"].append(profile(binary, output, family))
        report["source_digest"] = text_evidence_digest(SOURCE).to_json()
        report["status"] = "PASS"
    except (OSError, RuntimeError, ValueError, subprocess.TimeoutExpired, queue.Empty, AssertionError) as error:
        report["error"] = f"{type(error).__name__}: {error}"
    examples.atomic_json(report_path, report)
    print(json.dumps(report, sort_keys=True))
    return 0 if report["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
