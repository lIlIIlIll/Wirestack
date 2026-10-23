#!/usr/bin/env python3
"""Native end-to-end development baselines; never a release qualification seal."""
from __future__ import annotations

import argparse
from collections import defaultdict
import json
import math
import os
from pathlib import Path
import re
import shutil
import signal
import statistics
import subprocess
import sys
import threading
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))
from tools import m7_021_linux_release as release
from tools.evidence_digest import (artifact_byte_digest, text_evidence_digest,
                                   text_evidence_digest_bytes,
                                   artifact_byte_sha256_equal, schema_artifact_sha256_equal)

SOURCES = ROOT / "examples/linux/m12_001"
CASES = {
    "transport_tls": ("tcp_bulk", "tcp_partial", "tcp_cancel", "udp_packets", "tls_full",
                      "tls_resumed", "tls_small", "tls_bulk", "tls_failure", "tls_close"),
    "http": ("h1_short_reuse", "h1_new_connection", "h1_bulk_4096", "h1_bulk_32768",
             "h1_concurrent", "h1_early_close", "h2_streams_1", "h2_streams_10",
             "h2_streams_100", "h2_slow_consumer", "h2_stream_cancel", "http_overload", "http_observed", "http_unobserved"),
    "streams": ("sse_h1", "sse_h2", "sse_slow", "sse_cancel", "websocket_h1", "websocket_h2",
                "websocket_fragmented", "websocket_slow", "websocket_disconnect"),
}
# Two scenarios share one native case but are not interchangeable measurements.
NATIVE_SCENARIOS = {"http_unobserved": "http_observed"}
OBSERVATION_MODES = {"http_observed": "enabled", "http_unobserved": "disabled"}
# Native case names passed as the measured binary's first argument.
BINARY_RELATIVE_PATH = "target/release/bin/main"
# Work per native operation supplied on the command line; bulk exchanges are 8 MiB each way.
WORKLOAD_COUNTS = {"tcp_bulk": 8, "tcp_partial": 256, "tcp_cancel": 32, "udp_packets": 1024,
                   "tls_full": 32, "tls_resumed": 32, "tls_small": 256, "tls_bulk": 8,
                   "tls_failure": 16, "tls_close": 32}
# Declared operation, expected-rejection and regime accounting for every measured scenario,
# including the scenarios whose work is fixed in the consumer rather than supplied on argv.
SCENARIO_CONTRACTS = {
    "tcp_bulk": (8, 0, "normal"),
    "tcp_partial": (256, 0, "normal"),
    "tcp_cancel": (32, 32, "cleanup"),
    "udp_packets": (1024, 0, "normal"),
    "tls_full": (32, 0, "normal"),
    "tls_resumed": (32, 0, "normal"),
    "tls_small": (256, 0, "normal"),
    "tls_bulk": (8, 0, "normal"),
    "tls_failure": (16, 16, "failure"),
    "tls_close": (32, 0, "cleanup"),
    "h1_short_reuse": (200, 0, "normal"),
    "h1_new_connection": (200, 0, "normal"),
    "h1_bulk_4096": (1, 0, "normal"),
    "h1_bulk_32768": (1, 0, "normal"),
    "h1_concurrent": (100, 0, "normal"),
    "h1_early_close": (200, 0, "cleanup"),
    "h2_streams_1": (200, 0, "normal"),
    "h2_streams_10": (100, 0, "normal"),
    "h2_streams_100": (1000, 0, "normal"),
    "h2_slow_consumer": (13, 0, "slow"),
    "h2_stream_cancel": (3, 1, "cleanup"),
    "http_overload": (6, 2, "overload"),
    "http_observed": (200, 0, "normal"),
    "http_unobserved": (200, 0, "normal"),
    "sse_h1": (256, 0, "normal"),
    "sse_h2": (256, 0, "normal"),
    "sse_slow": (256, 0, "slow"),
    "sse_cancel": (9, 1, "cleanup"),
    "websocket_h1": (256, 0, "normal"),
    "websocket_h2": (256, 0, "normal"),
    "websocket_fragmented": (200, 0, "normal"),
    "websocket_slow": (256, 0, "slow"),
    "websocket_disconnect": (9, 1, "cleanup"),
}
# Identity is reconstructed from these retained commands; the environment block never asserts
# a machine fact that its own command logs do not prove.
ENVIRONMENT_COMMANDS = (
    ("cjc", ["cjc", "--version"]),
    ("cjpm", ["cjpm", "--version"]),
    ("cpu", ["lscpu", "-J"]),
    ("uname", ["uname", "-srm"]),
    ("environment", ["python3", "tools/benchmarks/m12_001_end_to_end.py", "environment-witness"]),
)
# Declared method, not machine identity; it is recorded but cannot be forged by editing a report
# without changing this runner, whose digest the task-source contract binds.
ENVIRONMENT_DECLARATIONS = {
    "network": "Native same-host loopback; no injected RTT/loss; both peers in one executable",
    "optimization": "-O2 -g for dependency and consumer",
    "load": "One measured process at a time; case-specific bounded concurrency",
    "reuse": "Case-defined: persistent transport/TLS and H1/H2 reuse versus explicit fresh connections",
    "resource_boundary": "Whole native workload process /proc RSS/threads/fds includes runtime and both peers; not Wirestack-exclusive memory",
}
ENVIRONMENT_IDENTITY_KEYS = ("platform", "kernel", "cjc", "cjpm", "compiler_digest", "runtime_binaries",
                             "optimization", "network", "runtime_environment", "tls_provider",
                             "load", "reuse", "resource_boundary")
CPU_IDENTITY_FIELDS = {"Architecture:", "Model name:", "CPU(s):", "Thread(s) per core:",
                       "Core(s) per socket:", "Socket(s):"}
PROCESS_PEAK_KEYS = {"rss_kib": "process_peak_rss_kib", "fds": "process_peak_fds",
                     "threads": "process_peak_threads"}
# Bound-evidence report schema; older captures never claimed these bindings.
SCHEMA_VERSION = 2
TLS_IDENTITY_PREFIX = "TLS_IDENTITY "


def workload_arguments(binary: Path, scenario: str, work: Path) -> list[str]:
    native = NATIVE_SCENARIOS.get(scenario, scenario)
    args = [str(binary), native, str(work / "certificate.der"), str(work / "key.pk8")]
    if scenario in WORKLOAD_COUNTS:
        args.append(str(WORKLOAD_COUNTS[scenario]))
    elif scenario in OBSERVATION_MODES:
        args.append(OBSERVATION_MODES[scenario])
    return args


def environment_witness() -> dict:
    """Machine identity a retained report can be reconstructed from, minus volatile state."""
    compiler = shutil.which("cjc")
    sdk = Path(os.environ["CANGJIE_HOME"])
    return {"platform": release.platform_identity(),
            "compiler_digest": artifact_byte_digest(Path(compiler)).to_json(),
            "runtime_binaries": {path.name: artifact_byte_digest(path).to_json()
                                 for path in sorted((sdk / "runtime/lib/linux_x86_64_cjnative").glob("libcangjie*.so"))},
            "runtime_environment": {key: value for key, value in os.environ.items() if key.startswith("CJ_")}}


def scenario_contracts() -> dict:
    """The declared work contract recorded in a capture and rechecked on verification."""
    return {case: {"operations": operations, "expected_rejections": rejections, "regime": regime}
            for case, (operations, rejections, regime) in sorted(SCENARIO_CONTRACTS.items())}


UNKNOWN_COSTS = {
    "cangjie_allocations_per_io": "Unavailable: CPU samples and /proc RSS do not count managed allocation events.",
    "context_cancel_registration_allocations": "Unavailable: no per-operation managed allocation counter in the public contract.",
    "tls_pump_copied_bytes": "Unavailable: public TLS transport byte counts are not copy counts.",
    "http_body_copied_bytes": "Unavailable: caller read count does not identify internal copying.",
    "http2_writer_lock_wait_ns": "Unavailable: public snapshots expose ownership/bounds, not lock acquisition duration.",
    "pool_lock_wait_ns": "Unavailable: admission/pool queue duration is not mutex wait duration.",
    "udp_allocations_per_packet": "Unavailable: packet throughput/RSS cannot be converted into allocation counts.",
}


def percentile(values: list[int | float], percent: int) -> float:
    if not values or not 0 < percent <= 100:
        raise ValueError("percentile requires nonempty samples and 0 < percentile <= 100")
    return float(sorted(values)[math.ceil(percent * len(values) / 100) - 1])


def robust_noise(values: list[float]) -> float:
    center = statistics.median(values)
    if not math.isfinite(center) or center <= 0:
        raise ValueError("metrics must be finite and positive")
    return 1.4826 * statistics.median(abs(value - center) for value in values) / center


def validate_sample(row: dict, scenario: str) -> None:
    if row.get("scenario") != scenario or row.get("regime") not in {"normal", "slow", "overload", "failure", "cleanup"}:
        raise ValueError("scenario or regime differs from the requested workload")
    names = ("duration_ns", "operations", "successes", "failures", "expected_rejections", "bytes", "checksum")
    if any(type(row.get(name)) is not int or row[name] < 0 for name in names):
        raise ValueError("invalid operation accounting")
    latencies = row.get("latencies_ns")
    if (row["duration_ns"] <= 0 or row["operations"] <= 0
            or row["successes"] + row["failures"] + row["expected_rejections"] != row["operations"]
            or not isinstance(latencies, list) or len(latencies) != row["operations"]
            or any(type(value) is not int or value <= 0 for value in latencies)):
        raise ValueError("missing operation outcomes or latency samples")
    if row["failures"] != 0:
        raise ValueError("unexpected failures cannot be hidden by throughput")
    metrics = row.get("metrics")
    if not isinstance(metrics, dict) or type(metrics.get("cleanup_owners")) is not int or metrics["cleanup_owners"] != 0:
        raise ValueError("native operation owners were not reclaimed")
    if any(isinstance(value, float) and not math.isfinite(value) for value in metrics.values()):
        raise ValueError("invalid metric")
    if row["regime"] == "overload" and row["expected_rejections"] == 0:
        raise ValueError("overload must actually exercise rejection")
    if row["bytes"] and row["successes"] == 0:
        raise ValueError("successful byte count without successful operations")


def summarize(rows: list[dict]) -> dict:
    if not rows:
        raise ValueError("missing measured rounds")
    contracts = {(r["operations"], r["successes"], r["failures"], r["expected_rejections"], r["bytes"], r["checksum"], r["regime"]) for r in rows}
    if len(contracts) != 1:
        raise ValueError("workload or outcome accounting changed between rounds")
    latency = [n for row in rows for n in row["latencies_ns"]]
    rates = [r["successes"] * 1e9 / r["duration_ns"] for r in rows]
    durations = [float(r["duration_ns"]) for r in rows]
    tails = [percentile(r["latencies_ns"], 99) for r in rows]
    operations = sum(r["operations"] for r in rows)
    successes = sum(r["successes"] for r in rows)
    noise = {"duration": robust_noise(durations), "p99": robust_noise(tails)}
    if all(rate > 0 for rate in rates):
        noise["successful_operations_per_second"] = robust_noise(rates)
    return {"rounds": len(rows), "latency_samples": len(latency), "operations": operations,
            "successes": successes, "unexpected_failures": sum(r["failures"] for r in rows),
            "expected_rejections": sum(r["expected_rejections"] for r in rows),
            "unexpected_failure_rate": (operations - successes - sum(r["expected_rejections"] for r in rows)) / operations,
            "successful_operations_per_second": statistics.median(rates),
            "successful_bytes_per_second": statistics.median(r["bytes"] * 1e9 / r["duration_ns"] for r in rows),
            "p50_ns": percentile(latency, 50), "p95_ns": percentile(latency, 95), "p99_ns": percentile(latency, 99),
            "duration_ns_samples": durations, "p99_ns_samples": tails, "rate_samples": rates,
            "robust_relative_noise": noise, "regime": rows[0]["regime"],
            "contract": {key: rows[0][key] for key in
                         ("operations", "successes", "expected_rejections", "bytes", "checksum", "regime")}}


def freeze_reference(summary: dict) -> dict:
    # Floor is a declared policy; the rest of the threshold comes from observed between-round noise.
    noise = max(summary["robust_relative_noise"].values())
    limit = max(.05, 6 * noise)
    status = "INCONCLUSIVE" if summary["rounds"] < 7 else "NOISY" if noise > .20 or limit > .10 else "STABLE"
    return {"status": status, "relative_regression_limit": None if status != "STABLE" else limit,
            "policy": {"minimum_rounds": 7, "maximum_robust_relative_noise": .20, "maximum_relative_limit": .10, "noise_multiplier": 6, "relative_floor": .05},
            "baseline": summary}


def classify(reference: dict, candidate: dict, environment_matches: bool = True) -> dict:
    if candidate["unexpected_failures"] or candidate.get("unexpected_failure_rate", 0):
        return {"status": "FAIL", "reason": "unexpected native failures"}
    if not environment_matches or candidate["contract"] != reference["baseline"]["contract"]:
        return {"status": "INCONCLUSIVE", "reason": "environment or equivalent-work contract differs"}
    if reference["status"] != "STABLE":
        return {"status": reference["status"], "reason": "baseline cannot support a stable performance gate"}
    if candidate["rounds"] < 7:
        return {"status": "INCONCLUSIVE", "reason": "insufficient measured rounds"}
    if max(.05, 6 * max(candidate["robust_relative_noise"].values())) > .10:
        return {"status": "NOISY", "reason": "candidate dispersion exceeds the frozen noise ceiling"}
    baseline = reference["baseline"]
    changes = {"p95": candidate["p95_ns"] / baseline["p95_ns"] - 1,
               "p99": candidate["p99_ns"] / baseline["p99_ns"] - 1}
    if baseline["successful_operations_per_second"] > 0:
        changes["throughput_loss"] = 1 - candidate["successful_operations_per_second"] / baseline["successful_operations_per_second"]
    failed = any(value > reference["relative_regression_limit"] for value in changes.values())
    return {"status": "FAIL" if failed else "PASS", "relative_changes": changes,
            "relative_regression_limit": reference["relative_regression_limit"]}


def paired_by_round(left: list[dict], right: list[dict]) -> list[tuple[dict, dict]] | None:
    """Pair two cohorts on their recorded round, never on serialized position."""
    if len(left) != len(right):
        return None
    if not any("round" in row for row in left + right):
        return list(zip(left, right))
    by_round = {}
    for row in right:
        if "round" not in row or row["round"] in by_round:
            return None
        by_round[row["round"]] = row
    pairs = []
    for row in left:
        if row.get("round") not in by_round:
            return None
        pairs.append((row, by_round[row["round"]]))
    return sorted(pairs, key=lambda pair: pair[0]["round"])


def evaluate_read_buffer(before: list[dict], after: list[dict]) -> dict:
    left, right = summarize(before), summarize(after)
    pairs = paired_by_round(before, after)
    if left["contract"] != right["contract"] or pairs is None:
        return {"decision": "REJECTED", "reason": "non-equivalent workload"}
    ratios = [a["duration_ns"] / b["duration_ns"] for a, b in pairs]
    gains = [ratio - 1 for ratio in ratios]
    positive = sum(gain > 0 for gain in gains)
    # Exact two-sided sign test on independent paired rounds, excluding exact ties.
    signs = [gain for gain in gains if gain != 0]
    n = len(signs)
    smaller = min(sum(gain > 0 for gain in signs), sum(gain < 0 for gain in signs))
    p_value = min(1.0, 2 * sum(math.comb(n, k) for k in range(smaller + 1)) / 2**n) if n else 1.0
    median_gain = statistics.median(gains)
    before_calls = [r["metrics"].get("body_read_calls") for r in before]
    after_calls = [r["metrics"].get("body_read_calls") for r in after]
    measured_calls = all(type(value) is int and value > 0 for value in before_calls + after_calls)
    tail_ok = right["p95_ns"] <= left["p95_ns"] * 1.10 and right["p99_ns"] <= left["p99_ns"] * 1.10
    noisy = max(*left["robust_relative_noise"].values(), *right["robust_relative_noise"].values()) > .20
    supported = (n >= 7 and p_value <= .05 and median_gain >= .05 and tail_ok and not noisy
                 and measured_calls and statistics.median(after_calls) < statistics.median(before_calls))
    return {"decision": "SUPPORTED_CALLER_CONFIGURATION" if supported else "REJECTED",
            "reason": "Equivalent native bytes, measured fewer body reads, repeatable gain and preserved tails" if supported else
                      "No reliable equivalent-work improvement with preserved tails; no production optimization or API added",
            "paired_rounds": n, "positive_rounds": positive, "paired_speedup_ratios": ratios,
            "median_speedup_fraction": median_gain, "two_sided_sign_test_p": p_value,
            "tail_within_10_percent": tail_ok, "noisy": noisy,
            "body_read_calls_before": before_calls, "body_read_calls_after": after_calls,
            "allocations_reduced": None, "copied_bytes_reduced": None,
            "unavailable_reason": "Fewer public read invocations does not prove fewer managed allocations or internal copies.",
            "P1-001_vectored_io": "DEFERRED: no measured copy bottleneck or supported native vectored SPI demonstrated."}


class Campaign:
    def __init__(self, output: Path, work: Path):
        self.output, self.work = output.resolve(), work.resolve()
        self.output.mkdir(parents=True, exist_ok=True)
        self.work.mkdir(mode=0o700, parents=True, exist_ok=True)
        if subprocess.check_output(["findmnt", "-n", "-o", "FSTYPE", "-T", str(self.work)], text=True).strip() == "tmpfs":
            raise ValueError("scratch must be disk-backed")
        if shutil.disk_usage(self.work).free < 2 * 1024**3:
            raise ValueError("scratch requires at least 2 GiB free")
        self.env = dict(os.environ, TMPDIR=str(self.work), TMP=str(self.work), TEMP=str(self.work))
        self.commands = []
        self.counter = 0
        self._binary_digests = {}

    def binary_digest(self, binary: Path) -> dict:
        """Digest of the exact executable a sample executed; compiled once per campaign."""
        key = str(binary)
        if key not in self._binary_digests:
            self._binary_digests[key] = artifact_byte_digest(binary).to_json()
        return self._binary_digests[key]

    def redact(self, text: str) -> str:
        replacements = [(str(self.work), "<scratch>"), (str(ROOT), "<repo>"),
                        (os.environ.get("CANGJIE_HOME", ""), "<sdk>"), (str(Path.home()), "$HOME")]
        for old, new in sorted(replacements, key=lambda pair: -len(pair[0])):
            if old:
                text = text.replace(old, new)
        return text.replace("127.0.0.1", "192.0.2.1").replace("[::1]", "[2001:db8::1]")

    def run(self, name: str, argv: list[str], cwd: Path, timeout: int = 90, sampled: bool = False,
            check: bool = True) -> tuple[str, dict]:
        self.counter += 1
        stem = f"{self.counter:04d}-{name}"
        raw_out, raw_err = self.work / f"{stem}.out", self.work / f"{stem}.err"
        samples, stop = [], threading.Event()
        timed_out = False
        started = time.monotonic_ns()
        with raw_out.open("wb") as stdout, raw_err.open("wb") as stderr:
            process = subprocess.Popen(argv, cwd=cwd, env=self.env, stdout=stdout, stderr=stderr, start_new_session=True)

            def monitor():
                proc = Path("/proc") / str(process.pid)
                while not stop.is_set():
                    try:
                        status = (proc / "status").read_text()
                        rss = re.search(r"^VmRSS:\s+(\d+)", status, re.MULTILINE)
                        threads = re.search(r"^Threads:\s+(\d+)", status, re.MULTILINE)
                        if rss and threads:
                            samples.append({"elapsed_ns": time.monotonic_ns() - started, "rss_kib": int(rss[1]),
                                            "threads": int(threads[1]), "fds": len(list((proc / "fd").iterdir()))})
                    except (FileNotFoundError, ProcessLookupError, PermissionError):
                        pass
                    stop.wait(.02)
            thread = threading.Thread(target=monitor, daemon=True) if sampled else None
            if thread:
                thread.start()
            try:
                code = process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                timed_out = True
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    code = process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    code = process.wait(timeout=5)
            finally:
                stop.set()
                if thread:
                    thread.join(2)
        logs = {}
        for kind, source in (("stdout", raw_out), ("stderr", raw_err)):
            dest = self.output / f"{stem}.{kind}.log"
            with source.open(errors="replace") as incoming, dest.open("w") as outgoing:
                for line in incoming:
                    outgoing.write(self.redact(line))
            logs[kind] = {"path": str(dest.relative_to(ROOT)) if dest.is_relative_to(ROOT) else dest.name,
                          "digest": text_evidence_digest(dest).to_json()}
        record = {"id": stem, "argv": [self.redact(v) for v in argv], "cwd": self.redact(str(cwd)),
                  "exit_code": code, "timed_out": timed_out, "wall_ns": time.monotonic_ns() - started,
                  "process_samples": samples, **logs}
        self.commands.append(record)
        text = (self.output / f"{stem}.stdout.log").read_text()
        if check and (code != 0 or timed_out):
            raise RuntimeError(f"{stem} failed ({code}, timeout={timed_out}); complete logs retained")
        return text, record

    def build(self) -> tuple[dict, dict]:
        payload, manifest = release.collect_payload(ROOT)
        archive = self.work / "wirestack-current.tar.gz"
        release.write_reproducible_archive(archive, payload)
        installed = release.extract_archive(archive, self.work / "install")
        sources = {str(p.relative_to(ROOT)): artifact_byte_digest(p).to_json() for p in release.production_sources(ROOT)}
        prior_path = ROOT / "docs/evidence/M11-004/installed-sdk113/report.json"
        prior = json.loads(prior_path.read_text())
        if prior["status"] != "PASS" or prior["production_sources"] != sources:
            raise ValueError("source differs from the development-accepted installed baseline")
        if not artifact_byte_sha256_equal(artifact_byte_digest(archive).to_json(), prior["archive_digest"]) or not schema_artifact_sha256_equal(manifest["payload_sha256"], prior["payload_sha256"]):
            raise ValueError("reconstructed baseline is not the exact previously accepted artifact")
        retained_archive = self.output / "wirestack-baseline.tar.gz"
        shutil.copy2(archive, retained_archive)
        flags = "-O2 -g"
        dep_manifest = installed / "cjpm.toml"
        # Build derivative only: the retained reproducible archive is unchanged.
        dep_manifest.write_text(dep_manifest.read_text().replace('  compile-option = ""', f'  compile-option = "{flags}"', 1))
        identity = {"archive_digest": artifact_byte_digest(archive).to_json(), "payload_sha256": manifest["payload_sha256"],
                    "production_sources": sources, "compile_flags": flags,
                    "prior_development_acceptance": {"path": str(prior_path.relative_to(ROOT)), "digest": text_evidence_digest(prior_path).to_json(),
                                                     "checks": prior["pass_check_count"], "release_qualification": "NOT_QUALIFIED"},
                    "probe_sources": {str(p.relative_to(ROOT)): text_evidence_digest(p).to_json() for p in sorted(SOURCES.glob("*.cj"))},
                    "task_source_digests": task_source_digests()}
        binaries = {}
        for layer in CASES:
            consumer = self.work / layer
            (consumer / "src").mkdir(parents=True)
            manifest_text = release.consumer_manifest(installed).replace("wirestack_release_smoke", "wirestack_m12_001")
            (consumer / "cjpm.toml").write_text(manifest_text.replace('  compile-option = ""', f'  compile-option = "{flags}"', 1))
            shutil.copy2(SOURCES / "common.cj", consumer / "src/common.cj")
            shutil.copy2(SOURCES / f"{layer}.cj", consumer / "src/main.cj")
            self.run(f"{layer}-build", ["cjpm", "build"], consumer, timeout=600)
            binary = consumer / BINARY_RELATIVE_PATH
            dynamic, _ = self.run(f"{layer}-needed", ["readelf", "-d", str(binary)], consumer)
            needed = sorted(re.findall(r"\(NEEDED\).*?\[(.*?)\]", dynamic))
            if any(re.search(r"lib(?:ssl|crypto|z[.-]|zstd|brotli|bz2|lzma)", item) for item in needed):
                raise ValueError("native probe introduced an undeclared system TLS/compression library")
            binaries[layer] = binary
            # Provider identity is observed from this executable, never typed into the runner.
            provider = self.measure_tls_provider(layer, binary)
            identity[layer] = {"binary_digest": self.binary_digest(binary),
                               "command_path": self.redact(str(binary)),
                               "dynamic_dependencies": needed, "tls_provider": provider}
        providers = {json.dumps(identity[layer]["tls_provider"], sort_keys=True) for layer in CASES}
        if len(providers) != 1:
            raise ValueError("measured native binaries do not share one TLS provider identity")
        return binaries, identity

    def measure_tls_provider(self, layer: str, binary: Path) -> dict:
        text, _ = self.run(f"{layer}-tls-identity", [str(binary), "tls-identity"], binary.parent)
        markers = [line for line in text.splitlines() if line.startswith(TLS_IDENTITY_PREFIX)]
        if len(markers) != 1:
            raise ValueError("measured binary did not report exactly one TLS provider identity")
        return tls_identity_record(markers[0])

    def certificates(self):
        self.run("certificate", ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "2",
                 "-subj", "/CN=example.test", "-addext", "subjectAltName=DNS:example.test,IP:127.0.0.1",
                 "-keyout", str(self.work / "key.pem"), "-out", str(self.work / "certificate.pem")], self.work)
        self.run("certificate-der", ["openssl", "x509", "-in", str(self.work / "certificate.pem"), "-outform", "DER", "-out", str(self.work / "certificate.der")], self.work)
        self.run("key-der", ["openssl", "pkcs8", "-topk8", "-nocrypt", "-in", str(self.work / "key.pem"), "-outform", "DER", "-out", str(self.work / "key.pk8")], self.work)

    def environment(self) -> dict:
        result = dict(ENVIRONMENT_DECLARATIONS)
        witness, uname = {}, ""
        for name, argv in ENVIRONMENT_COMMANDS:
            text, _ = self.run(name, argv, ROOT)
            if name == "environment":
                witness = json.loads(text)
            elif name == "cpu":
                result["cpu"] = json.loads(text)
            elif name == "uname":
                uname = text.strip()
            else:
                result[name] = text.strip()
        result["kernel"] = kernel_from_uname(uname)
        result.update({key: witness[key] for key in
                       ("platform", "compiler_digest", "runtime_binaries", "runtime_environment")})
        return result

    def capture(self, repeats: int, warmups: int, profile: bool) -> dict:
        report = {"schema_version": 2, "task_id": "M12-001", "status": "INCOMPLETE", "release_qualification": "NOT_QUALIFIED",
                  "candidate_committed": False, "samples": [], "commands": self.commands,
                  "workload_counts": WORKLOAD_COUNTS, "scenario_contracts": scenario_contracts(),
                  "warmup_process_rounds": warmups, "measured_process_rounds": repeats,
                  "unavailable_costs": {key: {"value": None, "reason": reason} for key, reason in UNKNOWN_COSTS.items()}}
        report_path = self.output / "report.json"
        try:
            report["environment"] = self.environment()
            binaries, report["artifact"] = self.build()
            report["tls_provider"] = report["artifact"][next(iter(CASES))]["tls_provider"]
            report["environment"]["tls_provider"] = dict(report["tls_provider"])
            self.certificates()
            order = [(layer, case) for layer, cases in CASES.items() for case in cases]
            for warmup in range(warmups):
                for layer, case in order:
                    self.sample(report, binaries[layer], layer, case, warmup, True)
            for round_number in range(repeats):
                # Balanced order prevents a fixed before/after thermal/startup advantage.
                ordered = order if round_number % 2 == 0 else list(reversed(order))
                for layer, case in ordered:
                    self.sample(report, binaries[layer], layer, case, round_number, False)
                report_path.write_text(json.dumps(report, indent=2) + "\n")
            measured = defaultdict(list)
            for sample in report["samples"]:
                if not sample["warmup"]:
                    measured[sample["scenario"]].append(sample)
            report["summary"] = {case: summarize(rows) for case, rows in measured.items()}
            report["reference"] = {case: freeze_reference(summary) for case, summary in report["summary"].items()}
            report["read_buffer_candidate"] = evaluate_read_buffer(measured["h1_bulk_4096"], measured["h1_bulk_32768"])
            report["profile"] = self.profile(binaries["http"]) if profile else {"status": "NOT_RUN", "reason": "explicitly disabled"}
            after = {str(p.relative_to(ROOT)): artifact_byte_digest(p).to_json() for p in release.production_sources(ROOT)}
            if after != report["artifact"]["production_sources"]:
                raise ValueError("production source changed during campaign")
            if task_source_digests() != report["artifact"]["task_source_digests"]:
                raise ValueError("benchmark runner, tests, task contract or documentation changed during campaign")
            report["status"] = "PASS"
        except Exception as error:
            report["error"] = self.redact(f"{type(error).__name__}: {error}")
        finally:
            report_path.write_text(json.dumps(report, indent=2) + "\n")
        return report

    def sample(self, report, binary, layer, case, round_number, warmup):
        text, command = self.run(f"{case}-{'warmup' if warmup else 'round'}-{round_number}",
                                 workload_arguments(binary, case, self.work), binary.parent,
                                 sampled=True)
        lines = [line for line in text.splitlines() if line.strip()]
        if len(lines) != 1 or not lines[0].startswith('{"scenario":'):
            raise ValueError(f"{case} did not emit exactly one native sample")
        row = json.loads(lines[0])
        validate_sample(row, NATIVE_SCENARIOS.get(case, case))
        row["native_scenario"] = row["scenario"]
        row["scenario"] = case
        row.update(layer=layer, round=round_number, warmup=warmup, command_id=command["id"],
                   binary_digest=self.binary_digest(binary),
                   process_peak_rss_kib=max((s["rss_kib"] for s in command["process_samples"]), default=None),
                   process_peak_fds=max((s["fds"] for s in command["process_samples"]), default=None),
                   process_peak_threads=max((s["threads"] for s in command["process_samples"]), default=None))
        report["samples"].append(row)
        print(f"NATIVE_SAMPLE {case} round={round_number} warmup={warmup} operations={row['operations']} failures={row['failures']}", flush=True)

    def profile(self, binary: Path) -> dict:
        profiler = shutil.which("cjprof")
        if profiler is None:
            return {"status": "UNAVAILABLE", "reason": "optional cjprof executable is not installed"}
        destination = self.work / "native-http-cpu.data"
        try:
            text, command = self.run("native-http-cpu-profile", [profiler, "record", "-f", "199", "-o", str(destination), "--",
                              str(binary), "h1_bulk_4096", str(self.work / "certificate.der"), str(self.work / "key.pk8")], binary.parent, check=False)
        except OSError as error:
            return {"status": "UNAVAILABLE", "reason": f"optional cjprof could not be launched: {type(error).__name__}: {error}"}
        if command["exit_code"] != 0 or command["timed_out"] or not destination.is_file():
            return {"status": "UNAVAILABLE", "command": command["id"], "reason": "Profiler execution did not produce a valid sample file; raw failure retained"}
        _, view = self.run("native-http-cpu-report", [profiler, "report", "-i", str(destination)], binary.parent, check=False)
        return {"status": "CAPTURED" if view["exit_code"] == 0 else "CAPTURED_REPORT_UNAVAILABLE",
                "record_command": command["id"], "report_command": view["id"],
                "data_digest": artifact_byte_digest(destination).to_json(),
                "interpretation": "Sampled CPU residency, not wall-stage duration, allocation count, copied bytes or mutex wait."}


def cpu_identity(env: dict) -> dict:
    """CPU scaling frequency varies by design; architecture/model/topology must match."""
    cpu = env.get("cpu")
    rows = cpu.get("lscpu") if isinstance(cpu, dict) else None
    if not isinstance(rows, list) or any(not isinstance(item, dict) for item in rows):
        raise ValueError("environment is missing structured CPU metadata")
    return {item.get("field"): item.get("data") for item in rows if item.get("field") in CPU_IDENTITY_FIELDS}


def environment_equal(left: dict, right: dict) -> bool:
    if not all(isinstance(env, dict) for env in (left, right)):
        raise TypeError("environment identity must be a mapping")
    return (all(left.get(key) == right.get(key) for key in ENVIRONMENT_IDENTITY_KEYS)
            and cpu_identity(left) == cpu_identity(right))


def kernel_from_uname(text: str) -> str:
    fields = text.split()
    if len(fields) != 3 or fields[0] != "Linux":
        raise ValueError("retained uname output does not identify a Linux release")
    return fields[1]


def environment_from_metadata(texts: dict[str, str]) -> dict:
    """Reconstruct the environment identity from its own retained command output."""
    witness = json.loads(texts["environment"])
    if not isinstance(witness, dict):
        raise ValueError("environment witness output is not an object")
    for key in ("platform", "compiler_digest", "runtime_binaries", "runtime_environment"):
        if key not in witness:
            raise ValueError(f"environment witness omitted {key}")
    return {"platform": witness["platform"], "kernel": kernel_from_uname(texts["uname"]),
            "cjc": texts["cjc"].strip(), "cjpm": texts["cjpm"].strip(),
            "cpu": json.loads(texts["cpu"]), "compiler_digest": witness["compiler_digest"],
            "runtime_binaries": witness["runtime_binaries"],
            "runtime_environment": witness["runtime_environment"], **ENVIRONMENT_DECLARATIONS}


def command_record(commands: dict, name: str) -> dict:
    matches = [record for key, record in commands.items() if key.endswith("-" + name)]
    if len(matches) != 1:
        raise ValueError(f"retained metadata command {name} is not present exactly once")
    return matches[0]


def command_stdout(base: Path, command: dict) -> str:
    record = command.get("stdout")
    if not isinstance(record, dict) or not isinstance(record.get("path"), str):
        raise ValueError("retained command has no stdout log")
    log = base / Path(record["path"]).name
    if not log.is_file() or text_evidence_digest(log).to_json() != record.get("digest"):
        raise ValueError("native stdout digest mismatch")
    return log.read_text()


def validate_environment(report: dict, base: Path) -> None:
    """The environment block is accepted only when its retained commands reproduce it."""
    environment = report.get("environment")
    if not isinstance(environment, dict):
        raise ValueError("retained report has no environment block")
    commands = {item["id"]: item for item in report.get("commands", [])
                if isinstance(item, dict) and isinstance(item.get("id"), str)}
    texts = {}
    for name, argv in ENVIRONMENT_COMMANDS:
        record = command_record(commands, name)
        if record.get("argv") != argv:
            raise ValueError(f"retained metadata command {name} was not the declared probe")
        if record.get("exit_code") != 0 or record.get("timed_out"):
            raise ValueError(f"retained metadata command {name} did not succeed")
        texts[name] = command_stdout(base, record)
    reconstructed = environment_from_metadata(texts)
    if set(environment) != set(reconstructed) | {"tls_provider"}:
        raise ValueError("environment identity is not backed by the retained metadata commands")
    for key, value in reconstructed.items():
        if environment.get(key) != value:
            raise ValueError(f"environment {key} is not backed by the retained metadata commands")
    cpu_identity(environment)


def tls_identity_record(line: str) -> dict:
    if not line.startswith(TLS_IDENTITY_PREFIX):
        raise ValueError("measured binary did not report a TLS provider identity")
    record = json.loads(line[len(TLS_IDENTITY_PREFIX):])
    required = {"provider", "version", "build_fingerprint", "target_triple",
                "external_openssl", "trust_backend"}
    if not isinstance(record, dict) or set(record) != required:
        raise ValueError("TLS provider identity record has an unexpected shape")
    if (any(not isinstance(record[key], str) or not record[key]
            for key in ("provider", "version", "build_fingerprint", "target_triple", "trust_backend"))
            or record["external_openssl"] is not False):
        raise ValueError("TLS provider identity is incomplete or depends on system OpenSSL")
    return record


def validate_tls_providers(report: dict, base: Path) -> None:
    """The compared provider identity is the one measured binaries actually reported."""
    identity = report.get("tls_provider")
    if not isinstance(identity, dict) or set(identity) != {
            "provider", "version", "build_fingerprint", "target_triple", "external_openssl", "trust_backend"}:
        raise ValueError("retained report does not record a measured TLS provider identity")
    if report.get("environment", {}).get("tls_provider") != identity:
        raise ValueError("environment TLS identity differs from the measured provider identity")
    commands = {item["id"]: item for item in report.get("commands", [])
                if isinstance(item, dict) and isinstance(item.get("id"), str)}
    artifact = report.get("artifact")
    if not isinstance(artifact, dict):
        raise ValueError("retained report does not bind the measured artifacts")
    for layer in CASES:
        binding = artifact.get(layer)
        if not isinstance(binding, dict) or binding.get("tls_provider") != identity:
            raise ValueError("measured layer artifact does not record the compared TLS provider identity")
        record = commands.get(f"{layer}-tls-identity")
        if record is None:
            raise ValueError("retained report has no measured TLS provider command")
        if record.get("argv") != [binding.get("command_path"), "tls-identity"]:
            raise ValueError("TLS identity was not read from the recorded layer binary")
        if record.get("exit_code") != 0 or record.get("timed_out"):
            raise ValueError("TLS identity probe did not complete")
        lines = [line for line in command_stdout(base, record).splitlines() if line.strip()]
        if len(lines) != 1 or tls_identity_record(lines[0]) != identity:
            raise ValueError("layer binary reported a different TLS provider identity")


def derived_process_peaks(command: dict) -> dict:
    samples = command.get("process_samples")
    if not isinstance(samples, list):
        raise ValueError("retained command has no process samples")
    for sample in samples:
        if (not isinstance(sample, dict)
                or any(type(sample.get(key)) is not int or sample[key] < 0
                       for key in PROCESS_PEAK_KEYS)):
            raise ValueError("retained process sample is malformed")
    return {reported: max((sample[source] for sample in samples), default=None)
            for source, reported in PROCESS_PEAK_KEYS.items()}


def validate_workload_sample(row: dict, command: dict) -> None:
    """Every scenario's work must match its declared operation/success/rejection contract."""
    contract = SCENARIO_CONTRACTS.get(row["scenario"])
    if contract is None:
        raise ValueError("scenario has no declared workload contract")
    operations, rejections, regime = contract
    args = command.get("argv")
    native = NATIVE_SCENARIOS.get(row["scenario"], row["scenario"])
    if not isinstance(args, list) or len(args) < 2 or args[1] != native:
        raise ValueError("native command does not match the scenario")
    if row["scenario"] in WORKLOAD_COUNTS:
        expected = ["certificate.der", "key.pk8", str(WORKLOAD_COUNTS[row["scenario"]])]
    elif row["scenario"] in OBSERVATION_MODES:
        expected = ["certificate.der", "key.pk8", OBSERVATION_MODES[row["scenario"]]]
    else:
        expected = ["certificate.der", "key.pk8"]
    actual = args[2:]
    if (len(actual) != len(expected)
            or any(Path(value).name != Path(want).name for value, want in zip(actual, expected))):
        raise ValueError("native command did not run the configured workload count")
    if row.get("operations") != operations or row.get("expected_rejections") != rejections:
        raise ValueError("native sample did not execute the configured workload count")
    if row.get("successes") != operations - rejections or row.get("regime") != regime:
        raise ValueError("native sample outcome contract differs from the declared workload")
    if row["scenario"] in OBSERVATION_MODES:
        observed = row["metrics"].get("observation_enabled")
        if type(observed) is not bool or observed != (row["scenario"] == "http_observed"):
            raise ValueError("observer scenario did not run in its declared observation mode")


def canonical_execution_identity(native: dict) -> str:
    """Identity of one validated native record; log padding cannot manufacture a new execution."""
    return text_evidence_digest_bytes(
        json.dumps(native, sort_keys=True, separators=(",", ":")).encode()).sha256


def selected_execution_digests(report: dict, rounds: list[int]) -> set[str]:
    """Canonical native-record identities of the measured executions in the selected rounds."""
    selected = set(rounds)
    rows = [row for row in report["samples"] if not row["warmup"] and row["round"] in selected]
    if any("execution_identity" not in row for row in rows):
        raise ValueError("execution identity must come from a verified report")
    return {row["execution_identity"] for row in rows}


def recomputed_read_buffer_candidate(measured: dict) -> dict:
    return evaluate_read_buffer(measured["h1_bulk_4096"], measured["h1_bulk_32768"])


def load_verified_report(path: Path) -> dict:
    report = json.loads(path.read_text())
    base = path.parent
    if report.get("status") != "PASS":
        raise ValueError("native capture did not complete successfully")
    if report.get("schema_version") != SCHEMA_VERSION:
        raise ValueError("retained report does not carry the bound-evidence schema")
    if report.get("workload_counts") != WORKLOAD_COUNTS:
        raise ValueError("declared workload counts differ from the configured workload")
    contracts = scenario_contracts()
    if report.get("scenario_contracts") != contracts:
        raise ValueError("declared scenario work contracts differ from the configured workloads")
    validate_environment(report, base)
    validate_tls_providers(report, base)
    artifact = report["artifact"]
    commands = {item["id"]: item for item in report["commands"]}
    if len(commands) != len(report["commands"]):
        raise ValueError("duplicate command identity")
    measured = defaultdict(list)
    warmups = defaultdict(set)
    identities = set()
    executions = set()
    used_commands = set()
    for row in report["samples"]:
        scenario = row["scenario"]
        native_case = NATIVE_SCENARIOS.get(scenario, scenario)
        if row.get("native_scenario") != native_case:
            raise ValueError("native command does not match the scenario")
        validate_sample({**row, "scenario": native_case}, native_case)
        identity = (scenario, row["warmup"], row["round"])
        if identity in identities or scenario not in CASES["transport_tls"] + CASES["http"] + CASES["streams"]:
            raise ValueError("duplicate or unknown native workload")
        identities.add(identity)
        command = commands.get(row["command_id"])
        if command is None:
            raise ValueError("reported sample has no retained command")
        if row["command_id"] in used_commands:
            raise ValueError("independent rounds reused a native command")
        used_commands.add(row["command_id"])
        layer = row["layer"]
        if scenario not in CASES.get(layer, ()):
            raise ValueError("native sample is attributed to the wrong layer")
        binding = artifact.get(layer)
        if not isinstance(binding, dict):
            raise ValueError("native sample is not bound to a recorded layer artifact")
        if row["native_scenario"] != native_case or command["argv"][:1] != [binding.get("command_path")]:
            raise ValueError("sample was not produced by the recorded layer binary")
        if row.get("binary_digest") != binding.get("binary_digest"):
            raise ValueError("sample binary digest differs from the recorded layer artifact")
        validate_workload_sample(row, command)
        if command["exit_code"] != 0 or command["timed_out"]:
            raise ValueError("failed native command cannot support a performance result")
        text = command_stdout(base, command)
        if len(text.splitlines()) != 1:
            raise ValueError("native command emitted output beyond its single sample record")
        native = json.loads(text)
        if native.get("scenario") != row["native_scenario"] or any(
                row.get(key) != value for key, value in native.items() if key != "scenario"):
            raise ValueError("reported measurements differ from raw native output")
        peaks = derived_process_peaks(command)
        if any(row.get(key) != value for key, value in peaks.items()):
            raise ValueError("derived process peaks differ from the retained process samples")
        execution = canonical_execution_identity(native)
        if execution in executions:
            raise ValueError("one raw execution was reported as independent rounds")
        executions.add(execution)
        row["execution_identity"] = execution
        if row["warmup"]:
            warmups[scenario].add(row["round"])
        else:
            measured[scenario].append(row)
    expected = set(contracts)
    if set(measured) != expected:
        raise ValueError("incomplete native layer/feature coverage")
    count = report["measured_process_rounds"]
    if type(count) is not int or count < 7 or any({r["round"] for r in rows} != set(range(count)) for rows in measured.values()):
        raise ValueError("incomplete independent measured rounds")
    warmup_count = report["warmup_process_rounds"]
    if type(warmup_count) is not int or not 1 <= warmup_count <= 8:
        raise ValueError("declared process warmup rounds are outside the supported range")
    for case in expected:
        if warmups.get(case) != set(range(warmup_count)):
            raise ValueError("declared process warmup rounds are incomplete")
    summaries = {case: summarize(sorted(rows, key=lambda r: r["round"])) for case, rows in measured.items()}
    if summaries != report["summary"] or {case: freeze_reference(summary) for case, summary in summaries.items()} != report["reference"]:
        raise ValueError("summary or frozen threshold differs from raw measurements")
    if recomputed_read_buffer_candidate(measured) != report.get("read_buffer_candidate"):
        raise ValueError("read-buffer candidate decision differs from raw measurements")
    return report



def selected_round_summaries(report: dict, selection: str | None) -> tuple[dict, list[int]]:
    count = report["measured_process_rounds"]
    start, stop = (0, count) if selection is None else tuple(map(int, selection.split(":")))
    if not 0 <= start < stop <= count:
        raise ValueError("round selection must be START:STOP inside the measured campaign")
    rounds = list(range(start, stop))
    rows = defaultdict(list)
    for row in report["samples"]:
        if not row["warmup"] and row["round"] in rounds:
            rows[row["scenario"]].append(row)
    return {case: summarize(sorted(values, key=lambda r: r["round"])) for case, values in rows.items()}, rounds



def task_source_digests() -> dict:
    """Every benchmark source declared by the task contract, not only native probes or production files."""
    task = json.loads((ROOT / "tools/tasks/M12-001.json").read_text())
    return {relative: text_evidence_digest(ROOT / relative).to_json() for relative in task["source_paths"]}


def verify_task_sources(report: dict) -> None:
    actual = task_source_digests()
    expected = report.get("artifact", {}).get("task_source_digests")
    if not isinstance(expected, dict) or expected.keys() != actual.keys():
        raise ValueError("retained evidence does not bind the complete benchmark task source inventory")
    if expected != actual:
        raise ValueError("current benchmark runner, tests, task contract or documentation differs from measured native source")


def verify_baseline_archive(report: dict, archive: Path) -> None:
    expected = report['artifact']['archive_digest']
    if archive.exists():
        if not archive.is_file() or artifact_byte_digest(archive).to_json() != expected:
            raise ValueError('retained development baseline artifact differs')
        return
    try:
        payload, manifest = release.collect_payload(ROOT)
    except Exception as error:
        raise ValueError(f'exact baseline payload reconstruction is unavailable: {error}') from error
    if not schema_artifact_sha256_equal(manifest['payload_sha256'], report['artifact']['payload_sha256']):
        raise ValueError('reconstructed baseline payload differs from measured development artifact')
    with tempfile.TemporaryDirectory(prefix='wirestack-m12-001-verify-') as directory:
        reconstructed = Path(directory) / archive.name
        release.write_reproducible_archive(reconstructed, payload)
        if artifact_byte_digest(reconstructed).to_json() != expected:
            raise ValueError('reconstructed baseline artifact differs from measured development artifact')


def comparison_contract(report: dict) -> dict:
    """The complete evidence that two captures must share to be compared at all."""
    return {"probe_sources": report["artifact"]["probe_sources"],
            "task_source_digests": report["artifact"].get("task_source_digests"),
            "workload_counts": report["workload_counts"],
            "scenario_contracts": report["scenario_contracts"],
            "tls_provider": report["tls_provider"]}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    capture = sub.add_parser("capture")
    capture.add_argument("--output", type=Path, default=ROOT / "docs/evidence/M12-001/native")
    capture.add_argument("--scratch", type=Path, required=True, help="New task-owned disk-backed directory; never reused")
    capture.add_argument("--repeats", type=int, default=12)
    capture.add_argument("--warmups", type=int, default=2)
    capture.add_argument("--no-profile", action="store_true")
    compare = sub.add_parser("compare")
    compare.add_argument("--baseline", type=Path, required=True)
    compare.add_argument("--candidate", type=Path, required=True)
    compare.add_argument("--output", type=Path, required=True)
    compare.add_argument("--baseline-rounds", help="Optional START:STOP measured-round cohort")
    compare.add_argument("--candidate-rounds", help="Optional START:STOP measured-round cohort")
    verify = sub.add_parser("verify", help="Check retained raw measurements and current source binding; no benchmark rerun")
    verify.add_argument("--report", type=Path, default=ROOT / "docs/evidence/M12-001/native-final/report.json")
    # Internal capture probe: the retained metadata command that reconstructs machine identity.
    sub.add_parser("environment-witness", help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.command == "environment-witness":
        print(json.dumps(environment_witness(), sort_keys=True))
        return 0
    if args.command == "capture":
        if not 7 <= args.repeats <= 64 or not 1 <= args.warmups <= 8 or args.scratch.exists():
            parser.error("capture requires 7..64 measured rounds, 1..8 warmups and a new scratch directory")
        report = Campaign(args.output, args.scratch).capture(args.repeats, args.warmups, not args.no_profile)
        print("M12_001_NATIVE_" + report["status"])
        return 0 if report["status"] == "PASS" else 1
    if args.command == "verify":
        report = load_verified_report(args.report)
        source = {str(p.relative_to(ROOT)): artifact_byte_digest(p).to_json() for p in release.production_sources(ROOT)}
        probes = {str(p.relative_to(ROOT)): text_evidence_digest(p).to_json() for p in sorted(SOURCES.glob("*.cj"))}
        archive = args.report.parent / "wirestack-baseline.tar.gz"
        if source != report["artifact"]["production_sources"] or probes != report["artifact"]["probe_sources"]:
            raise ValueError("current production/probe source differs from measured native source")
        verify_task_sources(report)
        verify_baseline_archive(report, archive)
        print("M12_001_EVIDENCE_PASS")
        return 0
    # Every malformed or non-comparable input, including malformed environment/argv metadata,
    # must still produce the documented decision file rather than a traceback.
    try:
        baseline, candidate = (load_verified_report(path) for path in (args.baseline, args.candidate))
        baseline_summaries, baseline_rounds = selected_round_summaries(baseline, args.baseline_rounds)
        candidate_summaries, candidate_rounds = selected_round_summaries(candidate, args.candidate_rounds)
        if set(baseline_summaries) != set(candidate_summaries):
            raise ValueError("compared reports do not cover the same scenario inventory")
        if selected_execution_digests(baseline, baseline_rounds) & selected_execution_digests(candidate, candidate_rounds):
            raise ValueError("overlapping executions cannot be an independent performance comparison")
        if comparison_contract(baseline) != comparison_contract(candidate):
            matches = False
        else:
            matches = environment_equal(baseline["environment"], candidate["environment"])
        results = {case: classify(freeze_reference(baseline_summaries[case]), summary, matches)
                   for case, summary in candidate_summaries.items()}
    except (ValueError, KeyError, IndexError, OSError, TypeError, AttributeError) as error:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps({"status": "INCONCLUSIVE", "reason": str(error)}, indent=2) + "\n")
        print("M12_001_COMPARISON_INCONCLUSIVE")
        return 3
    status = "FAIL" if any(row["status"] == "FAIL" for row in results.values()) else "INCONCLUSIVE" if any(row["status"] == "INCONCLUSIVE" for row in results.values()) else "NOISY" if any(row["status"] == "NOISY" for row in results.values()) else "PASS"
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps({"status": status, "environment_matches": matches,
        "baseline_rounds": baseline_rounds, "candidate_rounds": candidate_rounds,
        "baseline_report_digest": text_evidence_digest(args.baseline).to_json(),
        "candidate_report_digest": text_evidence_digest(args.candidate).to_json(),
        "frozen_reference": {case: freeze_reference(summary) for case, summary in baseline_summaries.items()},
        "cases": results}, indent=2) + "\n")
    print("M12_001_COMPARISON_" + status)
    return {"PASS": 0, "FAIL": 1, "NOISY": 2, "INCONCLUSIVE": 3}[status]


if __name__ == "__main__":
    raise SystemExit(main())
