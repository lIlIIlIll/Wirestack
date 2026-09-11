#!/usr/bin/env python3
"""Qualify public DNS APIs against bounded local UDP, TCP, and service peers."""
from __future__ import annotations

import argparse
from contextlib import ExitStack
import errno
import json
import os
from pathlib import Path
import platform
import queue
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
from typing import Callable, Sequence

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from tools.evidence_digest import artifact_byte_digest, text_evidence_digest
from tools import m7_027_linux_examples as examples

TASK_ID = "M8-004"
SOURCE = ROOT / "examples/linux/m8_004/native_dns.cj"
DEFAULT_REPORT = ROOT / "docs/evidence/M8-004/native-dns.json"
DEFAULT_OUTPUT = ROOT / "docs/evidence/M8-004/native-dns"
CASE_TIMEOUT_SECONDS = 30
SOCKET_TIMEOUT_SECONDS = 5
CNAME_DELAY_SECONDS = 1.25


def bounded_path(path: Path, label: str) -> Path:
    resolved = path.resolve()
    try:
        relative = resolved.relative_to(ROOT)
    except ValueError as error:
        raise ValueError(f"{label} must remain under the repository root") from error
    if relative.parts[:2] == ("docs", "evidence") and (
        len(relative.parts) < 3 or relative.parts[2] != TASK_ID
    ):
        raise ValueError(f"{label} must not rewrite another task's evidence")
    if resolved in {SOURCE.resolve(), Path(__file__).resolve()}:
        raise ValueError(f"{label} must not overwrite qualification sources")
    return resolved


def text_artifact(path: Path) -> dict[str, object]:
    return {
        "path": path.resolve().relative_to(ROOT).as_posix(),
        "digest": text_evidence_digest(path).to_json(),
    }


def command(
    argv: Sequence[str],
    cwd: Path,
    output: Path,
    name: str,
    timeout: int,
    records: list[dict[str, object]],
) -> None:
    stdout = output / f"{name}.stdout.log"
    stderr = output / f"{name}.stderr.log"
    timed_out = False
    return_code: int | None = None
    try:
        with stdout.open("w", encoding="utf-8") as out, stderr.open("w", encoding="utf-8") as err:
            try:
                completed = subprocess.run(
                    list(argv), cwd=cwd, stdout=out, stderr=err, timeout=timeout, check=False
                )
                return_code = completed.returncode
            except subprocess.TimeoutExpired:
                timed_out = True
    finally:
        records.append(
            {
                "id": name,
                "argv": list(argv),
                "cwd": str(cwd.resolve()),
                "timeout_seconds": timeout,
                "timed_out": timed_out,
                "exit_code": return_code,
                "stdout": text_artifact(stdout),
                "stderr": text_artifact(stderr),
            }
        )
    if timed_out:
        raise RuntimeError(f"{name} exceeded its {timeout}-second command budget")
    if return_code != 0:
        raise RuntimeError(f"{name} exited {return_code}; see {stderr}")


def receive_exact(peer: socket.socket, size: int) -> bytes:
    data = bytearray()
    while len(data) < size:
        block = peer.recv(size - len(data))
        if not block:
            raise RuntimeError("DNS TCP peer received premature EOF")
        data.extend(block)
    return bytes(data)

def socket_fds(pid: int) -> list[str]:
    descriptors = []
    for entry in (Path("/proc") / str(pid) / "fd").iterdir():
        try:
            target = os.readlink(entry)
        except FileNotFoundError:
            continue
        if target.startswith("socket:["):
            descriptors.append(entry.name)
    return sorted(descriptors)


def encode_name(name: str) -> bytes:
    canonical = name.rstrip(".").lower()
    if not canonical:
        return b"\0"
    output = bytearray()
    for label in canonical.split("."):
        encoded = label.encode("ascii")
        if not encoded or len(encoded) > 63:
            raise ValueError(f"invalid fixture DNS label: {label!r}")
        output.append(len(encoded))
        output.extend(encoded)
    output.append(0)
    return bytes(output)


def decode_name(message: bytes, offset: int) -> tuple[str, int]:
    labels: list[str] = []
    while True:
        if offset >= len(message):
            raise RuntimeError("DNS query name is truncated")
        length = message[offset]
        offset += 1
        if length == 0:
            return ".".join(labels), offset
        if length & 0xC0:
            raise RuntimeError("fixture received a compressed DNS question")
        if length > 63 or offset + length > len(message):
            raise RuntimeError("fixture received an invalid DNS question label")
        labels.append(message[offset : offset + length].decode("ascii").lower())
        offset += length


def parse_query(message: bytes) -> dict[str, object]:
    if len(message) < 17:
        raise RuntimeError("fixture received a short DNS query")
    transaction_id, flags, questions, answers, authority, additional = struct.unpack(
        "!HHHHHH", message[:12]
    )
    if questions != 1 or answers or authority or additional or flags & 0x8000:
        raise RuntimeError("fixture received an unexpected DNS query header")
    name, offset = decode_name(message, 12)
    if offset + 4 != len(message):
        raise RuntimeError("fixture received trailing or missing DNS question bytes")
    record_type, record_class = struct.unpack("!HH", message[offset : offset + 4])
    return {
        "id": transaction_id,
        "name": name,
        "type": record_type,
        "class": record_class,
        "question_end": offset + 4,
    }


def rr(owner: str | None, record_type: int, ttl: int, data: bytes) -> bytes:
    owner_wire = b"\xC0\x0C" if owner is None else encode_name(owner)
    return owner_wire + struct.pack("!HHIH", record_type, 1, ttl, len(data)) + data


def cname(owner: str | None, target: str, ttl: int) -> bytes:
    return rr(owner, 5, ttl, encode_name(target))


def soa(owner: str, ttl: int = 30, minimum: int = 30) -> bytes:
    data = encode_name("ns.native.test") + encode_name("hostmaster.native.test")
    data += struct.pack("!IIIII", 1, 2, 3, 4, minimum)
    return rr(owner, 6, ttl, data)


def response(
    query: bytes,
    *,
    flags: int = 0x8180,
    answers: Sequence[bytes] = (),
    authority: Sequence[bytes] = (),
    additional: Sequence[bytes] = (),
    transaction_id: int | None = None,
    question: bytes | None = None,
) -> bytes:
    parsed = parse_query(query)
    identity = int(parsed["id"]) if transaction_id is None else transaction_id
    question_wire = query[12 : int(parsed["question_end"])] if question is None else question
    return (
        struct.pack("!HHHHHH", identity, flags, 1, len(answers), len(authority), len(additional))
        + question_wire
        + b"".join(answers)
        + b"".join(authority)
        + b"".join(additional)
    )


class DnsPeers:
    def __init__(self) -> None:
        self.started_ns = time.monotonic_ns()
        for attempt in range(16):
            with ExitStack() as owned:
                self.tcp = owned.enter_context(socket.socket(socket.AF_INET, socket.SOCK_STREAM))
                self.tcp.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                self.tcp.settimeout(SOCKET_TIMEOUT_SECONDS)
                self.tcp.bind(("127.0.0.1", 0))
                self.port = int(self.tcp.getsockname()[1])
                self.udp = owned.enter_context(socket.socket(socket.AF_INET, socket.SOCK_DGRAM))
                self.udp.settimeout(SOCKET_TIMEOUT_SECONDS)
                try:
                    self.udp.bind(("127.0.0.1", self.port))
                except OSError as error:
                    if error.errno == errno.EADDRINUSE and attempt < 15:
                        continue
                    raise
                self.tcp.listen(8)
                self.rogue = owned.enter_context(socket.socket(socket.AF_INET, socket.SOCK_DGRAM))
                self.rogue.settimeout(SOCKET_TIMEOUT_SECONDS)
                self.rogue.bind(("127.0.0.1", 0))
                owned.pop_all()
                break
        self.queries: list[dict[str, object]] = []
        self.udp_responses = 0
        self.tcp_connections = 0

    def close(self) -> None:
        self.rogue.close()
        self.tcp.close()
        self.udp.close()

    def __enter__(self) -> DnsPeers:
        return self

    def __exit__(self, _type: object, _value: object, _traceback: object) -> None:
        self.close()

    def observe(self, wire: bytes, transport: str, source: tuple[str, int]) -> dict[str, object]:
        parsed = parse_query(wire)
        observed = {
            "transport": transport,
            "id": parsed["id"],
            "name": parsed["name"],
            "type": parsed["type"],
            "class": parsed["class"],
            "source_address": source[0],
            "source_port": source[1],
            "at_monotonic_ns_from_case_start": time.monotonic_ns() - self.started_ns,
        }
        self.queries.append(observed)
        return parsed

    def receive_udp(self, name: str, record_type: int) -> tuple[bytes, tuple[str, int]]:
        wire, source = self.udp.recvfrom(65535)
        parsed = self.observe(wire, "UDP", source)
        if parsed["name"] != name or parsed["type"] != record_type or parsed["class"] != 1:
            raise RuntimeError(
                f"expected UDP {name}/{record_type}/IN, got "
                f"{parsed['name']}/{parsed['type']}/{parsed['class']}"
            )
        return wire, source

    def send(self, wire: bytes, destination: tuple[str, int], *, rogue: bool = False) -> None:
        peer = self.rogue if rogue else self.udp
        if peer.sendto(wire, destination) != len(wire):
            raise RuntimeError("DNS UDP peer sent a partial datagram")
        self.udp_responses += 1

    def accept_tcp(self, expected_query: bytes, name: str, record_type: int) -> socket.socket:
        connection, source = self.tcp.accept()
        connection.settimeout(SOCKET_TIMEOUT_SECONDS)
        self.tcp_connections += 1
        length = struct.unpack("!H", receive_exact(connection, 2))[0]
        wire = receive_exact(connection, length)
        parsed = self.observe(wire, "TCP", source)
        if wire != expected_query:
            raise RuntimeError("DNS TCP fallback did not preserve the exact UDP query")
        if parsed["name"] != name or parsed["type"] != record_type:
            raise RuntimeError("DNS TCP fallback question identity changed")
        return connection

    def summary(self) -> dict[str, object]:
        return {
            "queries": self.queries,
            "query_count": len(self.queries),
            "udp_response_datagrams": self.udp_responses,
            "tcp_connections": self.tcp_connections,
        }


class ConsumerProcess:
    def __init__(
        self,
        binary: Path,
        mode: str,
        env: dict[str, str],
        output: Path,
        commands: list[dict[str, object]],
    ) -> None:
        self.mode = mode
        self.timeout = CASE_TIMEOUT_SECONDS
        self.deadline = time.monotonic() + self.timeout
        self.stdout_path = output / f"{mode}.stdout.log"
        self.stderr_path = output / f"{mode}.stderr.log"
        self.lines: queue.Queue[str | None] = queue.Queue(maxsize=256)
        self.stderr_stream = self.stderr_path.open("w", encoding="utf-8")
        self.argv = [str(binary), mode]
        self.cwd = binary.parent
        self.selected_environment = {
            key: value for key, value in env.items() if key.startswith("WIRESTACK_")
        }
        self.process = subprocess.Popen(
            self.argv,
            cwd=self.cwd,
            env={**os.environ, **env},
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=self.stderr_stream,
            text=True,
            bufsize=1,
            start_new_session=True,
        )
        assert self.process.stdout is not None
        self.reader = threading.Thread(target=self._read_output, args=(self.process.stdout,), daemon=True)
        self.reader.start()
        self.commands = commands
        self.recorded = False

    def _read_output(self, stream: object) -> None:
        with self.stdout_path.open("w", encoding="utf-8") as log:
            for line in stream:
                log.write(line)
                log.flush()
                try:
                    self.lines.put(line.rstrip("\r\n"), timeout=1)
                except queue.Full:
                    return
        try:
            self.lines.put(None, timeout=1)
        except queue.Full:
            pass

    def expect(self, expected: str) -> None:
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise RuntimeError(f"{self.mode} exceeded its {self.timeout}-second process budget")
        actual = self.lines.get(timeout=remaining)
        if actual is None:
            raise RuntimeError(f"{self.mode} exited before emitting {expected!r}")
        if actual != expected:
            raise RuntimeError(f"{self.mode} expected {expected!r}, received {actual!r}")

    def send(self, line: str) -> None:
        if self.process.stdin is None:
            raise RuntimeError(f"{self.mode} has no protocol input")
        self.process.stdin.write(line + "\n")
        self.process.stdin.flush()

    def finish(self, marker: str) -> None:
        self.expect(marker)
        if self.process.stdin is not None and not self.process.stdin.closed:
            self.process.stdin.close()
        remaining = max(0.1, self.deadline - time.monotonic())
        if self.process.wait(timeout=remaining) != 0:
            raise RuntimeError(f"{self.mode} consumer exited {self.process.returncode}")

    def close(self) -> None:
        if self.process.poll() is None:
            os.killpg(self.process.pid, signal.SIGTERM)
            try:
                self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                os.killpg(self.process.pid, signal.SIGKILL)
                self.process.wait(timeout=2)
        if self.process.stdin is not None and not self.process.stdin.closed:
            self.process.stdin.close()
        self.reader.join(timeout=2)
        if self.process.stdout is not None:
            self.process.stdout.close()
        self.stderr_stream.close()
        if not self.recorded:
            self.commands.append(
                {
                    "id": f"consumer-{self.mode}",
                    "argv": self.argv,
                    "cwd": str(self.cwd.resolve()),
                    "environment": self.selected_environment,
                    "timeout_seconds": self.timeout,
                    "exit_code": self.process.returncode,
                    "stdout": text_artifact(self.stdout_path),
                    "stderr": text_artifact(self.stderr_path),
                }
            )
            self.recorded = True


def run_case(
    binary: Path,
    output: Path,
    commands: list[dict[str, object]],
    mode: str,
    fixture: Callable[[ConsumerProcess, DnsPeers], dict[str, object]],
    *,
    extra_env: dict[str, str] | None = None,
) -> dict[str, object]:
    with DnsPeers() as peers:
        environment = {"WIRESTACK_DNS_PORT": str(peers.port)}
        if extra_env:
            environment.update(extra_env)
        process = ConsumerProcess(binary, mode, environment, output, commands)
        try:
            observations = fixture(process, peers)
        except (OSError, RuntimeError, ValueError, subprocess.TimeoutExpired, queue.Empty, AssertionError) as error:
            raise RuntimeError(
                f"{mode}: {type(error).__name__}: {error}; observed peers: "
                + json.dumps(peers.summary(), sort_keys=True)
            ) from error
        finally:
            process.close()
        return {"status": "PASS", "mode": mode, **peers.summary(), **observations}


def basic_fixture(process: ConsumerProcess, peers: DnsPeers) -> dict[str, object]:
    query, source = peers.receive_udp("a.native.test", 1)
    answer = rr(None, 1, 30, bytes([192, 0, 2, 10]))
    nameserver = rr(None, 2, 30, b"\x02ns\xC0\x0C")
    nameserver_offset = int(parse_query(query)["question_end"]) + len(answer) + 12
    glue = (
        struct.pack("!H", 0xC000 | nameserver_offset)
        + struct.pack("!HHIH", 1, 1, 30, 4)
        + bytes([192, 0, 2, 53])
    )
    peers.send(response(query, answers=[answer], authority=[nameserver], additional=[glue]), source)
    query, source = peers.receive_udp("a.native.test", 1)
    peers.send(response(query, answers=[answer], authority=[nameserver], additional=[glue]), source)

    query, source = peers.receive_udp("aaaa.native.test", 28)
    address = bytes.fromhex("20010db800000000000000000000002a")
    peers.send(response(query, answers=[rr(None, 28, 30, address)]), source)

    query, source = peers.receive_udp("owner.native.test", 1)
    answers = [
        rr("evil.native.test", 1, 30, bytes([203, 0, 113, 9])),
        cname(None, "target.native.test", 20),
        rr("target.native.test", 1, 10, bytes([198, 51, 100, 77])),
    ]
    peers.send(response(query, answers=answers), source)
    process.finish("BASIC_PASS")
    return {"checks": ["udp_a", "udp_aaaa", "cname_answer_owner", "compressed_ns_glue_excluded_from_answer"]}


def cache_capacity_fixture(process: ConsumerProcess, peers: DnsPeers) -> dict[str, object]:
    for name, value in [("lru-a", 1), ("lru-b", 2), ("lru-c", 3), ("lru-b", 4)]:
        query, source = peers.receive_udp(f"{name}.native.test", 1)
        peers.send(response(query, answers=[rr(None, 1, 300, bytes([192, 0, 2, value]))]), source)
    process.finish("CACHE_CAPACITY_PASS")
    return {"checks": ["bounded_lru_eviction", "cache_hit_updates_recency", "configured_ttl_cap"]}


def cname_bounds_fixture(process: ConsumerProcess, peers: DnsPeers) -> dict[str, object]:
    names = ["long-chain.native.test"] + [f"hop{index}.native.test" for index in range(1, 10)]
    query, source = peers.receive_udp(names[0], 1)
    records = [cname(None if index == 0 else names[index], names[index + 1], 30) for index in range(8)]
    peers.send(response(query, answers=records), source)
    query, source = peers.receive_udp(names[8], 1)
    peers.send(response(query, answers=[
        cname(None, names[9], 30), rr(names[9], 1, 30, bytes([192, 0, 2, 80]))
    ]), source)

    query, source = peers.receive_udp("loop-chain.native.test", 1)
    peers.send(response(query, answers=[
        cname(None, "middle.native.test", 30), cname("middle.native.test", "end.native.test", 30)
    ]), source)
    query, source = peers.receive_udp("end.native.test", 1)
    peers.send(response(query, answers=[
        cname(None, "middle.native.test", 30), rr("middle.native.test", 1, 30, bytes([192, 0, 2, 81]))
    ]), source)
    process.finish("CNAME_BOUNDS_PASS")
    return {"checks": ["lookup_wide_eight_alias_limit", "cross_response_intermediate_alias_loop"]}


def combined_negative_fixture(process: ConsumerProcess, peers: DnsPeers) -> dict[str, object]:
    query, source = peers.receive_udp("combined-negative.native.test", 1)
    alias_sent = time.monotonic_ns()
    peers.send(response(query, flags=0x8183,
        answers=[cname(None, "missing-target.native.test", 1)],
        authority=[soa("native.test")]), source)
    query, source = peers.receive_udp("expiry-barrier.native.test", 1)
    time.sleep(CNAME_DELAY_SECONDS)
    barrier_sent = time.monotonic_ns()
    peers.send(response(query, answers=[rr(None, 1, 0, bytes([192, 0, 2, 1]))]), source)
    query, source = peers.receive_udp("combined-negative.native.test", 1)
    peers.send(response(query, answers=[rr(None, 1, 30, bytes([192, 0, 2, 73]))]), source)
    process.finish("COMBINED_NEGATIVE_PASS")
    if barrier_sent - alias_sent < 1_000_000_000:
        raise RuntimeError("combined negative fixture did not cross the CNAME TTL")
    return {"checks": ["same_response_cname_bounds_negative_expiry"],
            "elapsed_alias_lifetime_ns": barrier_sent - alias_sent}


def negative_scope_fixture(process: ConsumerProcess, peers: DnsPeers) -> dict[str, object]:
    query, source = peers.receive_udp("namewide.native.test", 1)
    peers.send(negative(query, authoritative=True, authority=[soa("native.test")]), source)
    peers.udp.settimeout(0.25)
    try:
        try:
            query, source = peers.receive_udp("namewide.native.test", 28)
        except socket.timeout:
            pass
        else:
            peers.send(negative(query, authoritative=True, authority=[soa("native.test")]), source)
    finally:
        peers.udp.settimeout(SOCKET_TIMEOUT_SECONDS)
    process.finish("NEGATIVE_SCOPE_PASS")
    if len(peers.queries) != 1:
        raise RuntimeError("NXDOMAIN cache sent another query for the second address family")
    return {"checks": ["nxdomain_cache_is_namewide"]}


def search_boundary_fixture(process: ConsumerProcess, peers: DnsPeers) -> dict[str, object]:
    names = ["node.test"] + [f"node.test.s{index}.test" for index in range(15)]
    for index, name in enumerate(names):
        query, source = peers.receive_udp(name, 1)
        wire = (response(query, answers=[rr(None, 1, 30, bytes([192, 0, 2, 74]))])
                if index == 15 else negative(query, authoritative=True))
        peers.send(wire, source)
    process.finish("SEARCH_BOUNDARY_PASS")
    return {"checks": ["absolute_first_uses_sixteen_candidate_bound"]}


def fallback_fixture(process: ConsumerProcess, peers: DnsPeers) -> dict[str, object]:
    name = "fallback.native.test"
    query, source = peers.receive_udp(name, 1)
    final = response(query, answers=[rr(None, 1, 30, bytes([203, 0, 113, 91]))])
    peers.send(final, source, rogue=True)
    parsed = parse_query(query)
    peers.send(response(query, flags=0x8380, transaction_id=(int(parsed["id"]) + 1) & 0xFFFF), source)
    wrong_question = encode_name(name) + struct.pack("!HH", 28, 1)
    peers.send(response(query, flags=0x8380, question=wrong_question), source)
    peers.send(response(query, flags=0x8380, question=encode_name("wrong.native.test") + struct.pack("!HH", 1, 1)), source)
    peers.send(response(query, flags=0x8380, question=encode_name(name) + struct.pack("!HH", 1, 3)), source)
    peers.send(response(query, flags=0x0380), source)
    peers.send(response(query, flags=0x8B80), source)
    peers.tcp.settimeout(0.1)
    try:
        try:
            unexpected, _ = peers.tcp.accept()
        except socket.timeout:
            pass
        else:
            unexpected.close()
            raise RuntimeError("an invalid truncated response triggered TCP fallback")
    finally:
        peers.tcp.settimeout(SOCKET_TIMEOUT_SECONDS)
    peers.send(response(query, flags=0x8380), source)

    with peers.accept_tcp(query, name, 1) as connection:
        frame = struct.pack("!H", len(final)) + final
        connection.sendall(frame[:1])
        time.sleep(0.02)
        connection.sendall(frame[1:7])
        connection.sendall(frame[7:])
    process.finish("FALLBACK_IDENTITY_PASS")
    return {
        "checks": ["wrong_source_rejected", "wrong_id_rejected", "wrong_name_rejected",
                   "wrong_type_rejected", "wrong_class_rejected", "wrong_qr_rejected",
                   "wrong_opcode_rejected", "invalid_tc_no_tcp_fallback", "tc_tcp_fallback"],
        "rejected_candidates_sent": 7,
        "tcp_frame_bytes": len(final) + 2,
        "tcp_frame_chunk_sizes": [1, 6, len(frame) - 7],
    }


def negative(query: bytes, *, authoritative: bool, authority: Sequence[bytes] = ()) -> bytes:
    return response(query, flags=0x8583 if authoritative else 0x8183, authority=authority)


def cache_fixture(process: ConsumerProcess, peers: DnsPeers) -> dict[str, object]:
    query, source = peers.receive_udp("auth-negative.native.test", 1)
    peers.send(negative(query, authoritative=True, authority=[soa("native.test")]), source)

    for _ in range(2):
        query, source = peers.receive_udp("no-soa.native.test", 1)
        peers.send(negative(query, authoritative=True), source)

    for _ in range(2):
        query, source = peers.receive_udp("unrelated-soa.native.test", 1)
        peers.send(
            negative(query, authoritative=True, authority=[soa("unrelated.invalid")]), source
        )

    query, source = peers.receive_udp("nonauth-soa.native.test", 1)
    peers.send(negative(query, authoritative=False, authority=[soa("native.test")]), source)

    for value in (1, 2):
        query, source = peers.receive_udp("ttl-zero.native.test", 1)
        peers.send(response(query, answers=[rr(None, 1, 0, bytes([192, 0, 2, value]))]), source)

    process.finish("CACHE_POLICY_PASS")
    counts: dict[str, int] = {}
    for item in peers.queries:
        name = str(item["name"])
        counts[name] = counts.get(name, 0) + 1
    expected = {
        "auth-negative.native.test": 1,
        "no-soa.native.test": 2,
        "unrelated-soa.native.test": 2,
        "nonauth-soa.native.test": 1,
        "ttl-zero.native.test": 2,
    }
    if counts != expected:
        raise RuntimeError(f"negative/TTL cache query counts differ: {counts}")
    return {
        "checks": ["authoritative_negative_cache", "no_soa_no_cache", "unrelated_soa_no_cache", "recursive_negative_cache", "ttl_zero_no_cache"],
        "query_counts_by_name": counts,
    }


def cname_ttl_fixture(process: ConsumerProcess, peers: DnsPeers) -> dict[str, object]:
    timing: list[dict[str, object]] = []

    query, source = peers.receive_udp("short-alias.native.test", 1)
    first_alias_sent = time.monotonic_ns()
    peers.send(response(query, answers=[cname(None, "delayed-middle.native.test", 1)]), source)
    query, source = peers.receive_udp("delayed-middle.native.test", 1)
    time.sleep(CNAME_DELAY_SECONDS)
    later_cname_sent = time.monotonic_ns()
    peers.send(response(query, answers=[cname(None, "slow-target.native.test", 30)]), source)
    query, source = peers.receive_udp("slow-target.native.test", 1)
    peers.send(response(query, answers=[rr(None, 1, 30, bytes([192, 0, 2, 41]))]), source)
    timing.append(
        {
            "chain": "positive",
            "configured_delay_seconds": CNAME_DELAY_SECONDS,
            "alias_to_later_cname_response_elapsed_ns": later_cname_sent - first_alias_sent,
        }
    )

    query, source = peers.receive_udp("short-alias.native.test", 1)
    peers.send(response(query, answers=[rr(None, 1, 30, bytes([192, 0, 2, 42]))]), source)

    query, source = peers.receive_udp("short-negative-alias.native.test", 1)
    negative_alias_sent = time.monotonic_ns()
    peers.send(response(query, answers=[cname(None, "delayed-negative-middle.native.test", 1)]), source)
    query, source = peers.receive_udp("delayed-negative-middle.native.test", 1)
    time.sleep(CNAME_DELAY_SECONDS)
    negative_later_cname_sent = time.monotonic_ns()
    peers.send(response(query, answers=[cname(None, "slow-missing.native.test", 30)]), source)
    query, source = peers.receive_udp("slow-missing.native.test", 1)
    peers.send(
        negative(query, authoritative=True, authority=[soa("native.test", ttl=30, minimum=30)]),
        source,
    )
    timing.append(
        {
            "chain": "negative",
            "configured_delay_seconds": CNAME_DELAY_SECONDS,
            "alias_to_later_cname_response_elapsed_ns": negative_later_cname_sent - negative_alias_sent,
        }
    )

    query, source = peers.receive_udp("short-negative-alias.native.test", 1)
    peers.send(negative(query, authoritative=True), source)
    process.finish("CNAME_TTL_PASS")

    for item in timing:
        if int(item["alias_to_later_cname_response_elapsed_ns"]) < 1_000_000_000:
            raise RuntimeError(f"CNAME expiry fixture did not cross its one-second TTL: {item}")
    return {
        "checks": ["delayed_multihop_positive_ttl", "delayed_multihop_negative_ttl"],
        "timing": timing,
    }


def lifecycle_fixture(process: ConsumerProcess, peers: DnsPeers) -> dict[str, object]:
    waits: list[dict[str, object]] = []
    for kind, action in (("udp", "cancel"), ("udp", "close"), ("tcp", "cancel"), ("tcp", "close")):
        process.expect(f"WAIT_READY {kind} {action}")
        name = f"pending-{kind}-{action}.native.test"
        query, source = peers.receive_udp(name, 1)
        connection: socket.socket | None = None
        try:
            if kind == "tcp":
                peers.send(response(query, flags=0x8380), source)
                connection = peers.accept_tcp(query, name, 1)
                connection.sendall(b"\x00")
            process.send("stop")
            process.expect(f"WAIT_PASS {kind} {action}")
            remaining_descriptors = socket_fds(process.process.pid)
            if remaining_descriptors:
                raise RuntimeError(
                    f"{kind} {action} retained socket descriptors: {remaining_descriptors}"
                )
            peer_eof = None
            if connection is not None:
                peer_eof = connection.recv(1) == b""
                if not peer_eof:
                    raise RuntimeError(f"partial TCP frame remained open after {action}")
            waits.append(
                {
                    "transport": kind.upper(),
                    "action": action,
                    "partial_tcp_length_prefix_bytes": 1 if kind == "tcp" else 0,
                    "peer_observed_eof": peer_eof,
                    "socket_fds_after_completion": remaining_descriptors,
                }
            )
            process.send("next")
        finally:
            if connection is not None:
                connection.close()
    process.finish("LIFECYCLE_PASS")
    return {"checks": ["pending_udp_cancel", "pending_udp_close", "partial_tcp_cancel", "partial_tcp_close"], "waits": waits}


def connect_fixture(
    process: ConsumerProcess,
    peers: DnsPeers,
    service: socket.socket,
) -> dict[str, object]:
    started = time.monotonic_ns()
    query, source = peers.receive_udp("service.native.test", 1)
    time.sleep(0.1)
    dns_response_at = time.monotonic_ns()
    peers.send(response(query, answers=[rr(None, 1, 30, bytes([127, 0, 0, 1]))]), source)
    connection, remote = service.accept()
    accepted_at = time.monotonic_ns()
    with connection:
        connection.settimeout(SOCKET_TIMEOUT_SECONDS)
        request = receive_exact(connection, 4)
        if request != b"ping":
            raise RuntimeError(f"Resolver.connect service received {request!r}")
        connection.sendall(b"pong")
    process.finish("CONNECT_PASS")
    return {
        "checks": ["resolver_connect_dns_to_real_tcp_service", "single_operation_context"],
        "service_connections": 1,
        "service_remote_address": remote[0],
        "service_remote_port": remote[1],
        "dns_response_at_ns_from_start": dns_response_at - started,
        "service_accept_at_ns_from_start": accepted_at - started,
        "operation_deadline_seconds": 2,
    }


def run_connect_case(
    binary: Path,
    output: Path,
    commands: list[dict[str, object]],
) -> dict[str, object]:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as service:
        service.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        service.settimeout(SOCKET_TIMEOUT_SECONDS)
        service.bind(("127.0.0.1", 0))
        service.listen(1)
        port = int(service.getsockname()[1])
        return run_case(
            binary,
            output,
            commands,
            "connect",
            lambda process, peers: connect_fixture(process, peers, service),
            extra_env={"WIRESTACK_SERVICE_PORT": str(port)},
        )


def system_fallback_namespace(binary: Path, output: Path, parent_namespaces: str) -> None:
    """Exercise real glibc DNS search in private user, mount and network namespaces."""
    report: dict[str, object] = {
        "mode": "system-fallback", "status": "FAIL", "commands": [], "queries": [], "literal_exchange": [],
    }
    records = report["commands"]
    queries = report["queries"]
    literal_exchange = report["literal_exchange"]
    maximum_name = ".".join(["a" * 63] * 3 + ["a" * 61])
    answers = {"printer": 10, "printer.chosen.test": 20, "direct": 30, maximum_name: 40}
    try:
        parents = json.loads(parent_namespaces)
        for kind in ("user", "mnt", "net"):
            if os.readlink(f"/proc/self/ns/{kind}") == parents[kind]:
                raise RuntimeError(f"system fallback requires a private {kind} namespace")
        for key in ("LOCALDOMAIN", "RES_OPTIONS"):
            os.environ.pop(key, None)
        # AI_ADDRCONFIG excludes loopback-only namespaces. Give the isolated
        # resolver a non-loopback IPv4 interface without any external route.
        network = [
            ["ip", "link", "set", "lo", "up"],
            ["ip", "link", "add", "dns0", "type", "veth", "peer", "name", "dns1"],
            ["ip", "address", "add", "192.0.2.1/24", "dev", "dns0"],
            ["ip", "link", "set", "dns0", "up"],
            ["ip", "link", "set", "dns1", "up"],
        ]
        for index, argv in enumerate(network):
            command(argv, ROOT, output, f"system-fallback-network-{index}", 5, records)
        with tempfile.TemporaryDirectory(prefix="wirestack-dns-policy-") as temporary:
            directory = Path(temporary)
            policy = {
                "resolv.conf": "nameserver 127.0.0.1\nsearch corp.test\noptions ndots:15 timeout:1 attempts:1\n",
                "nsswitch.conf": "hosts: dns\n",
            }
            report["system_policy"] = policy
            for name, contents in policy.items():
                source = directory / name
                source.write_text(contents, encoding="utf-8")
                command(["mount", "--bind", str(source), f"/etc/{name}"], ROOT, output,
                        f"system-fallback-{name}", 5, records)
            with (
                socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as server,
                socket.socket(socket.AF_INET, socket.SOCK_STREAM) as service,
            ):
                server.bind(("127.0.0.1", 53))
                server.settimeout(0.1)
                service.bind(("127.0.0.1", 0))
                service.listen(1)
                service.settimeout(0.1)
                stopped = threading.Event()
                errors: list[str] = []

                def serve() -> None:
                    try:
                        while not stopped.is_set():
                            try:
                                query, peer = server.recvfrom(65535)
                            except socket.timeout:
                                continue
                            parsed = parse_query(query)
                            queries.append({"name": parsed["name"], "type": parsed["type"]})
                            if len(queries) > 16 or parsed["type"] != 1:
                                raise RuntimeError("system resolver exceeded the expected bounded IPv4 query domain")
                            value = answers.get(parsed["name"], 99)
                            server.sendto(response(query, answers=[rr(None, 1, 0, bytes([192, 0, 2, value]))]), peer)
                    except (OSError, RuntimeError, ValueError) as error:
                        errors.append(str(error))

                def exchange() -> None:
                    try:
                        while not stopped.is_set():
                            try:
                                peer, _ = service.accept()
                            except socket.timeout:
                                continue
                            with peer:
                                peer.settimeout(SOCKET_TIMEOUT_SECONDS)
                                received = receive_exact(peer, 4)
                                if received != b"ping":
                                    raise RuntimeError("literal connection sent unexpected application bytes")
                                peer.sendall(b"pong")
                                literal_exchange.append({"received": received.hex(), "sent": b"pong".hex()})
                            return
                    except (OSError, RuntimeError, ValueError) as error:
                        errors.append(str(error))

                worker = threading.Thread(target=serve, daemon=True)
                worker.start()
                service_worker = threading.Thread(target=exchange, daemon=True)
                service_worker.start()
                process = None
                try:
                    process = ConsumerProcess(binary, "system-fallback",
                                              {"WIRESTACK_SERVICE_PORT": str(service.getsockname()[1])},
                                              output, records)
                    process.finish("SYSTEM_FALLBACK_PASS")
                finally:
                    if process is not None:
                        process.close()
                    stopped.set()
                    worker.join(timeout=1)
                    service_worker.join(timeout=1)
                if worker.is_alive() or service_worker.is_alive() or errors:
                    raise RuntimeError(f"system DNS peer did not finish cleanly: {errors}")
                if [query["name"] for query in queries] != ["printer", "printer.chosen.test", "direct", maximum_name]:
                    raise RuntimeError(f"system resolver applied an unexpected search expansion: {queries}")
                if literal_exchange != [{"received": b"ping".hex(), "sent": b"pong".hex()}]:
                    raise RuntimeError("literal connect did not complete its DNS-free application exchange")
        report["status"] = "PASS"
    except (OSError, RuntimeError, ValueError, subprocess.TimeoutExpired, queue.Empty) as error:
        report["error"] = f"{type(error).__name__}: {error}"
    print(json.dumps(report, sort_keys=True))
    raise SystemExit(0 if report["status"] == "PASS" else 1)


def run_system_fallback_case(binary: Path, output: Path, commands: list[dict[str, object]]) -> dict[str, object]:
    parents = {kind: os.readlink(f"/proc/self/ns/{kind}") for kind in ("user", "mnt", "net")}
    child = (
        "import sys; from pathlib import Path; "
        "from tools.m8_004_native_dns import system_fallback_namespace; "
        "system_fallback_namespace(Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3])"
    )
    command(
        ["unshare", "--user", "--map-root-user", "--net", "--mount", "--propagation", "private",
         sys.executable, "-c", child, str(binary), str(output), json.dumps(parents)],
        ROOT, output, "system-fallback-namespace", CASE_TIMEOUT_SECONDS + 10, commands,
    )
    return json.loads((output / "system-fallback-namespace.stdout.log").read_text(encoding="utf-8"))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", type=Path, default=DEFAULT_REPORT)
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()

    try:
        report_path = bounded_path(args.report, "report path")
        output = bounded_path(args.output_dir, "output directory")
        if report_path == output or output in report_path.parents:
            raise ValueError("report path must not be inside the raw output directory")
        output.mkdir(parents=True, exist_ok=True)
    except (OSError, ValueError) as error:
        print(json.dumps({"source_task": TASK_ID, "status": "FAIL", "error": str(error)}, sort_keys=True))
        return 1

    report: dict[str, object] = {
        "schema_version": 1,
        "source_task": TASK_ID,
        "status": "FAIL",
        "platform": {
            "system": platform.system(),
            "machine": platform.machine(),
            "libc": platform.libc_ver(),
        },
        "invocation": {
            "argv": [sys.executable, str(Path(__file__).resolve()), *sys.argv[1:]],
            "cwd": str(Path.cwd().resolve()),
            "report": str(report_path),
            "output_dir": str(output),
        },
        "limits": {
            "case_timeout_seconds": CASE_TIMEOUT_SECONDS,
            "socket_timeout_seconds": SOCKET_TIMEOUT_SECONDS,
            "cname_delay_seconds": CNAME_DELAY_SECONDS,
            "dns_packet_bytes": 65535,
            "tcp_backlog": 8,
            "public_client_query_timeout_seconds": 5,
            "public_connect_deadline_seconds": 2,
        },
        "commands": [],
        "scenarios": [],
        "source_digests": {
            "tools/m8_004_native_dns.py": text_evidence_digest(Path(__file__)).to_json(),
            "examples/linux/m8_004/native_dns.cj": text_evidence_digest(SOURCE).to_json(),
        },
    }
    commands = report["commands"]
    scenarios = report["scenarios"]
    assert isinstance(commands, list) and isinstance(scenarios, list)

    try:
        examples.require_platform()
        command(["cjc", "-v"], ROOT, output, "toolchain", 10, commands)
        command(
            [sys.executable, "tools/build_linux_resolver.py", "--root", str(ROOT), "--quiet"],
            ROOT,
            output,
            "resolver-native-build",
            120,
            commands,
        )
        with tempfile.TemporaryDirectory(prefix="wirestack-m8-004-consumer-") as temporary:
            consumer = Path(temporary)
            (consumer / "src").mkdir()
            manifest = examples.consumer_manifest().replace(
                "wirestack_m7_027_examples", "wirestack_m8_004_native_dns"
            )
            manifest = manifest.replace(
                "M7-027 clean migration example consumer", "M8-004 native DNS consumer"
            )
            (consumer / "cjpm.toml").write_text(manifest, encoding="utf-8")
            (consumer / "src/main.cj").write_text(SOURCE.read_text(encoding="utf-8"), encoding="utf-8")
            command(["cjpm", "build"], consumer, output, "consumer-build", 600, commands)
            binary = consumer / "target/release/bin/main"
            if not binary.is_file():
                raise RuntimeError("consumer build produced no executable")
            report["binary_digest"] = artifact_byte_digest(binary).to_json()
            cases = [
                ("basic", basic_fixture),
                ("fallback-identity", fallback_fixture),
                ("cache-policy", cache_fixture),
                ("cname-ttl", cname_ttl_fixture),
                ("cache-capacity", cache_capacity_fixture),
                ("cname-bounds", cname_bounds_fixture),
                ("combined-negative", combined_negative_fixture),
                ("negative-scope", negative_scope_fixture),
                ("search-boundary", search_boundary_fixture),
                ("lifecycle", lifecycle_fixture),
                ("connect", None),
                ("system-fallback", None),
            ]
            for mode, fixture in cases:
                try:
                    if mode == "system-fallback":
                        scenario = run_system_fallback_case(binary, output, commands)
                    elif fixture is None:
                        scenario = run_connect_case(binary, output, commands)
                    else:
                        scenario = run_case(binary, output, commands, mode, fixture)
                    scenarios.append(scenario)
                except (OSError, RuntimeError, ValueError, subprocess.TimeoutExpired, queue.Empty, AssertionError) as error:
                    scenarios.append({"mode": mode, "status": "FAIL", "error": f"{type(error).__name__}: {error}"})
        report["status"] = "PASS" if all(case["status"] == "PASS" for case in scenarios) else "FAIL"
    except (
        OSError,
        RuntimeError,
        ValueError,
        subprocess.TimeoutExpired,
        socket.timeout,
        queue.Empty,
        AssertionError,
    ) as error:
        report["error"] = f"{type(error).__name__}: {error}"

    examples.atomic_json(report_path, report)
    print(json.dumps(report, sort_keys=True))
    return 0 if report["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
