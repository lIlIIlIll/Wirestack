#!/usr/bin/env python3
"""Qualify public Unix sockets against independent Linux AF_UNIX peers."""
from __future__ import annotations

import argparse
import errno
import json
import os
from pathlib import Path
import queue
import re
import select
import signal
import socket
import subprocess
import tempfile
import threading
import time

import m8_002_native_sockets as support

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "examples/linux/m8_003/main.cj"
PAYLOAD = bytes(index % 251 for index in range(32768))


def descriptor_flags(trace: Path) -> dict[str, int]:
    counts = {"stream_created": 0, "datagram_created": 0, "stream_accepted": 0}
    for line in trace.read_text(encoding="utf-8").splitlines():
        if not re.search(r"= \d+$", line):
            continue
        if "socket(" in line:
            if "AF_UNIX" not in line:
                raise RuntimeError(f"unexpected non-Unix socket: {line}")
            if "SOCK_STREAM" in line:
                key = "stream_created"
            elif "SOCK_DGRAM" in line:
                key = "datagram_created"
            else:
                raise RuntimeError(f"unexpected raw or unsupported socket: {line}")
        elif "accept4(" in line or " accept(" in line:
            key = "stream_accepted"
        else:
            continue
        if "SOCK_CLOEXEC" not in line or "SOCK_NONBLOCK" not in line:
            raise RuntimeError(f"descriptor omitted atomic creation flags: {line}")
        counts[key] += 1
    if counts["stream_created"] < 69 or counts["datagram_created"] < 67 or counts["stream_accepted"] < 4:
        raise RuntimeError(f"incomplete descriptor evidence: {counts}")
    return counts


def profile(binary: Path, output: Path, mode: str) -> dict[str, object]:
    trace = output / f"{mode}.syscalls.log"
    stdout = output / f"{mode}.stdout.log"
    stderr = output / f"{mode}.stderr.log"
    lines: queue.Queue[str | None] = queue.Queue(maxsize=256)
    peer_result: queue.Queue[Exception | None] = queue.Queue(maxsize=1)
    deadline = time.monotonic() + 90
    process: subprocess.Popen[str] | None = None
    reader: threading.Thread | None = None
    worker: threading.Thread | None = None
    checkpoints: dict[str, list[str]] = {}
    wait_observations: list[dict[str, object]] = []
    peer_filter = ""

    def next_line() -> str:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise RuntimeError("Unix consumer exceeded its 90-second protocol budget")
        line = lines.get(timeout=remaining)
        if line is None:
            raise RuntimeError("Unix consumer exited before protocol completion")
        return line

    def expect(expected: str) -> None:
        actual = next_line()
        if actual != expected:
            raise RuntimeError(f"expected {expected!r}, received {actual!r}")

    def send(line: str) -> None:
        assert process is not None and process.stdin is not None
        process.stdin.write(line + "\n")
        process.stdin.flush()

    def admitted(offset: int, operation: str) -> None:
        end = min(deadline, time.monotonic() + 5)
        while time.monotonic() < end:
            text = trace.read_text(encoding="utf-8")[offset:]
            if any(operation + "(" in line and "EAGAIN" in line for line in text.splitlines()):
                wait_observations.append({"operation": operation, "trace_offset": offset,
                                          "native_eagain_before_action": True})
                return
            if process is not None and process.poll() is not None:
                raise RuntimeError("consumer exited before native wait admission")
            time.sleep(0.01)
        raise RuntimeError(f"no native {operation} EAGAIN before control action")

    def read_output(stream: object) -> None:
        with stdout.open("w", encoding="utf-8") as log:
            for line in stream:
                log.write(line)
                log.flush()
                lines.put(line.rstrip("\r\n"), timeout=1)
        lines.put(None, timeout=1)

    with tempfile.TemporaryDirectory(prefix="wirestack-m8-003-peer-") as namespace:
        def address(label: str) -> str | bytes:
            if mode == "abstract":
                name = (namespace + "-" + label).encode() + b"\0tail\xc3\xa9"
                if len(name) > 107:
                    raise RuntimeError("native fixture name exceeded the endpoint bound")
                return b"\0" + name.ljust(107, b"z")
            return str(Path(namespace) / label)

        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server, \
                socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as datagram, \
                socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as other, \
                socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as arbitrary:
            for peer, label in ((server, "peer-stream"), (datagram, "peer-datagram"), (other, "other")):
                peer.settimeout(10)
                peer.bind(address(label))
            arbitrary.settimeout(10)
            arbitrary.bind(b"\0" + (namespace + "-arbitrary-").encode() + b"\xff")
            server.listen(1)

            def serve() -> None:
                try:
                    connection, _ = server.accept()
                    with connection:
                        connection.settimeout(10)
                        if support.receive_exact(connection, len(PAYLOAD)) != PAYLOAD:
                            raise RuntimeError("outgoing Unix stream bytes differed")
                        for offset in range(0, len(PAYLOAD), 1021):
                            connection.sendall(PAYLOAD[offset:offset + 1021])
                        connection.shutdown(socket.SHUT_WR)
                        if support.receive_exact(connection, 5) != b"after":
                            raise RuntimeError("post-EOF Unix write differed")
                    peer_result.put(None)
                except Exception as error:
                    peer_result.put(error)

            worker = threading.Thread(target=serve, daemon=True)
            worker.start()
            env = {**os.environ, "WIRESTACK_UNIX_PROFILE": mode, "WIRESTACK_UNIX_PREFIX": namespace}
            try:
                with stderr.open("w", encoding="utf-8") as err:
                    process = subprocess.Popen(
                        ["strace", "-f", "-e", "trace=socket,bind,listen,connect,accept,accept4,close,sendto,recvfrom",
                         "-o", str(trace), str(binary)], cwd=binary.parent, env=env,
                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=err,
                        text=True, bufsize=1, start_new_session=True,
                    )
                    assert process.stdout is not None
                    reader = threading.Thread(target=read_output, args=(process.stdout,), daemon=True)
                    reader.start()
                    expect("READY")
                    children = (Path("/proc") / str(process.pid) / "task" / str(process.pid) / "children").read_text().split()
                    if len(children) != 1:
                        raise RuntimeError(f"cannot identify traced Unix consumer: {children}")
                    consumer_pid = int(children[0])
                    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                        client.settimeout(10)
                        client.connect(address("listener"))
                        for offset in range(0, len(PAYLOAD), 1021):
                            client.sendall(PAYLOAD[offset:offset + 1021])
                        if support.receive_exact(client, len(PAYLOAD)) != PAYLOAD or client.recv(1) != b"":
                            raise RuntimeError("accepted Unix echo or graceful EOF differed")
                    expect("STREAM_PASS")
                    expect("WRITE_TIMEOUT_LISTEN")
                    trace_offset = trace.stat().st_size
                    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                        client.settimeout(10)
                        client.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
                        client.connect(address("write-timeout"))
                        admitted(trace_offset, "sendto")
                        expect("WRITE_TIMEOUT_PASS")
                        send("next")
                    for packet in (b"", bytes(range(1, 9)), bytes(range(9, 13))):
                        datagram.sendto(packet, address("datagram"))
                    arbitrary.sendto(b"raw", address("datagram"))
                    acknowledgement, source = datagram.recvfrom(8)
                    if acknowledgement != b"AB" or source != address("datagram"):
                        raise RuntimeError("connected Unix send/source or empty-send recovery differed")
                    expect("DATAGRAM_CONNECTED")
                    try:
                        other.sendto(b"wrong", address("datagram"))
                        peer_filter = "unselected packet not delivered"
                    except OSError as error:
                        if error.errno not in (errno.EPERM, errno.ECONNREFUSED):
                            raise
                        peer_filter = f"kernel rejected unselected peer with errno {error.errno}"
                    datagram.sendto(b"D", address("datagram"))
                    maximum, source = datagram.recvfrom(65508)
                    expected = bytes(index % 251 for index in range(65507))
                    if maximum != expected or source != address("datagram"):
                        raise RuntimeError("maximum Unix send bytes/source differed")
                    datagram.sendto(maximum, source)
                    expect("DATAGRAM_PASS")
                    if mode == "pathname":
                        expect("IDENTITY_BIND")
                        with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as selected_peer, \
                             socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as replacement_peer:
                            selected_peer.settimeout(10)
                            replacement_peer.settimeout(10)
                            selected_peer.bind(address("identity-peer"))
                            send("connect")
                            expect("IDENTITY_SELECTED")
                            os.unlink(address("identity-peer"))
                            replacement_peer.bind(address("identity-peer"))
                            send("send")
                            expect("IDENTITY_SEND_BLOCKED")
                            ready, _, _ = select.select([selected_peer, replacement_peer], [], [], 0)
                            if ready:
                                raise RuntimeError("unsupported connected send delivered a packet")
                            try:
                                replacement_peer.sendto(b"wrong", address("connected-identity"))
                            except OSError as error:
                                if error.errno not in (errno.EPERM, errno.ECONNREFUSED):
                                    raise
                            selected_peer.sendto(b"right", address("connected-identity"))
                            packet, source = replacement_peer.recvfrom(16)
                            if packet != b"override" or source != address("connected-identity"):
                                raise RuntimeError("explicit sendTo did not select the replacement pathname")
                            expect("IDENTITY_PASS")
                            send("next")
                    expect("CHECKPOINT baseline")
                    checkpoints["baseline"] = support.socket_fds(consumer_pid)
                    trace_offset = trace.stat().st_size
                    send("continue")
                    expect("WAIT_ACCEPT")
                    admitted(trace_offset, "accept4")
                    send("stop")
                    expect("ACCEPT_REUSABLE")
                    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                        client.settimeout(10)
                        client.connect(address("wait-listener"))
                        client.sendall(b"ok")
                    expect("ACCEPT_PASS")
                    trace_offset = trace.stat().st_size
                    send("next")
                    for operation in ("cancel", "close"):
                        expect(f"WAIT_STREAM_LISTEN {operation}")
                        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                            client.settimeout(10)
                            client.connect(address("wait-stream-" + operation))
                            expect(f"WAIT_STREAM {operation}")
                            admitted(trace_offset, "recvfrom")
                            send("stop")
                            if operation == "cancel" and support.receive_exact(client, 4) != b"live":
                                raise RuntimeError("opposite-direction Unix stream write differed")
                            expect(f"STREAM_WAIT_PASS {operation}")
                        trace_offset = trace.stat().st_size
                        send("next")
                    for operation in ("cancel", "close"):
                        expect(f"WAIT_DATAGRAM {operation}")
                        admitted(trace_offset, "recvfrom")
                        send("stop")
                        if operation == "cancel":
                            packet, source = datagram.recvfrom(8)
                            if packet != b"live" or source != address("wait-cancel"):
                                raise RuntimeError("opposite-direction Unix send did not reach its peer")
                        expect(f"DATAGRAM_WAIT_PASS {operation}")
                        trace_offset = trace.stat().st_size
                        send("next")
                    expect("CHECKPOINT after")
                    checkpoints["after"] = support.socket_fds(consumer_pid)
                    send("continue")
                    expect("NATIVE_UNIX_PASS")
                    assert process.stdin is not None
                    process.stdin.close()
                    if process.wait(timeout=max(1, deadline - time.monotonic())) != 0:
                        raise RuntimeError("Unix consumer failed")
                    peer_error = peer_result.get(timeout=10)
                    if peer_error is not None:
                        raise RuntimeError(f"independent Unix stream peer failed: {peer_error}")
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
                if process is not None:
                    if process.stdout is not None:
                        process.stdout.close()
                    if process.stdin is not None and not process.stdin.closed:
                        process.stdin.close()
                if worker is not None:
                    worker.join(timeout=11)
    if checkpoints != {"baseline": [], "after": []}:
        raise RuntimeError(f"Unix socket descriptors leaked: {checkpoints}")
    return {"status": "PASS", "profile": mode, "resource_cycles": 64,
            "socket_fds": checkpoints, "descriptor_creation": descriptor_flags(trace),
            "native_wait_admission": wait_observations, "connected_peer_filter": peer_filter,
            "empty_receive": "PASS", "empty_send": "UNSUPPORTED_BACKEND",
            "backpressured_write_timeout": "PASS_NON_REPLAYABLE",
            "connected_datagram_send": "BLOCKED_SDK_PEER_IDENTITY",
            "connected_send_guard": "PASS_FAIL_CLOSED",
            "pathname_replacement_guard": "PASS" if mode == "pathname" else "NOT_APPLICABLE",
            "arbitrary_non_utf8_outgoing_names": "BLOCKED_SDK",
            "short_abstract_outgoing_names": "BLOCKED_SDK_IDENTITY_PADDING",
            "incoming_non_utf8_sender": "PASS", "unnamed_datagram_sender": "BLOCKED_SDK",
            "raw_native_io": "BLOCKED_NO_ADAPTER",
            "stdout": support.artifact(stdout), "stderr": support.artifact(stderr),
            "syscalls": support.artifact(trace)}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", type=Path, default=ROOT / "docs/evidence/M8-003/native-sockets.json")
    args = parser.parse_args()
    report_path = args.report.resolve()
    output = report_path.parent / "native-sockets"
    output.mkdir(parents=True, exist_ok=True)
    report: dict[str, object] = {"schema_version": 1, "source_task": "M8-003", "status": "FAIL",
                                "commands": [], "profiles": []}
    try:
        support.examples.require_platform()
        support.command(["cjc", "-v"], ROOT, output, "toolchain", 10, report["commands"])
        with tempfile.TemporaryDirectory(prefix="wirestack-m8-003-consumer-") as temporary:
            consumer = Path(temporary)
            (consumer / "src").mkdir()
            manifest = support.examples.consumer_manifest().replace("wirestack_m7_027_examples", "wirestack_m8_003_native")
            manifest = manifest.replace("M7-027 clean migration example consumer", "M8-003 native Unix socket consumer")
            (consumer / "cjpm.toml").write_text(manifest, encoding="utf-8")
            (consumer / "src/main.cj").write_text(SOURCE.read_text(encoding="utf-8"), encoding="utf-8")
            support.command(["cjpm", "build"], consumer, output, "consumer-build", 600, report["commands"])
            binary = consumer / "target/release/bin/main"
            report["binary_digest"] = support.artifact_byte_digest(binary).to_json()
            for mode in ("pathname", "abstract"):
                report["profiles"].append(profile(binary, output, mode))
        report["source_digest"] = support.text_evidence_digest(SOURCE).to_json()
        report["status"] = "PASS"
    except (OSError, RuntimeError, ValueError, subprocess.TimeoutExpired, queue.Empty, AssertionError) as error:
        report["error"] = f"{type(error).__name__}: {error}"
    support.examples.atomic_json(report_path, report)
    print(json.dumps(report, sort_keys=True))
    return 0 if report["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
