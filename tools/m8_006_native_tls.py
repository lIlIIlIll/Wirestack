#!/usr/bin/env python3
"""Qualify installed Linux TLS contexts and real AWS-LC external callbacks."""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import tomllib
from typing import Any, Sequence

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from tools import m7_021_linux_release as release
from tools.evidence_digest import artifact_byte_digest, text_evidence_digest, TextEvidenceDigest

SOURCE = ROOT / "examples/linux/m8_006/native_tls.cj"
BOUNDARY_SOURCE = ROOT / "native/tls/aws_lc/tests/m8_006_keylog_boundary.c"
BOUNDARY_MARKER = "M8_006_KEYLOG_PROVIDER_BOUNDARY=PASS"
RELEASE_MODES = (
    "versions12", "versions13", "release-keylog-rejected",
    "sign-ok", "sign-throw", "sign-cancel", "sign-deadline",
    "decrypt-ok", "decrypt-throw", "decrypt-cancel", "decrypt-deadline", "decrypt-short",
    "reject-non-rsa",
)
KEYLOG_MODES = ("keylog12-ok", "keylog13-ok", "keylog13-throw", "keylog13-cancel", "keylog13-deadline")


def artifact(path: Path) -> dict[str, object]:
    return {"path": str(path.resolve().relative_to(ROOT)), "digest": text_evidence_digest(path).to_json()}


def command(argv: Sequence[str], cwd: Path, output: Path, name: str, timeout: int,
            records: list[dict[str, Any]]) -> None:
    stdout, stderr = output / f"{name}.stdout.log", output / f"{name}.stderr.log"
    code = None
    timed_out = False
    try:
        with stdout.open("w") as out, stderr.open("w") as err:
            try:
                code = subprocess.run(list(argv), cwd=cwd, stdout=out, stderr=err,
                                      timeout=timeout, check=False).returncode
            except subprocess.TimeoutExpired:
                timed_out = True
    finally:
        records.append({"id": name, "argv": list(argv), "cwd": str(cwd), "exit_code": code,
                        "timed_out": timed_out, "timeout_seconds": timeout,
                        "stdout": artifact(stdout), "stderr": artifact(stderr)})
    if timed_out or code != 0:
        raise RuntimeError(f"{name} failed; see {stderr}")


def marker(mode: str) -> str:
    if mode in {"versions12", "versions13"}:
        return "NATIVE_TLS_VERSIONS=PASS"
    if mode == "release-keylog-rejected":
        return "NATIVE_TLS_RELEASE_KEYLOG_REJECTED=PASS"
    return f"NATIVE_TLS_{mode}=PASS"


def require_marker(path: Path, mode: str) -> None:
    lines = path.read_text().splitlines()
    if [line for line in lines if line.endswith("=PASS")] != [marker(mode)]:
        raise RuntimeError(f"{mode} did not produce its exact acceptance marker")
    if any("SKIP" in line for line in lines):
        raise RuntimeError(f"{mode} attempted to substitute skipped work")


def create_identity(work: Path, output: Path, records: list[dict[str, Any]], *,
                    elliptic: bool = False) -> tuple[Path, Path, Path, Path]:
    pem, key_pem = work / "certificate.pem", work / "key.pem"
    certificate, key, spki = work / "certificate.der", work / "key.der", work / "spki.der"
    prefix = "ec-fixture" if elliptic else "fixture"
    key_options = ["-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256"] if elliptic else ["-newkey", "rsa:2048"]
    command(["/usr/bin/openssl", "req", "-x509", *key_options, "-nodes",
             "-keyout", str(key_pem), "-out", str(pem), "-subj", "/CN=example.com",
             "-addext", "subjectAltName=DNS:example.com", "-days", "2"],
            work, output, f"{prefix}-certificate", 30, records)
    command(["/usr/bin/openssl", "x509", "-in", str(pem), "-outform", "DER", "-out", str(certificate)],
            work, output, f"{prefix}-certificate-der", 10, records)
    command(["/usr/bin/openssl", "pkcs8", "-topk8", "-nocrypt", "-in", str(key_pem),
             "-outform", "DER", "-out", str(key)], work, output, f"{prefix}-key-der", 10, records)
    command(["/usr/bin/openssl", "pkey", "-in", str(key_pem), "-pubout", "-outform", "DER", "-out", str(spki)],
            work, output, f"{prefix}-spki", 10, records)
    key.chmod(0o600)
    key_pem.chmod(0o600)
    return certificate, key, spki, pem


def decrypt_peer(binary: Path, mode: str, identity: tuple[Path, Path, Path, Path],
                 output: Path, records: list[dict[str, Any]]) -> dict[str, Any]:
    certificate, key, spki, pem = identity
    name = f"consumer-{mode}"
    stdout, stderr = output / f"{name}.stdout.log", output / f"{name}.stderr.log"
    argv = [str(binary), mode, str(certificate), str(key), str(spki)]
    code = None
    with stdout.open("w") as out, stderr.open("w") as err:
        process = subprocess.Popen(argv, cwd=binary.parent, stdout=out, stderr=err, start_new_session=True)
        try:
            expires = time.monotonic() + 10
            port = None
            while time.monotonic() < expires:
                for line in stdout.read_text().splitlines():
                    if line.startswith("LISTEN_PORT="):
                        port = int(line.split("=", 1)[1])
                if port is not None:
                    break
                if process.poll() is not None:
                    raise RuntimeError(f"{mode} exited before listening")
                time.sleep(0.02)
            if port is None or not 1 <= port <= 65535:
                raise RuntimeError(f"{mode} did not publish a bounded native endpoint")
            peer_argv = ["/usr/bin/openssl", "s_client", "-quiet", "-tls1_2",
                         "-cipher", "AES128-GCM-SHA256", "-connect", f"127.0.0.1:{port}",
                         "-servername", "example.com", "-CAfile", str(pem),
                         "-verify_return_error", "-verify_hostname", "example.com"]
            peer = subprocess.run(peer_argv, input=b"q", stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                  cwd=binary.parent, timeout=12, check=False)
            peer_out, peer_err = output / f"{name}-peer.stdout.log", output / f"{name}-peer.stderr.log"
            peer_out.write_bytes(peer.stdout)
            peer_err.write_bytes(peer.stderr)
            records.append({"id": f"{name}-peer", "argv": peer_argv, "exit_code": peer.returncode,
                            "expected_success": mode == "decrypt-ok", "timeout_seconds": 12,
                            "stdout": artifact(peer_out), "stderr": artifact(peer_err)})
            if mode == "decrypt-ok":
                if peer.returncode != 0 or peer.stdout != b"a":
                    raise RuntimeError("static-RSA peer did not receive the authenticated application byte")
            elif peer.returncode == 0 or peer.stdout:
                raise RuntimeError("static-RSA peer did not observe the required failed handshake")
            code = process.wait(timeout=14)
            if code != 0:
                raise RuntimeError(f"{mode} native server failed")
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
            records.append({"id": name, "argv": argv, "exit_code": code,
                            "stdout": artifact(stdout), "stderr": artifact(stderr)})
    require_marker(stdout, mode)
    return {"mode": mode, "status": "PASS", "marker": marker(mode),
            "peer_policy": "external OpenSSL peer restricts existing TLS 1.2 static-RSA policy; Wirestack cipher policy unchanged",
            "stdout": artifact(stdout), "stderr": artifact(stderr)}


def qualify_provider_boundary(
    identity: tuple[Path, Path, Path, Path],
    provider_current: Path,
    provider_manifest: dict[str, Any],
    work: Path,
    output: Path,
    records: list[dict[str, Any]],
) -> dict[str, Any]:
    tools = provider_manifest.get("build_inputs", {}).get("tools", {})
    cc, cxx = tools.get("cc"), tools.get("cxx")
    if not isinstance(cc, str) or not isinstance(cxx, str):
        raise RuntimeError("test-only provider manifest lacks compiler paths")
    include = provider_current / "include"
    archive = provider_current / "lib/libwirestack_tls_provider.a"
    boundary_object = work / "m8_006_keylog_boundary.o"
    boundary_binary = work / "m8_006_keylog_boundary"
    command(
        [cc, "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
         f"-I{include}", "-c", str(BOUNDARY_SOURCE), "-o", str(boundary_object)],
        ROOT, output, "provider-boundary-compile", 60, records,
    )
    command(
        [cxx, str(boundary_object), str(archive), "-pthread", "-ldl", "-lm",
         "-o", str(boundary_binary)],
        ROOT, output, "provider-boundary-link", 60, records,
    )
    certificate, key, _, _ = identity
    command(
        [str(boundary_binary), str(certificate), str(key)],
        work, output, "provider-boundary-run", 30, records,
    )
    stdout = output / "provider-boundary-run.stdout.log"
    stderr = output / "provider-boundary-run.stderr.log"
    lines = stdout.read_text().splitlines()
    if lines != [BOUNDARY_MARKER] or any("SKIP" in line for line in lines):
        raise RuntimeError("provider boundary did not produce its exact acceptance marker")
    if stderr.read_bytes():
        raise RuntimeError("provider boundary emitted unexpected stderr")
    return {
        "status": "PASS",
        "marker": BOUNDARY_MARKER,
        "source": artifact(BOUNDARY_SOURCE),
        "stdout": artifact(stdout),
        "stderr": artifact(stderr),
        "bounds": {
            "maximum_certificate_bytes": 256 * 1024,
            "maximum_private_key_bytes": 64 * 1024,
            "maximum_server_name_bytes": 253,
            "transfer_chunk_bytes": 16 * 1024,
            "maximum_handshake_steps": 256,
            "maximum_handshake_ciphertext_bytes": 1024 * 1024,
            "maximum_key_log_records": 16,
            "maximum_key_log_record_bytes": 512,
        },
    }


def qualify(report: dict[str, Any], output: Path, profile: str, offline: bool) -> None:
    release.platform_identity()
    records = report["commands"]
    command(["cjc", "-v"], ROOT, output, "toolchain", 10, records)
    provider = [sys.executable, str(ROOT / "tools/build_tls_provider.py")]
    if offline:
        provider.append("--offline")
    command(provider, ROOT, output, "release-provider-build", 1800, records)
    command([sys.executable, str(ROOT / "tools/build_linux_resolver.py"), "--quiet"],
            ROOT, output, "resolver-build", 600, records)
    command([sys.executable, str(ROOT / "tools/build_linux_http_files.py"), "--root", str(ROOT), "--quiet"],
            ROOT, output, "http-files-build", 600, records)
    with tempfile.TemporaryDirectory(prefix=f"wirestack-m8-006-{profile}-") as temporary:
        test_provider_current: Path | None = None
        test_provider_manifest: dict[str, Any] | None = None
        work = Path(temporary)
        payload, manifest = release.collect_payload(ROOT)
        archive = work / release.ARTIFACT_NAME
        release.write_reproducible_archive(archive, payload)
        installed = release.extract_archive(archive, work / "install")
        if json.loads((installed / "release-manifest.json").read_text()) != manifest:
            raise RuntimeError("extracted manifest differs from the collected release payload")
        report["installation"] = {
            "method": "fresh archive extracted outside source checkout",
            "archive_digest": artifact_byte_digest(archive).to_json(), "archive_retained": False,
            "source_digest": TextEvidenceDigest(release.source_tree_sha256(installed)).to_json(),
            "checkout_path_dependency": False, "test_only_provider_overlay": profile == "keylog",
        }
        if profile == "keylog":
            test_output = work / "test-provider"
            args = [sys.executable, str(ROOT / "tools/build_linux_tls_provider.py"),
                    "--enable-test-keylog", "--out-dir", str(test_output)]
            if offline:
                args.append("--offline")
            command(args, ROOT, output, "test-only-keylog-provider-build", 1800, records)
            test_provider_current = test_output / "current"
            shutil.copytree(test_provider_current, installed / "target/native/current", dirs_exist_ok=True)
            test_manifest = json.loads((test_provider_current / "provider-manifest.json").read_text())
            if test_manifest.get("test_only_key_log") is not True:
                raise RuntimeError("key-log provider was not marked test-only")
            test_provider_manifest = test_manifest
            report["test_only_provider"] = test_manifest
            try:
                release.collect_payload(installed)
            except release.ReleaseError as error:
                if "test-only TLS key logging" not in str(error):
                    raise
                report["test_only_release_rejection"] = {"status": "PASS", "error": str(error)}
            else:
                raise RuntimeError("release collector accepted a test-only secret-logging provider")
        consumer = work / "consumer"
        (consumer / "src").mkdir(parents=True)
        consumer_manifest = release.consumer_manifest(installed).replace(
            "wirestack_release_smoke", "wirestack_m8_006_native_tls")
        parsed = tomllib.loads(consumer_manifest)
        if parsed["dependencies"] != {"wirestack": {"path": str(installed)}} or str(ROOT) in consumer_manifest:
            raise RuntimeError("consumer does not depend exclusively on the extracted installation")
        (consumer / "cjpm.toml").write_text(consumer_manifest)
        report["installation"]["consumer_manifest_digest"] = text_evidence_digest(consumer / "cjpm.toml").to_json()
        shutil.copy2(SOURCE, consumer / "src/main.cj")
        command(["cjpm", "build"], consumer, output, "consumer-build", 600, records)
        binary = consumer / "target/release/bin/main"
        report["consumer_binary_digest"] = artifact_byte_digest(binary).to_json()
        identity = create_identity(work, output, records)
        if profile == "keylog":
            if test_provider_current is None or test_provider_manifest is None:
                raise RuntimeError("test-only provider boundary inputs are unavailable")
            report["provider_boundary"] = qualify_provider_boundary(
                identity,
                test_provider_current,
                test_provider_manifest,
                work,
                output,
                records,
            )
        for mode in KEYLOG_MODES if profile == "keylog" else RELEASE_MODES:
            if mode.startswith("decrypt-"):
                scenario = decrypt_peer(binary, mode, identity, output, records)
            else:
                selected_identity = identity
                if mode == "reject-non-rsa":
                    ec_work = work / "elliptic-identity"
                    ec_work.mkdir()
                    selected_identity = create_identity(ec_work, output, records, elliptic=True)
                name = f"consumer-{mode}"
                command([str(binary), mode, *map(str, selected_identity[:3])], binary.parent, output, name, 30, records)
                require_marker(output / f"{name}.stdout.log", mode)
                scenario = {"mode": mode, "status": "PASS", "marker": marker(mode),
                            "stdout": artifact(output / f"{name}.stdout.log"),
                            "stderr": artifact(output / f"{name}.stderr.log")}
            report["scenarios"].append(scenario)
    report["status"] = "PASS"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", choices=("release", "keylog"), default="release")
    parser.add_argument("--report", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--offline", action="store_true")
    args = parser.parse_args()
    report_path = (args.report or ROOT / f"docs/evidence/M8-006/native-{args.profile}.json").resolve()
    output = (args.output or ROOT / f"docs/evidence/M8-006/native-{args.profile}").resolve()
    report_path.relative_to(ROOT)
    output.relative_to(ROOT)
    output.mkdir(parents=True, exist_ok=True)
    report: dict[str, Any] = {
        "schema_version": 1, "kind": "native-tls-context-hooks", "source_task": "M8-006",
        "status": "FAIL", "profile": f"linux-x86_64-glibc-{args.profile}",
        "key_log_release_qualified": False, "commands": [], "scenarios": [],
        "source_digest": text_evidence_digest(SOURCE).to_json(),
        "generated_at_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
    }
    try:
        qualify(report, output, args.profile, args.offline)
    except Exception as error:
        report["error"] = {"type": type(error).__name__, "message": str(error)}
    report_path.parent.mkdir(parents=True, exist_ok=True)
    temporary = report_path.with_suffix(".tmp")
    temporary.write_text(json.dumps(report, indent=2) + "\n")
    temporary.replace(report_path)
    print(json.dumps({"status": report["status"], "profile": args.profile,
                      "scenarios": len(report["scenarios"]), "report": str(report_path)}, indent=2))
    return 0 if report["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
