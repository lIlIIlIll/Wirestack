#!/usr/bin/env python3
"""Build and run the raw and explicit gzip consumers from an extracted production archive."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
from collections import Counter
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))
from tools import m7_021_linux_release as release, m7_025_linux_supply_chain as supply
from tools.evidence_digest import artifact_byte_digest, text_evidence_digest, text_evidence_sha256, text_evidence_bytes_sha256, text_evidence_sha256_equal

SOURCES = {mode: ROOT / f"examples/linux/m11_002/{mode}.cj" for mode in ("raw", "gzip")}
CHECKS = {"raw": Counter({"default_raw_no_negotiation": 1}),
    "gzip": Counter({"native_gzip_h1": 1, "native_gzip_h2": 1, "bounded_decode_baseline": 1, "native_shutdown": 1})}



def write_source_supply_chain(archive: Path, installed: Path, report: dict) -> None:
    """Bind the exercised payload and native consumers without claiming release qualification."""
    metadata = supply.artifact_metadata(archive)
    observations = {"platform": report["platform"], "artifact": {"name": archive.name},
        "toolchain": {"cjc": report["toolchain"]["compiler"].splitlines(), "cjpm": report["toolchain"]["cjpm"]},
        "dependency_scan": {"needed": report["consumers"]["gzip"]["native_needed"]}}
    if report["consumers"]["raw"]["native_needed"] != observations["dependency_scan"]["needed"]:
        raise RuntimeError("enabled consumer adds a native dependency")
    inputs = supply.fingerprint_inputs(metadata, observations, text_evidence_sha256(Path(supply.__file__)))
    fingerprint = text_evidence_bytes_sha256(supply.canonical_json(inputs))
    provider = supply.release_provider_manifest(metadata, observations, fingerprint, task_id="M11-002")
    sbom = supply.spdx_document(metadata, observations, provider, task_id="M11-002", created_utc=datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"))
    module = provider["optionalModules"][0]
    component = supply._spdx_package(sbom, supply.GZIP_SPDX_ID)
    if (module["package"] != "wirestack.gzip" or module["nativeDependencies"] != [] or len(module["sources"]) != 4
        or component["licenseDeclared"] != "Apache-2.0" or component["licenseConcluded"] != "Apache-2.0"
        or supply._package_checksum(sbom, supply.GZIP_SPDX_ID) != text_evidence_bytes_sha256(supply.canonical_json(module))):
        raise RuntimeError("gzip source component checksum, license or dependency inventory differs")
    relation = {"spdxElementId": "SPDXRef-Package-Wirestack-Artifact", "relationshipType": "CONTAINS", "relatedSpdxElement": supply.GZIP_SPDX_ID}
    if relation not in sbom["relationships"]:
        raise RuntimeError("SPDX omits the optional source component relationship")
    for source in module["sources"]:
        if not text_evidence_sha256_equal(text_evidence_digest(installed / source["path"]).to_json(), source["sha256"]):
            raise RuntimeError("SPDX source digest differs from installed payload")
    nonclaims = ["Working-tree source/binary acceptance, not an M7 qualified release or committed candidate.",
        "No new compression dependency; existing SDK and native-provider provenance remains separately recorded.",
        "Unsigned artifact; no non-Linux platform qualification."]
    provider.update(releaseQualification="NOT_QUALIFIED", candidateCommitted=False, nonClaims=nonclaims)
    fingerprint_document = {"schemaVersion": 2, "taskId": "M11-002", "buildFingerprint": fingerprint, "inputs": inputs,
        "releaseQualification": "NOT_QUALIFIED", "candidateCommitted": False}
    output = ROOT / "docs/evidence/M11-002/supply-chain"
    output.mkdir(parents=True, exist_ok=True)
    result = {"schema_version": 1, "task_id": "M11-002", "status": "PASS", "release_qualification": "NOT_QUALIFIED",
        "candidate_committed": False, "scope": "Actual exercised archive, installed source component and native consumer dependencies; not formal M7 qualification",
        "archive_digest": report["archive_digest"], "payload_sha256": report["payload_sha256"], "optional_modules": [module],
        "raw_native_needed": report["consumers"]["raw"]["native_needed"], "gzip_native_needed": observations["dependency_scan"]["needed"],
        "additional_native_compression_dependencies": [], "license": "Apache-2.0", "source_digests_match": True,
        "non_claims": nonclaims, "generator_source": {"path": "tools/m7_025_linux_supply_chain.py", "digest": text_evidence_digest(Path(supply.__file__)).to_json()},
        "consumer_runner_source_digest": report["runner_source_digest"], "documents": {}}
    for name, value in (("provider-manifest.json", provider), ("build-fingerprint.json", fingerprint_document), ("sbom.spdx.json", sbom)):
        path = output / name
        path.write_bytes(supply.canonical_json(value))
        result["documents"][name] = text_evidence_digest(path).to_json()
    (output / "report.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "docs/evidence/M11-002/installed")
    parser.add_argument("--scratch-parent", type=Path, default=Path.home() / ".cache/agent-tmp")
    args = parser.parse_args()
    output = args.output.resolve()
    relative = output.relative_to(ROOT)
    if relative.parts[:3] != ("docs", "evidence", "M11-002"):
        raise ValueError("output must stay within this task's evidence")
    output.mkdir(parents=True, exist_ok=True)
    parent = args.scratch_parent.resolve()
    parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if shutil.disk_usage(parent).free < 2 * 1024**3:
        raise RuntimeError("scratch filesystem needs at least 2 GiB free")
    probe = subprocess.run(["findmnt", "-n", "-o", "FSTYPE", "-T", str(parent)],
        capture_output=True, text=True, check=True)
    if probe.stdout.strip() == "tmpfs":
        raise RuntimeError("scratch filesystem must be disk-backed")
    report = {"schema_version": 1, "task_id": "M11-002", "status": "INCOMPLETE",
        "platform": release.platform_identity(), "release_qualification": "NOT_QUALIFIED",
        "candidate_committed": False, "consumer_sources": {mode: {"path": str(source.relative_to(ROOT)),
            "digest": text_evidence_digest(source).to_json()} for mode, source in SOURCES.items()}, "commands": []}
    report["runner_source_digest"] = text_evidence_digest(Path(__file__)).to_json()
    with tempfile.TemporaryDirectory(prefix="wirestack-m11-002-installed-", dir=parent) as directory:
        work = Path(directory)
        replacements = [(str(work), "<scratch>"), (str(ROOT), "<repo>"),
            (os.environ.get("CANGJIE_HOME", ""), "<sdk>"), (str(Path.home()), "$HOME")]
        replacements = sorted(((a, b) for a, b in replacements if a), key=lambda pair: -len(pair[0]))
        env = dict(os.environ, TMPDIR=str(work), TMP=str(work), TEMP=str(work), DISABLE_ZOXIDE="1")

        def redact(text: str) -> str:
            for actual, placeholder in replacements:
                text = text.replace(actual, placeholder)
            return text.replace("127.0.0.1", "192.0.2.1")

        def run(name: str, argv: list[str], cwd: Path, timeout: int = 60) -> str:
            code, timed_out = None, False
            try:
                result = subprocess.run(argv, cwd=cwd, env=env, capture_output=True, timeout=timeout, check=False)
                stdout, stderr, code = result.stdout, result.stderr, result.returncode
            except subprocess.TimeoutExpired as error:
                stdout, stderr, timed_out = error.stdout or b"", error.stderr or b"", True
            if name == "processor" and code == 0:
                fields = {row["field"]: row["data"] for row in json.loads(stdout)["lscpu"]}
                stdout = json.dumps({"architecture": fields["Architecture:"], "processor_model": fields["Model name:"],
                    "logical_processors": fields["CPU(s):"]}, sort_keys=True).encode("utf-8")
            text, errors = redact(stdout.decode("utf-8", errors="replace")), redact(stderr.decode("utf-8", errors="replace"))
            streams = {}
            for kind, value in (("stdout", text), ("stderr", errors)):
                path = output / f"{name}.{kind}.log"
                path.write_text(value, encoding="utf-8")
                streams[kind] = {"path": str(path.relative_to(ROOT)), "digest": text_evidence_digest(path).to_json()}
            report["commands"].append({"id": name, "argv": [redact(v) for v in argv],
                "cwd": redact(str(cwd)), "exit_code": code, "timed_out": timed_out, **streams})
            if timed_out or code != 0:
                raise RuntimeError(f"{name} failed; see task evidence logs")
            return text

        try:
            payload, manifest = release.collect_payload(ROOT)
            archive = work / "wirestack-current.tar.gz"
            release.write_reproducible_archive(archive, payload)
            installed = release.extract_archive(archive, work / "install")
            if installed == ROOT or ROOT in installed.parents:
                raise RuntimeError("installation must be outside checkout")
            actual = json.loads((installed / "release-manifest.json").read_text())
            if actual != manifest:
                raise RuntimeError("extracted archive manifest differs")
            report.update(archive_digest=artifact_byte_digest(archive).to_json(), payload_sha256=manifest["payload_sha256"],
                production_sources={str(path.relative_to(installed)): text_evidence_digest(path).to_json()
                    for path in release.production_sources(installed)})
            report["optional_modules"] = manifest.get("optionalModules", [])
            run("certificate", ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                "-subj", "/CN=example.test", "-addext", "subjectAltName=DNS:example.test",
                "-keyout", str(work / "key.pem"), "-out", str(work / "certificate.pem")], work)
            run("certificate-der", ["openssl", "x509", "-in", str(work / "certificate.pem"),
                "-outform", "DER", "-out", str(work / "certificate.der")], work)
            run("key-der", ["openssl", "pkcs8", "-topk8", "-nocrypt", "-in", str(work / "key.pem"),
                "-outform", "DER", "-out", str(work / "key.pk8")], work)
            report["toolchain"] = {"compiler": run("compiler", ["cjc", "--version"], work).strip(),
                "cjpm": run("cjpm", ["cjpm", "--version"], work).strip()}
            report["benchmark_environment"] = {"scope": "native Linux executable; in-memory raw versus decoded 8 x 1 MiB; no throughput threshold",
                "processor": run("processor", ["lscpu", "--json"], work)}
            report["consumers"] = {}
            for mode, source in SOURCES.items():
                consumer = work / mode
                (consumer / "src").mkdir(parents=True)
                consumer_manifest = release.consumer_manifest(installed).replace("wirestack_release_smoke", f"wirestack_m11_002_{mode}")
                if str(ROOT) in consumer_manifest:
                    raise RuntimeError("consumer manifest references checkout")
                (consumer / "cjpm.toml").write_text(consumer_manifest, encoding="utf-8")
                shutil.copy2(source, consumer / "src/main.cj")
                run(f"{mode}-build", ["cjpm", "build"], consumer, timeout=600)
                binary = consumer / "target/release/bin/main"
                dynamic = run(f"{mode}-dependencies", ["readelf", "-d", str(binary)], consumer)
                needed = sorted(re.findall(r"\(NEEDED\).*?\[(.*?)\]", dynamic))
                if any(re.search(r"(?:libz[.-]|libzstd|libbz2|liblzma|libbrotli)", name) for name in needed):
                    raise RuntimeError("consumer acquired an unexpected compression library")
                argv = [str(binary)] + ([str(work / "certificate.der"), str(work / "key.pk8")] if mode == "gzip" else [])
                text = run(f"{mode}-run", argv, consumer, timeout=90)
                checks = Counter(re.findall(r"^CHECK ([a-z0-9_]+) PASS$", text, flags=re.MULTILINE))
                if checks != CHECKS[mode] or text.splitlines().count(f"M11_002_INSTALLED_{mode.upper()}_PASS") != 1:
                    raise RuntimeError(f"{mode} consumer checks differ: {dict(checks)}")
                report["consumers"][mode] = {"binary_digest": artifact_byte_digest(binary).to_json(),
                    "native_needed": needed, "pass_checks": dict(checks), "checkout_path_dependency": False}
                if mode == "gzip":
                    resource = re.findall(r"^RESOURCE buffers=(\d+) requests=(\d+) streams=(\d+) reserved_streams=(\d+) admission_waiters=(\d+) pool_waiters=(\d+)$", text, re.MULTILINE)
                    if len(resource) != 6 or any(any(int(v) != 0 for v in row) for row in resource):
                        raise RuntimeError("installed decoder terminal owners/waiters are not zero")
                    rows = re.findall(r"^BENCH mode=(raw|gzip) bytes=(\d+) checksum=(\d+) elapsed_ns=(\d+) max_work_between_checks=(\d+) retained_bound=(\d+)$", text, re.MULTILINE)
                    if len(rows) != 2 or {row[0] for row in rows} != {"raw", "gzip"}:
                        raise RuntimeError("measured raw/decode baseline missing")
                    benchmarks = []
                    for name, count, checksum, nanos, steps, retained in rows:
                        count, checksum, nanos, steps, retained = map(int, (count, checksum, nanos, steps, retained))
                        if count != 8 * 1024**2 or checksum != count * 97 or nanos <= 0 or steps > 512 or retained != (135168 if name == "gzip" else 0):
                            raise RuntimeError("benchmark correctness/work/storage acceptance failed")
                        benchmarks.append({"mode": name, "bytes": count, "checksum": checksum, "elapsed_ns": nanos,
                            "MiB_per_second": count * 1e9 / nanos / 1024**2, "maximum_work_between_checks": steps,
                            "codec_retained_bound_bytes": retained})
                    report["benchmark"] = {"status": "PASS", "rows": benchmarks,
                        "decision": "Exact 8 MiB/checksum validated in both modes; gzip work <=512 and declared storage bound; no speed improvement or regression threshold claimed."}
            write_source_supply_chain(archive, installed, report)
            report.update(status="PASS", additional_compression_native_dependencies=[], checkout_path_dependency=False,
                pass_check_count=sum(sum(checks.values()) for checks in CHECKS.values()))
        except Exception as error:
            report.update(status="FAIL", error=redact(str(error)))
        finally:
            (output / "report.json").write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(json.dumps({"status": report["status"], "report": str((output / "report.json").relative_to(ROOT))}))
    return 0 if report["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
