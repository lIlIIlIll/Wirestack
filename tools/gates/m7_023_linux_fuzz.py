#!/usr/bin/env python3
"""Run the native Linux M7-023 deterministic release fuzz gate."""
from __future__ import annotations

if __package__ in {None, ""}:
    import sys
    from pathlib import Path
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from tools import evidence_digest

import argparse
import datetime as dt
import json
import os
import platform
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any, Mapping, Sequence

SCHEMA_VERSION = 1
MAX_CAPTURE_BYTES = 4 * 1024 * 1024
EXPECTED_TARGETS = (
    "tls-record",
    "tls-handshake",
    "hostname-verifier",
    "certificate-adapter",
    "http1-parser",
    "chunked-decoder",
    "http2-frame",
    "hpack-decoder",
    "url-authority",
    "proxy-parser",
)
MARKER_RE = re.compile(
    r"^M7023_FUZZ target=(\S+) seed=(\d+) iterations=(\d+) decision=(PASS|FAIL)$",
    re.MULTILINE,
)
COMPILE_RE = re.compile(r'^(\s*compile-option\s*=\s*)"[^"]*"', re.MULTILINE)


class GateError(RuntimeError):
    pass


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def bounded(value: bytes) -> str:
    return value[-MAX_CAPTURE_BYTES:].decode("utf-8", errors="replace")


def terminate(process: subprocess.Popen[bytes]) -> None:
    if process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=2)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait(timeout=2)


def run(command: Sequence[str], cwd: Path, timeout: float,
        env: Mapping[str, str] | None = None) -> dict[str, Any]:
    started = time.monotonic()
    process = subprocess.Popen(
        list(command), cwd=cwd, env=env, stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, shell=False,
        start_new_session=True,
    )
    timed_out = False
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        timed_out = True
        terminate(process)
        stdout, stderr = process.communicate()
    return {
        "command": list(command),
        "exit_code": process.returncode,
        "timed_out": timed_out,
        "duration_ms": round((time.monotonic() - started) * 1000, 3),
        "stdout": bounded(stdout),
        "stderr": bounded(stderr),
    }


def checked_path(root: Path, relative: str) -> Path:
    candidate = (root / relative).resolve()
    try:
        candidate.relative_to(root.resolve())
    except ValueError as error:
        raise GateError(f"path escapes repository: {relative}") from error
    return candidate


def decode_hex_corpus(path: Path) -> str:
    if not path.is_file():
        raise GateError(f"corpus is missing: {path}")
    text = path.read_text(encoding="ascii")
    compact = "".join(text.split())
    if not compact or len(compact) % 2:
        raise GateError(f"corpus is empty or has odd hex length: {path}")
    try:
        bytes.fromhex(compact)
    except ValueError as error:
        raise GateError(f"corpus is not hexadecimal: {path}") from error
    return compact.lower()


def load_manifest(root: Path, manifest_path: Path) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise GateError(f"cannot load manifest: {error}") from error
    if manifest.get("schema_version") != SCHEMA_VERSION:
        raise GateError("unsupported manifest schema")
    if manifest.get("gate_id") != "M7-023-LINUX-FUZZ":
        raise GateError("unexpected gate id")
    if manifest.get("profile") != "linux_glibc_x86_64":
        raise GateError("unexpected platform profile")
    if manifest.get("seed") != 7023:
        raise GateError("unexpected deterministic seed")
    raw_targets = manifest.get("targets")
    if not isinstance(raw_targets, list):
        raise GateError("manifest targets must be an array")
    names = [item.get("name") for item in raw_targets if isinstance(item, dict)]
    if tuple(names) != EXPECTED_TARGETS:
        raise GateError("manifest must contain the ten PRD targets exactly once and in order")

    targets: list[dict[str, Any]] = []
    for item in raw_targets:
        name = item["name"]
        corpus_value = item.get("corpus")
        expected_digest = item.get("corpus_sha256")
        filter_value = item.get("filter")
        package = item.get("package")
        minimum = item.get("minimum_iterations")
        timeout = item.get("timeout_seconds")
        if not isinstance(corpus_value, str) or not isinstance(expected_digest, str):
            raise GateError(f"invalid corpus metadata: {name}")
        if not isinstance(filter_value, str) or not filter_value:
            raise GateError(f"invalid test filter: {name}")
        if not isinstance(package, str) or not re.fullmatch(r"wirestack(?:\.[a-z0-9_]+)+", package):
            raise GateError(f"invalid package: {name}")
        if not isinstance(minimum, int) or minimum <= 0:
            raise GateError(f"invalid iteration threshold: {name}")
        if not isinstance(timeout, int) or timeout <= 0 or timeout > 3600:
            raise GateError(f"invalid timeout: {name}")
        corpus = checked_path(root, corpus_value)
        compact = decode_hex_corpus(corpus)
        actual_digest = evidence_digest.text_evidence_sha256(corpus)
        if not evidence_digest.schema_text_sha256_equal(actual_digest, expected_digest):
            raise GateError(f"corpus digest mismatch: {name}")
        targets.append({
            **item,
            "corpus_path": corpus,
            "corpus_hex": compact,
            "actual_corpus_sha256": actual_digest,
        })
    return manifest, targets


def enable_o2(manifest: Path) -> None:
    text = manifest.read_text(encoding="utf-8")
    if len(COMPILE_RE.findall(text)) != 1:
        raise GateError("expected exactly one compile-option in cjpm.toml")
    manifest.write_text(COMPILE_RE.sub(r'\1"-O2"', text, count=1), encoding="utf-8")


def prepare_snapshot(root: Path, destination: Path) -> None:
    shutil.copytree(
        root,
        destination,
        ignore=shutil.ignore_patterns(
            ".git", ".cjpm", ".codex", "target", "__pycache__", "*.pyc"
        ),
    )
    native = root / "target/native"
    if not native.is_dir():
        raise GateError("native provider/resolver artifacts are missing under target/native")
    (destination / "target").mkdir()
    (destination / "target/native").symlink_to(native, target_is_directory=True)
    enable_o2(destination / "cjpm.toml")


def build_command() -> list[str]:
    return [
        "cjpm", "test",
        "src/internal/tls_engine", "src/internal/trust", "src/internal/http1",
        "src/internal/http2", "src/http", "-j", "1", "--no-run",
        "--no-progress", "--no-color",
    ]


def campaign_command(snapshot: Path, target: Mapping[str, Any]) -> list[str]:
    return [
        str(snapshot / "target/release/unittest_bin" / str(target["package"])),
        f"--filter={target['filter']}", "--show-all-output", "--no-progress", "--no-color",
    ]


def classify(target: Mapping[str, Any], seed: int,
             process: Mapping[str, Any]) -> tuple[str, list[str], dict[str, Any] | None]:
    reasons: list[str] = []
    if process.get("timed_out"):
        reasons.append("campaign timed out")
    if process.get("exit_code") != 0:
        reasons.append(f"campaign exited {process.get('exit_code')}")
    markers = MARKER_RE.findall(str(process.get("stdout", "")))
    marker: dict[str, Any] | None = None
    if len(markers) != 1:
        reasons.append(f"expected exactly one M7023_FUZZ marker, found {len(markers)}")
    else:
        name, marker_seed, iterations, marker_decision = markers[0]
        marker = {
            "target": name,
            "seed": int(marker_seed),
            "iterations": int(iterations),
            "decision": marker_decision,
        }
        if name != target["name"]:
            reasons.append(f"marker target mismatch: {name}")
        if int(marker_seed) != seed:
            reasons.append(f"marker seed mismatch: {marker_seed}")
        if int(iterations) < target["minimum_iterations"]:
            reasons.append(
                f"iterations {iterations} below threshold {target['minimum_iterations']}"
            )
        if marker_decision != "PASS":
            reasons.append(f"marker decision is {marker_decision}")
    return ("PASS" if not reasons else "FAIL", reasons, marker)


def replay_command(root: Path, artifact: Path, output: Path) -> list[str]:
    return [
        str(root / "scripts/gate-m7-023-linux-fuzz"),
        "--replay-crash", str(artifact), "--output", str(output),
    ]


def save_crash(root: Path, crash_dir: Path, target: Mapping[str, Any], seed: int,
               manifest_digest: str, reasons: Sequence[str],
               process: Mapping[str, Any], output: Path) -> Path:
    crash_dir.mkdir(parents=True, exist_ok=True)
    artifact = crash_dir / f"{target['name']}.json"
    payload = {
        "schema_version": SCHEMA_VERSION,
        "gate_id": "M7-023-LINUX-FUZZ",
        "created_at_utc": utc_now(),
        "target": target["name"],
        "seed": seed,
        "filter": target["filter"],
        "minimum_iterations": target["minimum_iterations"],
        "corpus": target["corpus"],
        "corpus_sha256": target["actual_corpus_sha256"],
        "manifest_sha256": manifest_digest,
        "reasons": list(reasons),
        "process": dict(process),
    }
    payload["replay_command"] = replay_command(root, artifact, output)
    artifact.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return artifact


def source_fingerprint(root: Path) -> str:
    paths: list[Path] = []
    for directory in (
        "src/internal/tls_engine", "src/internal/trust", "src/internal/http1",
        "src/internal/http2", "src/http",
    ):
        paths.extend((root / directory).glob("*.cj"))
    return evidence_digest.text_evidence_inventory_sha256(root, paths)


def version(command: Sequence[str], root: Path) -> str:
    result = run(command, root, 10)
    text = (result["stdout"] + result["stderr"]).strip()
    return text[:4096] if result["exit_code"] == 0 else f"UNAVAILABLE(exit={result['exit_code']})"


def execute_target(snapshot: Path, target: Mapping[str, Any], seed: int) -> dict[str, Any]:
    env = dict(os.environ)
    env.update({
        "WIRESTACK_M7_023_TARGET": str(target["name"]),
        "WIRESTACK_M7_023_CORPUS_HEX": str(target["corpus_hex"]),
    })
    process = run(campaign_command(snapshot, target), snapshot, float(target["timeout_seconds"]), env)
    decision, reasons, marker = classify(target, seed, process)
    return {
        "target": target["name"],
        "decision": decision,
        "seed": seed,
        "minimum_iterations": target["minimum_iterations"],
        "corpus": target["corpus"],
        "corpus_sha256": target["actual_corpus_sha256"],
        "marker": marker,
        "reasons": reasons,
        "process": process,
    }


def validate_replay(path: Path, manifest_digest: str,
                    targets: Sequence[Mapping[str, Any]]) -> Mapping[str, Any]:
    try:
        artifact = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise GateError(f"cannot load replay artifact: {error}") from error
    if artifact.get("schema_version") != SCHEMA_VERSION:
        raise GateError("unsupported replay schema")
    if artifact.get("gate_id") != "M7-023-LINUX-FUZZ":
        raise GateError("unexpected replay gate id")
    by_name = {target["name"]: target for target in targets}
    target = by_name.get(artifact.get("target"))
    if target is None:
        raise GateError("replay target is not in the checked-in manifest")
    expected = {
        "seed": 7023,
        "filter": target["filter"],
        "minimum_iterations": target["minimum_iterations"],
        "corpus": target["corpus"],
        "corpus_sha256": target["actual_corpus_sha256"],
        "manifest_sha256": manifest_digest,
    }
    for key, value in expected.items():
        if artifact.get(key) != value:
            raise GateError(f"replay coordinate mismatch: {key}")
    return target


def main(argv: Sequence[str] | None = None) -> int:
    root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--manifest", type=Path,
        default=root / "tools/gates/campaigns/m7-023-linux-fuzz.json",
    )
    parser.add_argument(
        "--output", type=Path,
        default=root / "docs/evidence/M7-023/linux_glibc_x86_64/fuzz-report.json",
    )
    parser.add_argument("--crash-dir", type=Path)
    parser.add_argument("--replay-crash", type=Path)
    args = parser.parse_args(argv)

    started = utc_now()
    try:
        manifest_path = args.manifest.resolve()
        manifest, targets = load_manifest(root, manifest_path)
        manifest_digest = evidence_digest.text_evidence_sha256(manifest_path)
        selected = targets
        mode = "campaign"
        if args.replay_crash is not None:
            selected = [validate_replay(args.replay_crash.resolve(), manifest_digest, targets)]
            mode = "replay"
        run_id = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        crash_dir = args.crash_dir or (
            root / "docs/evidence/M7-023/linux_glibc_x86_64/crashes" / run_id
        )
        with tempfile.TemporaryDirectory(prefix="wirestack-m7-023-") as directory:
            snapshot = Path(directory) / "wirestack"
            prepare_snapshot(root, snapshot)
            build = run(build_command(), snapshot, 600.0)
            if build["timed_out"] or build["exit_code"] != 0:
                raise GateError(
                    f"release fuzz binaries failed to build: exit={build['exit_code']} "
                    f"timed_out={build['timed_out']} stderr={build['stderr'][-2000:]}"
                )
            results = [execute_target(snapshot, target, int(manifest["seed"])) for target in selected]

        crash_artifacts: list[str] = []
        for result, target in zip(results, selected):
            if result["decision"] == "FAIL":
                artifact = save_crash(
                    root, crash_dir, target, int(manifest["seed"]), manifest_digest,
                    result["reasons"], result["process"], args.output.resolve(),
                )
                result["crash_artifact"] = str(artifact)
                result["replay_command"] = replay_command(
                    root, artifact, args.output.resolve()
                )
                crash_artifacts.append(str(artifact))
        decision = "PASS" if all(item["decision"] == "PASS" for item in results) else "FAIL"
        report = {
            "schema_version": SCHEMA_VERSION,
            "gate_id": manifest["gate_id"],
            "profile": manifest["profile"],
            "mode": mode,
            "decision": decision,
            "started_at_utc": started,
            "finished_at_utc": utc_now(),
            "release_compile_option": "-O2",
            "build": build,
            "manifest": str(manifest_path.relative_to(root)),
            "manifest_sha256": manifest_digest,
            "corpus_version": manifest["corpus_version"],
            "source_sha256": source_fingerprint(root),
            "environment": {
                "system": platform.system(),
                "release": platform.release(),
                "machine": platform.machine(),
                "libc": " ".join(platform.libc_ver()),
                "cjc": version(["cjc", "-v"], root),
                "cjpm": version(["cjpm", "-v"], root),
            },
            "target_count": len(results),
            "crash_artifacts": crash_artifacts,
            "targets": results,
        }
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        print(json.dumps({
            "gate_id": report["gate_id"], "mode": mode, "decision": decision,
            "targets": len(results), "output": str(args.output),
        }, sort_keys=True))
        return 0 if decision == "PASS" else 1
    except GateError as error:
        print(f"M7-023 gate error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
