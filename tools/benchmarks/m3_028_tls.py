#!/usr/bin/env python3
"""Run the native Linux M3-028 TLS qualification and benchmark gate."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import re
import shutil
import socket
import statistics
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path
from typing import Any, Mapping, Sequence

ROUNDS = 11
WIRE_RE = re.compile(
    r"M3028_WIRESTACK scenario=(\S+) iterations=(\d+) durationNs=(\d+) "
    r"bytes=(\d+) resumed=(true|false)"
)
STDX_RE = re.compile(
    r"M3028_STDX scenario=(\S+) iterations=(\d+) durationNs=(\d+) "
    r"bytes=(\d+) resumed=(true|false)"
)
COMPILE_RE = re.compile(r'^(\s*compile-option\s*=\s*)"[^"]*"', re.MULTILINE)
MIB = 1024 * 1024


class GateError(RuntimeError):
    pass


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(command: Sequence[str], cwd: Path, timeout: float,
        env: Mapping[str, str] | None = None, check: bool = True,
        input_text: str | None = None) -> subprocess.CompletedProcess[str]:
    try:
        result = subprocess.run(
            list(command), cwd=cwd, env=env, input=input_text,
            stdin=None if input_text is not None else subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            errors="replace", timeout=timeout, check=False,
        )
    except subprocess.TimeoutExpired as error:
        raise GateError(f"command timed out: {' '.join(command)}") from error
    if check and result.returncode != 0:
        raise GateError(
            f"command failed ({result.returncode}): {' '.join(command)}\n"
            f"{result.stderr[-6000:]}"
        )
    return result


def nearest_rank(values: Sequence[float], percentile: int) -> float:
    ordered = sorted(values)
    if not ordered:
        raise GateError("empty percentile input")
    index = max(1, (percentile * len(ordered) + 99) // 100) - 1
    return ordered[index]


def enable_o2(manifest: Path) -> None:
    text = manifest.read_text(encoding="utf-8")
    if len(COMPILE_RE.findall(text)) != 1:
        raise GateError("expected one compile-option in benchmark snapshot")
    manifest.write_text(COMPILE_RE.sub(r'\1"-O2"', text, count=1), encoding="utf-8")


def prepare_wirestack(root: Path, destination: Path, prefix: Sequence[str],
                      timeout: float) -> tuple[Path, list[list[str]]]:
    shutil.copytree(
        root, destination,
        ignore=shutil.ignore_patterns(
            ".git", ".cjpm", ".codex", "target", "__pycache__", "*.pyc"
        ),
    )
    native = root / "target/native"
    if not native.is_dir():
        raise GateError("native TLS provider artifact is missing")
    (destination / "target").mkdir()
    (destination / "target/native").symlink_to(native, target_is_directory=True)
    enable_o2(destination / "cjpm.toml")
    commands: list[list[str]] = []
    for package in (
        "src/internal/transport_stdnet", "src/internal/tls_engine", "src/internal/trust"
    ):
        command = [
            *prefix, "cjpm", "test", package, "-j", "1", "--no-run",
            "--no-progress", "--no-color",
        ]
        run(command, destination, timeout)
        commands.append(command)
    binary = destination / "target/release/unittest_bin/wirestack.internal.transport_stdnet"
    if not binary.is_file():
        raise GateError("optimized Wirestack benchmark binary is missing")
    return binary, commands


def verify_stdx(reference: Path, archive: Path, extracted: Path) -> tuple[dict[str, Any], Path]:
    data = json.loads(reference.read_text(encoding="utf-8"))
    if sha256(archive) != data["archive_sha256"]:
        raise GateError("stdx archive digest mismatch")
    dynamic = extracted / data["dynamic_directory"]
    for name, digest in data["module_sha256"].items():
        if sha256(dynamic / name) != digest:
            raise GateError(f"stdx module digest mismatch: {name}")
    return data, dynamic


def compile_stdx(root: Path, dynamic: Path, output: Path,
                 prefix: Sequence[str], timeout: float) -> list[str]:
    source = root / "tools/benchmarks/stdx_m3_028_tls.cj"
    command = [
        *prefix, "cjc", "-O2", str(source), "-L", str(dynamic),
        "--import-path", str(dynamic), "-lstdx.net.tls",
        "-lstdx.net.tls.common", "-lstdx.crypto.x509", "-lstdx.crypto.keys",
        "-o", str(output),
    ]
    run(command, root, timeout)
    return command


def generate_identity(directory: Path, timeout: float) -> dict[str, Path]:
    paths = {suffix: directory / f"identity.{suffix}" for suffix in ("pem", "key", "der", "pk8")}
    run([
        "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "2",
        "-subj", "/CN=example.com", "-addext", "subjectAltName=DNS:example.com",
        "-keyout", str(paths["key"]), "-out", str(paths["pem"]),
    ], directory, timeout)
    run(["openssl", "x509", "-in", str(paths["pem"]), "-outform", "DER",
         "-out", str(paths["der"])], directory, timeout)
    run(["openssl", "pkcs8", "-topk8", "-nocrypt", "-in", str(paths["key"]),
         "-outform", "DER", "-out", str(paths["pk8"])], directory, timeout)
    return paths


def environment(base: Mapping[str, str], scenario: str, version: str,
                iterations: int, byte_count: int, identity: Mapping[str, Path],
                port: int = 0) -> dict[str, str]:
    result = dict(base)
    result.update({
        "WIRESTACK_M3_028_SCENARIO": scenario,
        "WIRESTACK_M3_028_VERSION": version,
        "WIRESTACK_M3_028_ITERATIONS": str(iterations),
        "WIRESTACK_M3_028_BYTES": str(byte_count),
        "WIRESTACK_M3_028_CERT_DER": str(identity["der"]),
        "WIRESTACK_M3_028_KEY_DER": str(identity["pk8"]),
        "WIRESTACK_M3_028_CERT_PEM": str(identity["pem"]),
        "WIRESTACK_M3_028_KEY_PEM": str(identity["key"]),
        "WIRESTACK_M3_028_PORT": str(port),
    })
    return result


def parse_marker(output: str, pattern: re.Pattern[str], expected: str) -> dict[str, Any]:
    matches = pattern.findall(output)
    if len(matches) != 1 or matches[0][0] != expected:
        raise GateError(f"expected one {expected} marker")
    scenario, iterations, duration, byte_count, resumed = matches[0]
    return {
        "scenario": scenario, "iterations": int(iterations),
        "duration_ns": int(duration), "bytes": int(byte_count),
        "resumed": resumed == "true", "stdout": output,
    }


def command_for_wire(binary: Path) -> list[str]:
    return [str(binary), "--filter=M3028TlsBenchmarkTest.runProfile",
            "--show-all-output", "--no-progress", "--no-color"]


def sample(command: Sequence[str], cwd: Path, env: Mapping[str, str],
           pattern: re.Pattern[str], expected: str, timeout: float) -> dict[str, Any]:
    result = run(command, cwd, timeout, env=env)
    parsed = parse_marker(result.stdout, pattern, expected)
    parsed.update({"exit_code": result.returncode, "stderr": result.stderr})
    return parsed


def rss_kib(pid: int) -> int | None:
    try:
        for line in Path(f"/proc/{pid}/status").read_text(encoding="utf-8").splitlines():
            if line.startswith("VmRSS:"):
                return int(line.split()[1])
    except (FileNotFoundError, PermissionError, ProcessLookupError, ValueError):
        return None
    return None


def sampled_process(command: Sequence[str], cwd: Path, env: Mapping[str, str],
                    pattern: re.Pattern[str], expected: str,
                    timeout: float) -> dict[str, Any]:
    process = subprocess.Popen(
        list(command), cwd=cwd, env=env, stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        errors="replace", start_new_session=True,
    )
    samples: list[int] = []
    deadline = time.monotonic() + timeout
    while process.poll() is None:
        value = rss_kib(process.pid)
        if value is not None:
            samples.append(value)
        if time.monotonic() >= deadline:
            process.kill(); process.communicate()
            raise GateError(f"sampled command timed out: {' '.join(command)}")
        time.sleep(0.01)
    stdout, stderr = process.communicate()
    if process.returncode != 0 or not samples:
        raise GateError(
            f"sampled command failed: exit={process.returncode} samples={len(samples)}\n"
            f"{stderr[-5000:]}"
        )
    parsed = parse_marker(stdout, pattern, expected)
    parsed.update({
        "exit_code": process.returncode, "stderr": stderr,
        "rss_samples_kib": samples, "peak_rss_kib": max(samples),
        "median_rss_kib": statistics.median(samples),
    })
    return parsed


def memory_profiles(wire: Path, snapshot: Path, identity: Mapping[str, Path],
                    timeout: float) -> dict[str, Any]:
    body: list[dict[str, Any]] = []
    for byte_count in (1 * MIB, 16 * MIB, 64 * MIB, 100 * MIB):
        env = environment(os.environ, "bulk", "tls13", 1, byte_count, identity)
        body.append(sampled_process(
            command_for_wire(wire), snapshot, env, WIRE_RE, "bulk_tls13", timeout
        ))
    growth = int(body[-1]["peak_rss_kib"]) - int(body[0]["peak_rss_kib"])
    payload_growth_kib = (100 - 1) * 1024
    growth_ratio = growth / payload_growth_kib
    body_pass = growth <= 32 * 1024 and growth_ratio <= 0.25

    idle: list[dict[str, Any]] = []
    for pairs in (1, 8, 32, 64):
        env = environment(os.environ, "idle", "tls13", pairs, 0, identity)
        item = sampled_process(
            command_for_wire(wire), snapshot, env, WIRE_RE, "idle_tls13", timeout
        )
        item["pairs"] = pairs
        item["connections"] = pairs * 2
        idle.append(item)
    xs = [float(item["connections"]) for item in idle]
    ys = [float(item["median_rss_kib"]) for item in idle]
    x_mean, y_mean = statistics.mean(xs), statistics.mean(ys)
    denominator = sum((x - x_mean) ** 2 for x in xs)
    slope = sum((x - x_mean) * (y - y_mean) for x, y in zip(xs, ys)) / denominator
    intercept = y_mean - slope * x_mean
    idle_pass = slope <= 48.0
    return {
        "decision": "PASS" if body_pass and idle_pass else "FAIL",
        "body_scaling": {
            "decision": "PASS" if body_pass else "FAIL", "samples": body,
            "peak_growth_kib": growth, "growth_per_payload_kib": growth_ratio,
            "maximum_growth_kib": 32 * 1024, "maximum_growth_ratio": 0.25,
        },
        "idle_connections": {
            "decision": "PASS" if idle_pass else "FAIL", "samples": idle,
            "slope_kib_per_connection": slope, "intercept_kib": intercept,
            "maximum_kib_per_connection": 48.0,
            "method": "OLS slope of process VmRSS medians; shared contexts are the intercept; kernel socket buffers are outside process RSS",
        },
    }


def paired_rounds(wire: Path, stdx: Path, root: Path, snapshot: Path,
                  base_stdx_env: Mapping[str, str], identity: Mapping[str, Path],
                  scenario: str, version: str, iterations: int, byte_count: int,
                  timeout: float) -> dict[str, Any]:
    wire_samples: list[dict[str, Any]] = []
    stdx_samples: list[dict[str, Any]] = []
    wire_env = environment(os.environ, scenario, version, iterations, byte_count, identity)
    stdx_env = environment(base_stdx_env, scenario, version, iterations, byte_count, identity)
    expected = f"{scenario}_{version}"
    for index in range(ROUNDS + 1):
        order = ("wire", "stdx") if index % 2 == 0 else ("stdx", "wire")
        for leg in order:
            value = sample(
                command_for_wire(wire) if leg == "wire" else [str(stdx)],
                snapshot if leg == "wire" else root,
                wire_env if leg == "wire" else stdx_env,
                WIRE_RE if leg == "wire" else STDX_RE,
                expected, timeout,
            )
            if index > 0:
                (wire_samples if leg == "wire" else stdx_samples).append(value)
    return {"wirestack": wire_samples, "stdx": stdx_samples}


def metric(samples: Sequence[Mapping[str, Any]], scenario: str) -> list[float]:
    if scenario == "bulk":
        return [float(item["bytes"]) * 1e9 / float(item["duration_ns"]) for item in samples]
    return [float(item["duration_ns"]) / float(item["iterations"]) for item in samples]


def choose_port() -> int:
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return int(probe.getsockname()[1])


def interoperability(wire: Path, snapshot: Path, identity: Mapping[str, Path],
                     timeout: float) -> dict[str, Any]:
    results: dict[str, Any] = {}
    for version, option in (("tls12", "-tls1_2"), ("tls13", "-tls1_3")):
        port = choose_port()
        server = subprocess.Popen(
            ["openssl", "s_server", "-accept", str(port), "-cert", str(identity["pem"]),
             "-key", str(identity["key"]), option, "-rev", "-quiet"],
            cwd=snapshot, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True, start_new_session=True,
        )
        try:
            time.sleep(0.25)
            if server.poll() is not None:
                raise GateError("OpenSSL interop server exited before Wirestack connected")
            env = environment(os.environ, "interop-client", version, 1, 0, identity, port)
            client = sample(command_for_wire(wire), snapshot, env, WIRE_RE,
                            f"interop-client_{version}", timeout)
            results[f"wire_client_{version}"] = client
        finally:
            server.terminate()
            try:
                out, err = server.communicate(timeout=2)
            except subprocess.TimeoutExpired:
                server.kill(); out, err = server.communicate(timeout=2)
            results[f"openssl_server_{version}"] = {
                "exit_code": server.returncode, "stdout": out, "stderr": err,
            }

        port = choose_port()
        env = environment(os.environ, "interop-server", version, 1, 0, identity, port)
        wire_server = subprocess.Popen(
            command_for_wire(wire), cwd=snapshot, env=env, stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True,
        )
        try:
            time.sleep(0.25)
            openssl = run([
                "openssl", "s_client", "-connect", f"127.0.0.1:{port}",
                "-servername", "example.com", "-CAfile", str(identity["pem"]),
                option, "-quiet",
            ], snapshot, timeout, check=False, input_text="ping\n")
            stdout, stderr = wire_server.communicate(timeout=timeout)
        except Exception:
            wire_server.kill(); wire_server.communicate(); raise
        if wire_server.returncode != 0 or "pong\n" not in openssl.stdout:
            raise GateError(
                f"OpenSSL client interop failed: openssl={openssl.returncode} "
                f"wire={wire_server.returncode}\n{openssl.stderr[-3000:]}\n{stderr[-3000:]}"
            )
        results[f"wire_server_{version}"] = parse_marker(
            stdout, WIRE_RE, f"interop-server_{version}"
        )
        results[f"openssl_client_{version}"] = {
            "exit_code": openssl.returncode, "stdout": openssl.stdout,
            "stderr": openssl.stderr,
        }
    results["decision"] = "PASS"
    return results


def dependencies(binary: Path, root: Path) -> dict[str, Any]:
    readelf = run(["readelf", "-d", str(binary)], root, 30)
    ldd = run(["ldd", str(binary)], root, 30)
    text = (readelf.stdout + "\n" + ldd.stdout).lower()
    forbidden = [name for name in (
        "libssl", "libcrypto", "stdx.net.tlsffi", "dynamicloader-opensslffi"
    ) if name in text]
    manifest = json.loads((root / "target/native/current/provider-manifest.json").read_text())
    passed = not forbidden and manifest.get("externalOpenSslDependency") is False
    return {
        "decision": "PASS" if passed else "FAIL", "forbidden": forbidden,
        "readelf": readelf.stdout, "ldd": ldd.stdout, "manifest": manifest,
    }


def deterministic_qualification(root: Path, prefix: Sequence[str],
                                timeout: float) -> dict[str, Any]:
    command = [
        *prefix, "cjpm", "test", "src/internal/tls_engine", "src/internal/trust",
        "-j", "1", "--parallel", "1", "--show-all-output",
        "--no-progress", "--no-color",
    ]
    result = run(command, root, timeout)
    combined = result.stdout
    required = (
        "M3028_FUZZ target=tls-record,tls-handshake seed=3028 mutations=1024 decision=PASS",
        "M3028_FUZZ target=certificate-adapter seed=3028 mutations=512 decision=PASS",
        "M3028_FUZZ target=hostname-verifier seed=3028 mutations=2048 decision=PASS",
    )
    missing = [marker for marker in required if marker not in combined]
    return {
        "decision": "PASS" if not missing else "FAIL",
        "required_markers": list(required), "missing_markers": missing,
        "command": command, "exit_code": result.returncode,
        "stdout": result.stdout, "stderr": result.stderr,
    }


def classify(cases: Mapping[str, Any], resumed: Sequence[Mapping[str, Any]],
             dependency: Mapping[str, Any], interop: Mapping[str, Any],
             memory: Mapping[str, Any], qualification: Mapping[str, Any]) -> dict[str, Any]:
    bulk_wire = metric(cases["bulk_tls13"]["wirestack"], "bulk")
    bulk_stdx = metric(cases["bulk_tls13"]["stdx"], "bulk")
    full_wire = metric(cases["full_tls13"]["wirestack"], "full")
    full_stdx = metric(cases["full_tls13"]["stdx"], "full")
    bulk_ratio = statistics.median(bulk_wire) / statistics.median(bulk_stdx)
    p50_ratio = nearest_rank(full_wire, 50) / nearest_rank(full_stdx, 50)
    p95_ratio = nearest_rank(full_wire, 95) / nearest_rank(full_stdx, 95)
    resumed_ok = len(resumed) == ROUNDS and all(item["resumed"] for item in resumed)
    checks = {
        "bulk_ratio": {"value": bulk_ratio, "minimum": 0.9,
                       "decision": "PASS" if bulk_ratio >= 0.9 else "FAIL"},
        "full_p50_ratio": {"value": p50_ratio, "maximum": 1.1,
                           "decision": "PASS" if p50_ratio <= 1.1 else "FAIL"},
        "full_p95_ratio": {"value": p95_ratio, "maximum": 1.2,
                           "decision": "PASS" if p95_ratio <= 1.2 else "FAIL"},
        "wirestack_resumption": {"samples": len(resumed),
                                 "decision": "PASS" if resumed_ok else "FAIL"},
        "dependencies": {"decision": dependency["decision"]},
        "interoperability": {"decision": interop["decision"]},
        "memory": {"decision": memory["decision"]},
        "deterministic_and_fuzz": {"decision": qualification["decision"]},
    }
    return {
        "decision": "PASS" if all(v["decision"] == "PASS" for v in checks.values()) else "FAIL",
        "checks": checks,
    }


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--stdx-archive", type=Path, required=True)
    parser.add_argument("--stdx-root", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--timeout-seconds", type=float, default=180.0)
    parser.add_argument("--build-timeout-seconds", type=float, default=600.0)
    parser.add_argument("--command-prefix", nargs="+",
                        default=["/home/elliot/.codex/scripts/codex_cangjie_env"])
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    root = args.repo.resolve()
    reference = root / "docs/references/stdx-tls-baseline-linux.data"
    stdx_data, dynamic = verify_stdx(
        reference, args.stdx_archive.resolve(), args.stdx_root.resolve()
    )
    with tempfile.TemporaryDirectory(prefix="wirestack-m3-028-") as temporary:
        work = Path(temporary)
        snapshot = work / "repository"
        wire, wire_build = prepare_wirestack(
            root, snapshot, args.command_prefix, args.build_timeout_seconds
        )
        stdx = work / "stdx_tls"
        stdx_build = compile_stdx(
            root, dynamic, stdx, args.command_prefix, args.build_timeout_seconds
        )
        identity = generate_identity(work, args.timeout_seconds)
        stdx_env = dict(os.environ)
        runtime_dirs = [str(dynamic)]
        for candidate in (
            Path(os.environ.get("CANGJIE_HOME", "")) / "runtime/lib/linux_x86_64_cjnative",
            Path(os.environ.get("CANGJIE_HOME", "")) / "lib/linux_x86_64_cjnative",
        ):
            if candidate.is_dir(): runtime_dirs.append(str(candidate))
        prior = stdx_env.get("LD_LIBRARY_PATH")
        if prior: runtime_dirs.append(prior)
        stdx_env["LD_LIBRARY_PATH"] = ":".join(runtime_dirs)
        cases = {
            "full_tls13": paired_rounds(
                wire, stdx, root, snapshot, stdx_env, identity,
                "full", "tls13", 20, 0, args.timeout_seconds
            ),
            "bulk_tls13": paired_rounds(
                wire, stdx, root, snapshot, stdx_env, identity,
                "bulk", "tls13", 1, 16 * MIB, args.timeout_seconds
            ),
        }
        resumed: list[dict[str, Any]] = []
        resumed_env = environment(os.environ, "resumed", "tls13", 20, 0, identity)
        for index in range(ROUNDS + 1):
            value = sample(command_for_wire(wire), snapshot, resumed_env, WIRE_RE,
                           "resumed_tls13", args.timeout_seconds)
            if index > 0: resumed.append(value)
        qualification = deterministic_qualification(
            root, args.command_prefix, args.timeout_seconds
        )
        interop = interoperability(wire, snapshot, identity, args.timeout_seconds)
        memory = memory_profiles(wire, snapshot, identity, args.timeout_seconds)
        dependency = dependencies(wire, root)
        decision = classify(cases, resumed, dependency, interop, memory, qualification)
        report = {
            "schema_version": 1, "task": "M3-028", "platform": "linux_glibc_x86_64",
            "decision": decision, "cases": cases, "resumed": resumed,
            "interoperability": interop, "dependencies": dependency,
            "memory": memory, "deterministic_qualification": qualification,
            "build": {"wirestack": wire_build, "stdx": stdx_build},
            "stdx_reference": stdx_data,
            "environment": {"platform": platform.platform(), "python": sys.version},
        }
        output = args.output or (
            root / "docs/evidence/M3-028/linux_glibc_x86_64/tls-qualification.json"
        )
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        print(f"M3-028 decision={decision['decision']} report={output}")
        return 0 if decision["decision"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
