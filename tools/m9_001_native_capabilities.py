#!/usr/bin/env python3
"""Qualify the installed public Linux network capability contract."""
from __future__ import annotations

import argparse
from collections import Counter
import errno
import json
import os
from pathlib import Path
import platform as host_platform
import queue
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import tomllib
from typing import Any, Callable, Sequence

ROOT = Path(__file__).resolve().parents[1]
TOOLS = ROOT / "tools"
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))
if str(TOOLS) not in sys.path:
    sys.path.insert(0, str(TOOLS))

import m8_002_native_sockets as internet_support
import m8_003_native_sockets as unix_support
import m8_004_native_dns as dns_support
from tools import development_baseline
from tools import m7_021_linux_release as release
from tools import m8_005_native_http as installed_support
from tools.evidence_digest import ArtifactByteDigest, TextEvidenceDigest, artifact_byte_digest, text_evidence_digest

TASK_ID = "M9-001"
PLATFORM = "linux-x86_64-glibc"
DEFAULT_REPORT = ROOT / "docs/evidence/M9-001/native-capabilities.json"
DEFAULT_OUTPUT = ROOT / "docs/evidence/M9-001/native-capabilities"
CAPABILITY_DESCRIPTION = ROOT / "docs/references/linux-network-capabilities.json"
CAPABILITY_SOURCE = ROOT / "examples/linux/m9_001/native_capabilities.cj"
INTERNET_SOURCE = ROOT / "examples/linux/m8_002/main.cj"
UNIX_SOURCE = ROOT / "examples/linux/m8_003/main.cj"
DNS_SOURCE = ROOT / "examples/linux/m8_004/native_dns.cj"
SCENARIO_IDS = (
    "internet-ipv4",
    "internet-ipv6",
    "unix-pathname",
    "unix-abstract",
    "capability-contract",
    "dns-basic",
    "dns-connect",
)
CAPABILITY_FIELDS = (
    "nonBlocking",
    "closeOnExec",
    "halfClose",
    "broadcast",
    "multicast",
    "raw",
    "ancillaryData",
    "zeroLengthDatagramSend",
    "connectedDatagramSend",
)
CAPABILITY_CLASSES = (
    "TcpStream",
    "TcpListener",
    "UdpSocket",
    "UnixStream",
    "UnixListener",
    "UnixDatagramSocket",
)
EXPECTED_CAPABILITIES = {
    name: {
        field: field in {"nonBlocking", "closeOnExec"}
        or (name == "UdpSocket" and field == "connectedDatagramSend")
        for field in CAPABILITY_FIELDS
    }
    for name in CAPABILITY_CLASSES
}
PROFILE_TIMEOUTS = {
    "internet-ipv4": 60,
    "internet-ipv6": 60,
    "unix-pathname": 90,
    "unix-abstract": 90,
    "capability-contract": 90,
    "dns-basic": dns_support.CASE_TIMEOUT_SECONDS,
    "dns-connect": dns_support.CASE_TIMEOUT_SECONDS,
}
BUILD_TIMEOUT_SECONDS = 600


class EnvironmentFailure(RuntimeError):
    """A native prerequisite failed without changing the permanent capability contract."""


def require(condition: bool, reason: str) -> None:
    if not condition:
        raise RuntimeError(reason)


def relative(path: Path) -> str:
    return path.resolve().relative_to(ROOT).as_posix()


def text_artifact(path: Path) -> dict[str, object]:
    return {"path": relative(path), "digest": text_evidence_digest(path).to_json()}


def typed_source_tree_digest(root: Path) -> dict[str, str]:
    return TextEvidenceDigest(release.source_tree_sha256(root)).to_json()


def normalize_text(text: str, replacements: Sequence[tuple[str, str]] = ()) -> str:
    values = list(replacements)
    values.extend(((str(ROOT.resolve()), "<repo>"), (str(Path.home()), "$HOME")))
    if os.environ.get("CANGJIE_HOME"):
        values.append((str(Path(os.environ["CANGJIE_HOME"]).resolve()), "<sdk>"))
    for old, new in sorted(values, key=lambda item: len(item[0]), reverse=True):
        if old:
            text = text.replace(old, new)
    return re.sub(r"/(?:var/tmp|tmp|home)/[^\s\"'<>]+", "<scratch>", text)


def normalize_value(value: Any, replacements: Sequence[tuple[str, str]]) -> Any:
    if isinstance(value, dict):
        return {key: normalize_value(item, replacements) for key, item in value.items()}
    if isinstance(value, list):
        return [normalize_value(item, replacements) for item in value]
    if isinstance(value, tuple):
        return [normalize_value(item, replacements) for item in value]
    if isinstance(value, str):
        return normalize_text(value, replacements)
    return value


def sanitize_logs(output: Path, replacements: Sequence[tuple[str, str]]) -> None:
    for path in sorted(output.rglob("*.log")):
        raw = path.read_text(encoding="utf-8")
        path.write_text(normalize_text(raw, replacements), encoding="utf-8")


def refresh_text_artifacts(value: Any) -> None:
    if isinstance(value, dict):
        path_value = value.get("path")
        if isinstance(path_value, str) and "digest" in value:
            path = ROOT / path_value
            if path.is_file() and path.suffix in {".log", ".json", ".txt", ".cj", ".py"}:
                value["digest"] = text_evidence_digest(path).to_json()
        for item in value.values():
            refresh_text_artifacts(item)
    elif isinstance(value, list):
        for item in value:
            refresh_text_artifacts(item)


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
    exit_code: int | None = None
    try:
        with stdout.open("w", encoding="utf-8") as out, stderr.open("w", encoding="utf-8") as err:
            try:
                completed = subprocess.run(
                    list(argv), cwd=cwd, stdout=out, stderr=err,
                    timeout=timeout, check=False,
                )
                exit_code = completed.returncode
            except subprocess.TimeoutExpired:
                timed_out = True
    finally:
        records.append({
            "id": name,
            "argv": [str(item) for item in argv],
            "cwd": str(cwd.resolve()),
            "timeout_seconds": timeout,
            "timed_out": timed_out,
            "exit_code": exit_code,
            "stdout": text_artifact(stdout),
            "stderr": text_artifact(stderr),
        })
    if timed_out:
        raise RuntimeError(f"{name} exceeded its {timeout}-second command budget")
    if exit_code != 0:
        raise RuntimeError(f"{name} exited {exit_code}; see {stderr}")


def git_value(*arguments: str) -> str:
    completed = subprocess.run(
        ["git", *arguments], cwd=ROOT, capture_output=True, text=True,
        check=False, timeout=10,
    )
    if completed.returncode != 0:
        raise RuntimeError(f"git {' '.join(arguments)} failed")
    value = completed.stdout.strip()
    if not value:
        raise RuntimeError(f"git {' '.join(arguments)} returned no value")
    return value


def ensure_ipv6_loopback() -> None:
    try:
        with socket.socket(socket.AF_INET6, socket.SOCK_DGRAM) as probe:
            probe.bind(("::1", 0))
    except OSError as error:
        if error.errno in {errno.EAFNOSUPPORT, errno.EADDRNOTAVAIL, errno.EPERM, errno.EACCES}:
            raise EnvironmentFailure(f"native IPv6 loopback is unavailable: errno={error.errno}") from error
        raise


def build_consumer(
    installed: Path,
    source: Path,
    package_name: str,
    description: str,
    work: Path,
    output: Path,
    command_id: str,
    records: list[dict[str, object]],
) -> tuple[Path, ArtifactByteDigest]:
    consumer = work / package_name
    (consumer / "src").mkdir(parents=True)
    manifest = release.consumer_manifest(installed)
    manifest = manifest.replace("wirestack_release_smoke", package_name)
    manifest = manifest.replace("M7-021 installed Wirestack release smoke", description)
    parsed = tomllib.loads(manifest)
    dependencies = parsed.get("dependencies")
    dependency = dependencies.get("wirestack") if isinstance(dependencies, dict) else None
    require(
        isinstance(dependencies, dict)
        and set(dependencies) == {"wirestack"}
        and isinstance(dependency, dict)
        and dependency.get("path") == str(installed.resolve())
        and str(ROOT.resolve()) not in manifest,
        f"{package_name} did not depend only on the extracted release root",
    )
    (consumer / "cjpm.toml").write_text(manifest, encoding="utf-8")
    shutil.copy2(source, consumer / "src/main.cj")
    command(["cjpm", "build"], consumer, output, command_id, BUILD_TIMEOUT_SECONDS, records)
    binary = consumer / "target/release/bin/main"
    require(binary.is_file(), f"{package_name} build produced no executable")
    return binary, artifact_byte_digest(binary)


def fd_inventory(pid: int) -> list[dict[str, str]]:
    values: list[dict[str, str]] = []
    for entry in sorted((Path("/proc") / str(pid) / "fd").iterdir(), key=lambda item: int(item.name)):
        try:
            target = os.readlink(entry)
        except FileNotFoundError:
            continue
        if target.startswith("/"):
            target = "file:" + Path(target).name
        values.append({"fd": entry.name, "target": target})
    return values


def task_inventory(pid: int) -> list[dict[str, object]]:
    names = []
    for entry in (Path("/proc") / str(pid) / "task").iterdir():
        try:
            names.append((entry / "comm").read_text(encoding="utf-8").strip())
        except FileNotFoundError:
            continue
    return [{"name": name, "count": count} for name, count in sorted(Counter(names).items())]


def traced_child_pid(process: subprocess.Popen[str]) -> int:
    children = (Path("/proc") / str(process.pid) / "task" / str(process.pid) / "children").read_text().split()
    require(len(children) == 1, f"cannot identify the strace child process: {children}")
    return int(children[0])


def exchange_stream_server(server: socket.socket, errors: queue.Queue[Exception | None]) -> None:
    try:
        connection, _ = server.accept()
        with connection:
            connection.settimeout(10)
            for expected in (b"\x01", b"\x02"):
                require(internet_support.receive_exact(connection, 1) == expected, "outgoing stream byte differed")
                connection.sendall(expected)
        errors.put(None)
    except Exception as error:
        errors.put(error)


def exchange_accepted_client(
    family: int,
    address: str | bytes,
    errors: queue.Queue[Exception | None],
) -> None:
    try:
        with socket.socket(family, socket.SOCK_STREAM) as client:
            client.settimeout(10)
            client.connect(address)
            client.sendall(b"\x01")
            require(internet_support.receive_exact(client, 1) == b"\x01", "accepted stream first echo differed")
            require(internet_support.receive_exact(client, 1) == b"\x02", "accepted stream recovery byte differed")
            client.sendall(b"\x02")
        errors.put(None)
    except Exception as error:
        errors.put(error)


def echo_datagrams(peer: socket.socket, errors: queue.Queue[Exception | None]) -> None:
    try:
        peer.settimeout(10)
        for expected in (b"\x01", b"\x02"):
            payload, source = peer.recvfrom(8)
            require(payload == expected, "datagram peer received the wrong byte")
            peer.sendto(payload, source)
        errors.put(None)
    except Exception as error:
        errors.put(error)


def parse_capability_observations(lines: Sequence[str]) -> tuple[dict[str, dict[str, bool]], dict[str, list[dict[str, object]]]]:
    observations: dict[str, list[dict[str, object]]] = {name: [] for name in CAPABILITY_CLASSES}
    for line in lines:
        if not line.startswith("CAP "):
            continue
        parts = line.split()
        require(len(parts) == 4 + len(CAPABILITY_FIELDS) - 1, f"invalid capability line: {line}")
        _, class_name, instance, *raw_flags = parts
        require(class_name in observations, f"unexpected capability class: {class_name}")
        require(all(value in {"true", "false"} for value in raw_flags), f"invalid capability flags: {line}")
        flags = dict(zip(CAPABILITY_FIELDS, (value == "true" for value in raw_flags), strict=True))
        require(not any(item["instance"] == instance for item in observations[class_name]),
                f"duplicate capability instance: {class_name}/{instance}")
        observations[class_name].append({"instance": instance, "capabilities": flags})
    collapsed: dict[str, dict[str, bool]] = {}
    for class_name in CAPABILITY_CLASSES:
        values = observations[class_name]
        require(values, f"missing capability observations for {class_name}")
        first = values[0]["capabilities"]
        require(all(item["capabilities"] == first for item in values),
                f"cross-instance capability difference for {class_name}: {values}")
        require(first == EXPECTED_CAPABILITIES[class_name],
                f"observed capabilities differ for {class_name}: {first}")
        collapsed[class_name] = first
    return collapsed, observations


def capability_profile(binary: Path, output: Path) -> tuple[dict[str, object], dict[str, dict[str, bool]]]:
    ensure_ipv6_loopback()
    if shutil.which("strace") is None:
        raise EnvironmentFailure("strace is required for native allocation proof")
    trace = output / "capability-contract.syscalls.log"
    stdout = output / "capability-contract.stdout.log"
    stderr = output / "capability-contract.stderr.log"
    lines: queue.Queue[str | None] = queue.Queue(maxsize=256)
    peer_results: queue.Queue[Exception | None] = queue.Queue(maxsize=8)
    process: subprocess.Popen[str] | None = None
    reader: threading.Thread | None = None
    workers: list[threading.Thread] = []
    deadline = time.monotonic() + PROFILE_TIMEOUTS["capability-contract"]
    captured: list[str] = []

    def read_output(stream: object) -> None:
        with stdout.open("w", encoding="utf-8") as log:
            for line in stream:
                log.write(line)
                log.flush()
                value = line.rstrip("\r\n")
                captured.append(value)
                lines.put(value, timeout=1)
        lines.put(None, timeout=1)

    def next_line() -> str:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise RuntimeError("capability consumer exceeded its 90-second protocol budget")
        value = lines.get(timeout=remaining)
        if value is None:
            raise RuntimeError("capability consumer exited before protocol completion")
        return value

    def wait_for(prefix: str) -> str:
        while True:
            value = next_line()
            if value.startswith(prefix):
                return value

    with tempfile.TemporaryDirectory(prefix="wirestack-m9-001-peer-") as namespace:
        namespace_path = Path(namespace)
        outgoing_unix = namespace_path / "outgoing-stream"
        accepted_unix = namespace_path / "listener"
        datagram_peer_path = namespace_path / "datagram-peer"
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as tcp_server, \
                socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as unix_server, \
                socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp4_peer, \
                socket.socket(socket.AF_INET6, socket.SOCK_DGRAM) as udp6_peer, \
                socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as unix_datagram_peer:
            tcp_server.settimeout(10)
            tcp_server.bind(("127.0.0.1", 0))
            tcp_server.listen(1)
            unix_server.settimeout(10)
            unix_server.bind(str(outgoing_unix))
            unix_server.listen(1)
            udp4_peer.bind(("127.0.0.1", 0))
            udp6_peer.bind(("::1", 0))
            unix_datagram_peer.bind(str(datagram_peer_path))
            for target, function, arguments in (
                ("tcp-outgoing", exchange_stream_server, (tcp_server, peer_results)),
                ("unix-outgoing", exchange_stream_server, (unix_server, peer_results)),
                ("udp4", echo_datagrams, (udp4_peer, peer_results)),
                ("udp6", echo_datagrams, (udp6_peer, peer_results)),
                ("unix-datagram", echo_datagrams, (unix_datagram_peer, peer_results)),
            ):
                worker = threading.Thread(target=function, args=arguments, name=target, daemon=True)
                worker.start()
                workers.append(worker)
            environment = os.environ.copy()
            environment.update({
                "WIRESTACK_TCP_V4_PEER_PORT": str(tcp_server.getsockname()[1]),
                "WIRESTACK_UDP_V4_PEER_PORT": str(udp4_peer.getsockname()[1]),
                "WIRESTACK_UDP_V6_PEER_PORT": str(udp6_peer.getsockname()[1]),
                "WIRESTACK_UNIX_PREFIX": namespace,
                "WIRESTACK_UNIX_STREAM_PEER": str(outgoing_unix),
                "WIRESTACK_UNIX_DATAGRAM_PEER": str(datagram_peer_path),
            })
            try:
                with stderr.open("w", encoding="utf-8") as err:
                    process = subprocess.Popen(
                        ["strace", "-f", "-e",
                         "trace=socket,socketpair,accept,accept4,bind,connect,sendto,recvfrom,shutdown,clone,clone3,close",
                         "-o", str(trace), str(binary)],
                        cwd=binary.parent, env=environment, stdin=subprocess.PIPE,
                        stdout=subprocess.PIPE, stderr=err, text=True, bufsize=1,
                        start_new_session=True,
                    )
                    assert process.stdout is not None and process.stdin is not None
                    reader = threading.Thread(target=read_output, args=(process.stdout,), daemon=True)
                    reader.start()
                    ready = wait_for("READY ").split()
                    require(len(ready) == 2, f"unexpected capability readiness: {ready}")
                    tcp_client = threading.Thread(
                        target=exchange_accepted_client,
                        args=(socket.AF_INET, ("127.0.0.1", int(ready[1])), peer_results),
                        name="tcp-accepted", daemon=True,
                    )
                    unix_client = threading.Thread(
                        target=exchange_accepted_client,
                        args=(socket.AF_UNIX, str(accepted_unix), peer_results),
                        name="unix-accepted", daemon=True,
                    )
                    tcp_client.start()
                    unix_client.start()
                    workers.extend((tcp_client, unix_client))
                    require(wait_for("UNSUPPORTED_READY") == "UNSUPPORTED_READY",
                            "unsupported checkpoint changed")
                    child = traced_child_pid(process)
                    before_fds = fd_inventory(child)
                    before_tasks = task_inventory(child)
                    trace_offset = trace.stat().st_size
                    process.stdin.write("continue\n")
                    process.stdin.flush()
                    completed = wait_for("UNSUPPORTED_DONE ").split()
                    require(len(completed) == 5, f"unexpected unsupported completion: {completed}")
                    raw_environment_failure = completed[1:] != ["true", "true", "true", "true"]
                    after_fds = fd_inventory(child)
                    after_tasks = task_inventory(child)
                    with trace.open("r", encoding="utf-8") as stream:
                        stream.seek(trace_offset)
                        unsupported_trace = stream.read()
                    (output / "unsupported.syscalls.log").write_text(unsupported_trace, encoding="utf-8")
                    require(before_fds == after_fds, "unsupported operations changed the process FD inventory")
                    require(before_tasks == after_tasks, "unsupported operations changed the process task inventory")
                    socket_allocations = [line for line in unsupported_trace.splitlines()
                                          if re.search(r"\b(?:socket|socketpair|accept4?)\(", line)]
                    task_allocations = [line for line in unsupported_trace.splitlines()
                                        if re.search(r"\bclone3?\(", line)]
                    shutdown_calls = [line for line in unsupported_trace.splitlines()
                                      if re.search(r"\bshutdown\(", line)]
                    privileged_raw = [line for line in socket_allocations if "SOCK_RAW" in line]
                    require(not socket_allocations, f"unsupported operations allocated sockets: {socket_allocations}")
                    require(not task_allocations, f"unsupported operations created tasks: {task_allocations}")
                    require(not shutdown_calls, f"unsupported half-close reached a native syscall: {shutdown_calls}")
                    require(not privileged_raw, f"raw rejection reached a privileged syscall: {privileged_raw}")
                    if raw_environment_failure:
                        raise EnvironmentFailure("raw socket probes reached an environment permission failure")
                    process.stdin.write("continue\n")
                    process.stdin.flush()
                    require(wait_for("CAPABILITY_CONTRACT_PASS") == "CAPABILITY_CONTRACT_PASS",
                            "capability consumer omitted its completion marker")
                    process.stdin.close()
                    if process.wait(timeout=max(0.1, deadline - time.monotonic())) != 0:
                        raise RuntimeError(f"capability consumer exited {process.returncode}")
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
                for worker in workers:
                    worker.join(timeout=11)
            for _ in workers:
                result = peer_results.get(timeout=1)
                if result is not None:
                    raise RuntimeError(f"independent capability peer failed: {result}")
    collapsed, observations = parse_capability_observations(captured)
    details = {
        "status": "PASS",
        "checks": [
            "all_nine_fields", "default_no_broadcast_multicast", "typed_unsupported_errors",
            "healthy_state_and_io_after_rejection", "dns_parser_positive_negative",
            "no_socket_allocation", "no_background_task_growth", "no_privileged_raw_syscall",
        ],
        "capability_observations": observations,
        "resource_proof": {
            "fd_inventory_before": before_fds,
            "fd_inventory_after": after_fds,
            "task_inventory_before": before_tasks,
            "task_inventory_after": after_tasks,
            "unchanged": True,
            "socket_allocations": 0,
            "task_allocations": 0,
            "native_shutdown_calls": 0,
            "no_privileged_raw_syscall": True,
            "syscalls": text_artifact(output / "unsupported.syscalls.log"),
        },
        "raw_ipv4": "UNSUPPORTED_BEFORE_NATIVE_IO",
        "raw_ipv6": "UNSUPPORTED_BEFORE_NATIVE_IO",
        "raw_packet": "UNSUPPORTED_BEFORE_NATIVE_IO",
        "raw_netlink": "UNSUPPORTED_BEFORE_NATIVE_IO",
        "stdout": text_artifact(stdout),
        "stderr": text_artifact(stderr),
        "syscalls": text_artifact(trace),
    }
    return details, collapsed


def record_profile_command(
    commands: list[dict[str, object]],
    scenario_id: str,
    details: dict[str, object],
) -> None:
    commands.append({
        "id": f"scenario-{scenario_id}",
        "argv": ["<installed-consumer>", scenario_id],
        "cwd": "<consumer>",
        "timeout_seconds": PROFILE_TIMEOUTS[scenario_id],
        "timed_out": False,
        "exit_code": 0,
        "stdout": details.get("stdout"),
        "stderr": details.get("stderr"),
    })


def run_scenario(
    scenarios: list[dict[str, object]],
    scenario_id: str,
    operation: Callable[[], dict[str, object]],
) -> dict[str, object] | None:
    entry: dict[str, object] = {"id": scenario_id, "status": "FAIL"}
    scenarios.append(entry)
    try:
        details = operation()
        require(details.get("status") == "PASS", f"{scenario_id} did not pass")
        entry.update({"status": "PASS", "details": details})
        return details
    except EnvironmentFailure as error:
        entry.update({"status": "ENVIRONMENT_FAILURE", "details": {"reason": str(error)}})
    except (OSError, RuntimeError, ValueError, subprocess.TimeoutExpired, queue.Empty, AssertionError) as error:
        entry.update({"status": "FAIL", "details": {"error": f"{type(error).__name__}: {error}"}})
    return None


def source_provenance() -> dict[str, dict[str, str]]:
    paths = set(release.production_sources(ROOT))
    paths.update(ROOT / value for value in release.QUALIFICATION_INPUTS)
    paths.update({
        ROOT / "cjpm.toml", ROOT / "cjpm.lock", Path(__file__), CAPABILITY_SOURCE,
        INTERNET_SOURCE, UNIX_SOURCE, DNS_SOURCE,
        CAPABILITY_DESCRIPTION,
        ROOT / "tools/check_network_capabilities.py",
        ROOT / "tools/m7_026_linux_api_freeze.py",
        ROOT / "tools/m7_027_linux_examples.py",
        ROOT / "tools/m8_002_native_sockets.py",
        ROOT / "tools/m8_003_native_sockets.py",
        ROOT / "tools/m8_004_native_dns.py",
        ROOT / "tools/m8_005_native_http.py",
        ROOT / "tools/m7_021_linux_release.py",
        ROOT / "tools/development_baseline.py",
        ROOT / "tools/evidence_digest.py",
        ROOT / "docs/references/m7-033-ci-toolchain.json",
    })
    return {relative(path): text_evidence_digest(path).to_json() for path in sorted(paths)}


def qualify(
    report: dict[str, object],
    output: Path,
    sdk_archive: Path,
    *,
    offline: bool,
    compile_only: bool,
) -> None:
    platform_details = release.platform_identity()
    report["platform_details"] = platform_details
    report["native_execution"] = True
    report["cross_compiled"] = False
    report["base_revision"] = git_value("rev-parse", "HEAD")
    report["source_state"] = "WORKING_TREE_UNSEALED"
    try:
        report["merge_base"] = git_value("merge-base", "HEAD", "origin/main")
    except RuntimeError:
        report["merge_base"] = None
    report["source_digest"] = typed_source_tree_digest(ROOT)
    report["sdk"] = development_baseline.sdk_identity(ROOT, sdk_archive.resolve())
    require(CAPABILITY_DESCRIPTION.is_file(), "capability description is absent")
    report["capability_description_digest"] = text_evidence_digest(CAPABILITY_DESCRIPTION).to_json()
    report["input_digests"] = source_provenance()

    commands = report["commands"]
    scenarios = report["scenarios"]
    assert isinstance(commands, list) and isinstance(scenarios, list)
    command(["cjc", "-v"], ROOT, output, "toolchain", 10, commands)

    archive = ROOT / "dist/m9-001" / release.ARTIFACT_NAME
    archive.parent.mkdir(parents=True, exist_ok=True)
    archive, expected_manifest = installed_support.build_archive(output, archive, commands, offline=offline)
    report["artifact"] = {
        "path": relative(archive),
        "digest": artifact_byte_digest(archive).to_json(),
        "payload_digest": TextEvidenceDigest(expected_manifest["payload_sha256"]).to_json(),
    }

    with tempfile.TemporaryDirectory(prefix="wirestack-m9-001-installed-") as temporary:
        work = Path(temporary)
        installed = release.extract_archive(archive, work / "install")
        require(not installed.resolve().is_relative_to(ROOT.resolve()),
                "release package was extracted inside the checkout")
        actual_manifest = json.loads((installed / "release-manifest.json").read_text(encoding="utf-8"))
        require(actual_manifest == expected_manifest, "extracted release manifest differs from fresh payload")
        report["installed_source_digest"] = typed_source_tree_digest(installed)
        report["installation"] = {
            "method": "fresh archive extracted outside checkout; consumers depend only on extracted root",
            "checkout_path_dependency": False,
            "release_manifest_digest": text_evidence_digest(installed / "release-manifest.json").to_json(),
        }
        internet_binary, internet_digest = build_consumer(
            installed, INTERNET_SOURCE, "wirestack_m8_002_native", "M9-001 reused installed Internet consumer",
            work, output, "internet-consumer-build", commands,
        )
        unix_binary, unix_digest = build_consumer(
            installed, UNIX_SOURCE, "wirestack_m8_003_native", "M9-001 reused installed Unix consumer",
            work, output, "unix-consumer-build", commands,
        )
        dns_binary, dns_digest = build_consumer(
            installed, DNS_SOURCE, "wirestack_m8_004_native_dns", "M9-001 reused installed DNS consumer",
            work, output, "dns-consumer-build", commands,
        )
        capability_binary, capability_digest = build_consumer(
            installed, CAPABILITY_SOURCE, "wirestack_m9_001_native_capabilities",
            "M9-001 installed capability contract consumer", work, output,
            "capability-consumer-build", commands,
        )
        report["consumer_binaries"] = {
            "internet": internet_digest.to_json(),
            "unix": unix_digest.to_json(),
            "dns": dns_digest.to_json(),
            "capability_contract": capability_digest.to_json(),
        }
        if compile_only:
            report["status"] = "COMPILE_PASS"
            replacements = ((str(work.resolve()), "<work>"),)
            sanitize_logs(output, replacements)
            normalized = normalize_value(report, replacements)
            report.clear()
            report.update(normalized)
            for record in report["commands"]:
                if isinstance(record, dict):
                    record.setdefault("timed_out", False)
            refresh_text_artifacts(report)
            return

        internet_output = output / "internet"
        unix_output = output / "unix"
        dns_output = output / "dns"
        contract_output = output / "contract"
        for directory in (internet_output, unix_output, dns_output, contract_output):
            directory.mkdir(parents=True, exist_ok=True)

        for scenario_id, profile_name in (("internet-ipv4", "ipv4"), ("internet-ipv6", "ipv6")):
            def internet_operation(name: str = profile_name) -> dict[str, object]:
                if name == "ipv6":
                    ensure_ipv6_loopback()
                return internet_support.profile(internet_binary, internet_output, name)
            details = run_scenario(scenarios, scenario_id, internet_operation)
            if details is not None:
                record_profile_command(commands, scenario_id, details)

        for scenario_id, profile_name in (("unix-pathname", "pathname"), ("unix-abstract", "abstract")):
            details = run_scenario(
                scenarios, scenario_id,
                lambda name=profile_name: unix_support.profile(unix_binary, unix_output, name),
            )
            if details is not None:
                record_profile_command(commands, scenario_id, details)

        observed: dict[str, dict[str, bool]] = {}
        contract_details = run_scenario(
            scenarios, "capability-contract",
            lambda: capability_profile(capability_binary, contract_output)[0],
        )
        if contract_details is not None:
            observed, observations = parse_capability_observations(
                (contract_output / "capability-contract.stdout.log").read_text(encoding="utf-8").splitlines()
            )
            contract_details["capability_observations"] = observations
            record_profile_command(commands, "capability-contract", contract_details)
        report["observed_capabilities"] = observed

        basic_details = run_scenario(
            scenarios, "dns-basic",
            lambda: dns_support.run_case(dns_binary, dns_output, commands, "basic", dns_support.basic_fixture),
        )
        if basic_details is not None:
            basic_details["scope"] = "configured local nameserver; no system-fallback claim"
        connect_details = run_scenario(
            scenarios, "dns-connect",
            lambda: dns_support.run_connect_case(dns_binary, dns_output, commands),
        )
        if connect_details is not None:
            connect_details["scope"] = "configured local nameserver and controlled TCP service"

        require(tuple(item.get("id") for item in scenarios) == SCENARIO_IDS,
                "native scenarios were missing, duplicated, or reordered")
        report["status"] = "PASS" if all(item.get("status") == "PASS" for item in scenarios) else "FAIL"

    replacements = ((str(work.resolve()), "<work>"),)
    sanitize_logs(output, replacements)
    normalized = normalize_value(report, replacements)
    report.clear()
    report.update(normalized)
    for record in report["commands"]:
        if isinstance(record, dict):
            record.setdefault("timed_out", False)
            record.setdefault("timeout_seconds", PROFILE_TIMEOUTS.get(str(record.get("id", "")).removeprefix("scenario-"),
                                                                       dns_support.CASE_TIMEOUT_SECONDS))
    refresh_text_artifacts(report)


def bounded_path(path: Path, label: str) -> Path:
    resolved = path.resolve()
    try:
        relative_path = resolved.relative_to(ROOT)
    except ValueError as error:
        raise ValueError(f"{label} must remain under the repository root") from error
    if relative_path.parts[:2] == ("docs", "evidence") and (
        len(relative_path.parts) < 3 or relative_path.parts[2] != TASK_ID
    ):
        raise ValueError(f"{label} must not rewrite another task's evidence")
    if resolved in {Path(__file__).resolve(), CAPABILITY_SOURCE.resolve()}:
        raise ValueError(f"{label} must not overwrite qualification sources")
    return resolved


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", type=Path, default=DEFAULT_REPORT)
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--sdk-archive", type=Path, default=os.environ.get("WIRESTACK_BASELINE_SDK_ARCHIVE"))
    parser.add_argument("--offline", action="store_true")
    parser.add_argument("--compile-only", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    try:
        report_path = bounded_path(args.report, "report path")
        output = bounded_path(args.output_dir, "output directory")
        require(args.sdk_archive is not None, "set WIRESTACK_BASELINE_SDK_ARCHIVE or --sdk-archive")
        require(report_path != output and output not in report_path.parents,
                "report path must not be inside the raw output directory")
        output.mkdir(parents=True, exist_ok=True)
    except (OSError, RuntimeError, ValueError) as error:
        print(json.dumps({"source_task": TASK_ID, "status": "FAIL", "error": str(error)}, sort_keys=True))
        return 1

    report: dict[str, object] = {
        "schema_version": 1,
        "source_task": TASK_ID,
        "status": "FAIL",
        "platform": PLATFORM,
        "native_execution": False,
        "cross_compiled": True,
        "commands": [],
        "scenarios": [],
        "observed_capabilities": {},
        "invocation": {
            "argv": ["python3", relative(Path(__file__)), *sys.argv[1:]],
            "cwd": "<repo>",
            "offline": args.offline,
            "compile_only": args.compile_only,
        },
    }
    try:
        qualify(report, output, args.sdk_archive, offline=args.offline, compile_only=args.compile_only)
    except (
        OSError, RuntimeError, ValueError, KeyError, TypeError, AttributeError, AssertionError,
        subprocess.TimeoutExpired, socket.timeout, queue.Empty, release.ReleaseError,
    ) as error:
        report["status"] = "FAIL"
        report["error"] = normalize_text(f"{type(error).__name__}: {error}")
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(report, sort_keys=True))
    return 0 if report["status"] in {"PASS", "COMPILE_PASS"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
