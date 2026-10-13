#!/usr/bin/env python3
"""Native end-to-end development baselines; never a release qualification seal."""
from __future__ import annotations

import argparse
from collections import defaultdict
import json
import math
import os
from pathlib import Path
import platform
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
# Fixed work per native operation; bulk exchanges are8MiB in each direction.
WORKLOAD_COUNTS = {"tcp_bulk": 8, "tcp_partial": 256, "tcp_cancel": 32, "udp_packets": 1024,
                   "tls_full": 32, "tls_resumed": 32, "tls_small": 256, "tls_bulk": 8,
                   "tls_failure": 16, "tls_close": 32}


def workload_arguments(binary: Path, scenario: str, work: Path) -> list[str]:
    native = "http_observed" if scenario == "http_unobserved" else scenario
    args = [str(binary), native, str(work / "certificate.der"), str(work / "key.pk8")]
    if scenario in WORKLOAD_COUNTS:
        args.append(str(WORKLOAD_COUNTS[scenario]))
    elif scenario == "http_unobserved":
        args.append("disabled")
    return args
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
            "contract": {key: rows[0][key] for key in ("operations", "successes", "expected_rejections", "bytes", "checksum")}}


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


def evaluate_read_buffer(before: list[dict], after: list[dict]) -> dict:
    left, right = summarize(before), summarize(after)
    if left["contract"] != right["contract"] or len(before) != len(after):
        return {"decision": "REJECTED", "reason": "non-equivalent workload"}
    ratios = [a["duration_ns"] / b["duration_ns"] for a, b in zip(before, after)]
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
                    "probe_sources": {str(p.relative_to(ROOT)): text_evidence_digest(p).to_json() for p in sorted(SOURCES.glob("*.cj"))}}
        binaries = {}
        for layer in CASES:
            consumer = self.work / layer
            (consumer / "src").mkdir(parents=True)
            manifest_text = release.consumer_manifest(installed).replace("wirestack_release_smoke", "wirestack_m12_001")
            (consumer / "cjpm.toml").write_text(manifest_text.replace('  compile-option = ""', f'  compile-option = "{flags}"', 1))
            shutil.copy2(SOURCES / "common.cj", consumer / "src/common.cj")
            shutil.copy2(SOURCES / f"{layer}.cj", consumer / "src/main.cj")
            self.run(f"{layer}-build", ["cjpm", "build"], consumer, timeout=600)
            binary = consumer / "target/release/bin/main"
            dynamic, _ = self.run(f"{layer}-needed", ["readelf", "-d", str(binary)], consumer)
            needed = sorted(re.findall(r"\(NEEDED\).*?\[(.*?)\]", dynamic))
            if any(re.search(r"lib(?:ssl|crypto|z[.-]|zstd|brotli|bz2|lzma)", item) for item in needed):
                raise ValueError("native probe introduced an undeclared system TLS/compression library")
            binaries[layer] = binary
            identity[layer] = {"binary_digest": artifact_byte_digest(binary).to_json(), "dynamic_dependencies": needed}
        return binaries, identity

    def certificates(self):
        self.run("certificate", ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "2",
                 "-subj", "/CN=example.test", "-addext", "subjectAltName=DNS:example.test,IP:127.0.0.1",
                 "-keyout", str(self.work / "key.pem"), "-out", str(self.work / "certificate.pem")], self.work)
        self.run("certificate-der", ["openssl", "x509", "-in", str(self.work / "certificate.pem"), "-outform", "DER", "-out", str(self.work / "certificate.der")], self.work)
        self.run("key-der", ["openssl", "pkcs8", "-topk8", "-nocrypt", "-in", str(self.work / "key.pem"), "-outform", "DER", "-out", str(self.work / "key.pk8")], self.work)

    def environment(self) -> dict:
        result = {"platform": release.platform_identity(), "kernel": platform.release(),
                  "network": "Native same-host loopback; no injected RTT/loss; both peers in one executable",
                  "optimization": "-O2 -g for dependency and consumer", "load": "One measured process at a time; case-specific bounded concurrency",
                  "reuse": "Case-defined: persistent transport/TLS and H1/H2 reuse versus explicit fresh connections",
                  "TLS": "Static AWS-LC5.5.0, pinned commit991e67ff4cf04df4dd89e407f8b920c6936cb56a; H1 HTTPcasesplaintext, H2 and SSE/WebSocketcases native custom-root TLS",
                  "runtime_environment": {key: self.redact(value) for key, value in os.environ.items() if key.startswith("CJ_")},
                  "resource_boundary": "Whole native workload process /proc RSS/threads/fds includes runtime and both peers; not Wirestack-exclusive memory"}
        for name, argv in (("cjc", ["cjc", "--version"]), ("cjpm", ["cjpm", "--version"]), ("cpu", ["lscpu", "-J"])):
            text, _ = self.run(name, argv, self.work)
            result[name] = json.loads(text) if name == "cpu" else text.strip()
        result["compiler_digest"] = artifact_byte_digest(Path(shutil.which("cjc"))).to_json()
        sdk = Path(os.environ["CANGJIE_HOME"])
        result["runtime_binaries"] = {p.name: artifact_byte_digest(p).to_json() for p in sorted((sdk / "runtime/lib/linux_x86_64_cjnative").glob("libcangjie*.so"))}
        return result

    def capture(self, repeats: int, warmups: int, profile: bool) -> dict:
        report = {"schema_version": 1, "task_id": "M12-001", "status": "INCOMPLETE", "release_qualification": "NOT_QUALIFIED",
                  "candidate_committed": False, "samples": [], "commands": self.commands,
                  "workload_counts": WORKLOAD_COUNTS, "warmup_process_rounds": warmups, "measured_process_rounds": repeats,
                  "unavailable_costs": {key: {"value": None, "reason": reason} for key, reason in UNKNOWN_COSTS.items()}}
        report_path = self.output / "report.json"
        try:
            report["environment"] = self.environment()
            binaries, report["artifact"] = self.build()
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
        lines = [line for line in text.splitlines() if line.startswith('{"scenario":')]
        if len(lines) != 1:
            raise ValueError(f"{case} did not emit exactly one native sample")
        row = json.loads(lines[0])
        validate_sample(row, "http_observed" if case == "http_unobserved" else case)
        row["native_scenario"] = row["scenario"]
        row["scenario"] = case
        row.update(layer=layer, round=round_number, warmup=warmup, command_id=command["id"],
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
        text, command = self.run("native-http-cpu-profile", [profiler, "record", "-f", "199", "-o", str(destination), "--",
                          str(binary), "h1_bulk_4096", str(self.work / "certificate.der"), str(self.work / "key.pk8")], binary.parent, check=False)
        if command["exit_code"] != 0 or command["timed_out"] or not destination.is_file():
            return {"status": "UNAVAILABLE", "command": command["id"], "reason": "Profiler execution did not produce a valid sample file; raw failure retained"}
        _, view = self.run("native-http-cpu-report", [profiler, "report", "-i", str(destination)], binary.parent, check=False)
        return {"status": "CAPTURED" if view["exit_code"] == 0 else "CAPTURED_REPORT_UNAVAILABLE",
                "record_command": command["id"], "report_command": view["id"],
                "data_digest": artifact_byte_digest(destination).to_json(),
                "interpretation": "Sampled CPU residency, not wall-stage duration, allocation count, copied bytes or mutex wait."}


def environment_equal(left: dict, right: dict) -> bool:
    keys = ("platform", "kernel", "cjc", "compiler_digest", "runtime_binaries", "optimization", "network", "runtime_environment")
    # CPU scaling frequency varies by design; architecture/model/topology must match.
    def cpu_identity(env):
        return {item["field"]: item["data"] for item in env["cpu"]["lscpu"] if item["field"] in
                {"Architecture:", "Model name:", "CPU(s):", "Thread(s) per core:", "Core(s) per socket:", "Socket(s):"}}
    return all(left.get(key) == right.get(key) for key in keys) and cpu_identity(left) == cpu_identity(right)

def load_verified_report(path: Path) -> dict:
    report = json.loads(path.read_text())
    if report.get("status") != "PASS":
        raise ValueError("native capture did not complete successfully")
    expected = {case for cases in CASES.values() for case in cases}
    commands = {item["id"]: item for item in report["commands"]}
    if len(commands) != len(report["commands"]):
        raise ValueError("duplicate command identity")
    measured = defaultdict(list)
    identities = set()
    used_commands = set()
    for row in report["samples"]:
        validate_sample(row, row["scenario"])
        identity = (row["scenario"], row["warmup"], row["round"])
        if identity in identities or row["scenario"] not in expected:
            raise ValueError("duplicate or unknown native workload")
        identities.add(identity)
        command = commands[row["command_id"]]
        if row["command_id"] in used_commands:
            raise ValueError("independent rounds reused a native command")
        used_commands.add(row["command_id"])
        native_case = "http_observed" if row["scenario"] == "http_unobserved" else row["scenario"]
        if row["native_scenario"] != native_case or command["argv"][1] != native_case:
            raise ValueError("native command does not match the scenario")
        if command["exit_code"] != 0 or command["timed_out"]:
            raise ValueError("failed native command cannot support a performance result")
        log = path.parent / Path(command["stdout"]["path"]).name
        if text_evidence_digest(log).to_json() != command["stdout"]["digest"]:
            raise ValueError("native stdout digest mismatch")
        lines = [line for line in log.read_text().splitlines() if line.startswith('{"scenario":')]
        if len(lines) != 1:
            raise ValueError("missing unique native JSON record")
        native = json.loads(lines[0])
        if native["scenario"] != row["native_scenario"] or any(row.get(key) != value for key, value in native.items() if key != "scenario"):
            raise ValueError("reported measurements differ from raw native output")
        if not row["warmup"]:
            measured[row["scenario"]].append(row)
    if set(measured) != expected:
        raise ValueError("incomplete native layer/feature coverage")
    count = report["measured_process_rounds"]
    if type(count) is not int or count < 7 or any({r["round"] for r in rows} != set(range(count)) for rows in measured.values()):
        raise ValueError("incomplete independent measured rounds")
    summaries = {case: summarize(sorted(rows, key=lambda r: r["round"])) for case, rows in measured.items()}
    if summaries != report["summary"] or {case: freeze_reference(summary) for case, summary in summaries.items()} != report["reference"]:
        raise ValueError("summary or frozen threshold differs from raw measurements")
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
    args = parser.parse_args()
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
        verify_baseline_archive(report, archive)
        print("M12_001_EVIDENCE_PASS")
        return 0
    try:
        baseline, candidate = (load_verified_report(path) for path in (args.baseline, args.candidate))
        baseline_summaries, baseline_rounds = selected_round_summaries(baseline, args.baseline_rounds)
        candidate_summaries, candidate_rounds = selected_round_summaries(candidate, args.candidate_rounds)
        if text_evidence_digest(args.baseline).to_json() == text_evidence_digest(args.candidate).to_json() and set(baseline_rounds) & set(candidate_rounds):
            raise ValueError("overlapping executions cannot be an independent performance comparison")
    except (ValueError, KeyError, OSError, TypeError) as error:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps({"status": "INCONCLUSIVE", "reason": str(error)}, indent=2) + "\n")
        print("M12_001_COMPARISON_INCONCLUSIVE")
        return 3
    if baseline["artifact"]["probe_sources"] != candidate["artifact"]["probe_sources"] or baseline["workload_counts"] != candidate["workload_counts"]:
        matches = False
    else:
        matches = environment_equal(baseline["environment"], candidate["environment"])
    results = {case: classify(freeze_reference(baseline_summaries[case]), summary, matches) for case, summary in candidate_summaries.items()}
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
