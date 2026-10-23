#!/usr/bin/env python3
"""Exercise existing release verifiers with isolated TEST_ONLY mutations."""
from __future__ import annotations

import argparse
import contextlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile

if __package__ in {None, ""}:
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tools import evidence_digest as digest
from tools import m7_021_linux_release as payload_release
from tools import m7_030_linux_release as signing

ROOT = Path(__file__).resolve().parents[1]
NATIVE = ROOT / "docs/evidence/M12-001/native-final/wirestack-baseline.tar.gz"


def error_code(error: Exception) -> str:
    """Use verifier-owned structured codes, never exception-message dispatch."""
    return getattr(error, "code", "UNEXPECTED_VERIFIER_ERROR")


def rejection(name: str, expected: str, verifier: str, operation, evidence: dict) -> dict:
    try:
        operation()
    except (signing.ReleaseError, payload_release.ReleaseError) as error:
        actual = error_code(error)
        return {"id": name, "status": "PASS" if actual == expected else "FAIL",
                "expected_error": expected, "error": actual, "verifier": verifier,
                "evidence": evidence}
    return {"id": name, "status": "FAIL", "expected_error": expected,
            "error": "ACCEPTED_MUTATION", "verifier": verifier, "evidence": evidence}


@contextlib.contextmanager
def scratch_environment(directory: Path):
    previous = {name: os.environ.get(name) for name in ("TMPDIR", "TMP", "TEMP")}
    previous_tempdir = tempfile.tempdir
    for name in previous:
        os.environ[name] = str(directory)
    tempfile.tempdir = str(directory)
    try:
        yield
    finally:
        tempfile.tempdir = previous_tempdir
        for name, value in previous.items():
            if value is None:
                os.environ.pop(name, None)
            else:
                os.environ[name] = value


def run_command(argv: list[str], directory: Path, commands: list, timeout: int = 30):
    result = subprocess.run(argv, cwd=directory, capture_output=True, timeout=timeout)
    normalized = [value.replace(str(directory), "<sandbox>").replace(str(ROOT), "<repo>") for value in argv]
    commands.append({"argv": normalized, "exit_code": result.returncode,
                     "stdout_digest": digest.artifact_byte_digest_bytes(result.stdout).to_json(),
                     "stderr_digest": digest.artifact_byte_digest_bytes(result.stderr).to_json()})
    if result.returncode:
        raise RuntimeError("CONTROL_COMMAND_FAILED")
    return result


def isolated_final():
    spec = importlib.util.spec_from_file_location("m12_004_isolated_final", ROOT / "tools/m8_007_final_release.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def input_name(path: Path) -> str:
    try:
        return path.resolve().relative_to(ROOT).as_posix()
    except ValueError:
        return "<external-native-artifact>"

def required_control_inputs(native_artifact: Path) -> list[Path]:
    return [signing.ARTIFACT, native_artifact, *[signing.SUPPLY_CHAIN / name for name in
            ("bundle.json", "provider-manifest.json", "build-fingerprint.json", "sbom.spdx.json")],
            ROOT / "docs/evidence/M8-007/linux_x86_64/fuzz-report.json"]

def fuzz_control(baseline: str, verify, evidence: dict) -> dict:
    """Credit the fuzz mutation only when the pristine report verified first.

    A verifier that rejects the unmodified report rejects the mutation for the
    same reason, so the mutation proves nothing. Withhold the credit and fail.
    """
    if baseline != "PASS":
        return {"id": "stale-candidate-fuzz-report", "status": "FAIL",
                "expected_error": "STALE_FUZZ_INPUTS", "error": "POSITIVE_CONTROL_BLOCKED",
                "verifier": "m8_007.verify_fuzz", "evidence": evidence}
    return rejection("stale-candidate-fuzz-report", "STALE_FUZZ_INPUTS", "m8_007.verify_fuzz", verify, evidence)


def suite_status(report: dict) -> str:
    """Fail closed when the pristine positive control is not a PASS."""
    baseline = report.get("historical_fuzz_baseline", {}).get("status", "NOT_RUN")
    passed = (all(item["status"] == "PASS" for item in report.get("controls", []))
              and baseline == "PASS" and report.get("original_inputs_untouched") is True
              and report.get("temporary_material_removed") is True
              and report.get("native_smoke", {}).get("status") == "PASS")
    return "PASS" if passed else "FAIL"


def run_controls(scratch_parent: Path, native_artifact: Path = NATIVE) -> dict:
    native_artifact = native_artifact.resolve()
    scratch_parent = scratch_parent.resolve()
    if ROOT == scratch_parent or ROOT in scratch_parent.parents:
        raise ValueError("scratch must be outside the repository")
    files = required_control_inputs(native_artifact)
    missing = sorted({input_name(path) for path in files if not path.is_file()})
    if missing:
        return {"schema_version": 1, "task_id": "M12-004", "family": "verifier-controls",
                "status": "BLOCKED", "SDKpolicy": "STS_ONLY", "qualification": "NOT_QUALIFIED",
                "error": "CONTROL_INPUTS_MISSING", "missing_inputs": missing,
                "native_artifact": {"path": input_name(native_artifact), "digest": "NOT_AVAILABLE"},
                "limitations": ["Verifier controls and native smoke were not run because required release evidence archives are unavailable.",
                                "This blocked report does not qualify a candidate or SDK."]}
    scratch_parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    originals = {input_name(path): digest.artifact_byte_digest(path).to_json() for path in files}
    report = {"schema_version": 1, "task_id": "M12-004", "family": "verifier-controls",
              "status": "FAIL", "SDKpolicy": "STS_ONLY", "qualification": "NOT_QUALIFIED",
              "signing_material": "TEST_ONLY", "controls": [], "commands": [],
              "original_inputs": originals,
              "native_artifact": {"path": input_name(native_artifact), "digest": digest.artifact_byte_digest(native_artifact).to_json()},
              "sources": {name: digest.text_evidence_digest(ROOT / name).to_json() for name in
                          ("tools/m12_004_verifier_controls.py", "tools/m7_030_linux_release.py",
                           "tools/m7_021_linux_release.py", "tools/m8_007_final_release.py")},
              "limitations": ["Historical M7-025/M7-030 bytes provide only a positive offline cryptographic fixture, not current candidate qualification.",
                               "Wrong source control binds signed manifest bytes, not GitHub OIDC provenance. Production attestation authorization is not exercised.",
                               "Native controls and ABI smoke apply only to the selected native artifact. No Cangjie SDK is executed."]}
    with tempfile.TemporaryDirectory(prefix="test-only-verifier-", dir=scratch_parent) as temporary:
        sandbox = Path(temporary)
        sandbox.chmod(0o700)
        with scratch_environment(sandbox):
            private = sandbox / "TEST_ONLY_signer"
            wrong = sandbox / "TEST_ONLY_wrong_signer"
            for key in (private, wrong):
                run_command(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "TEST_ONLY", "-f", str(key)], sandbox, report["commands"])
            artifact = sandbox / signing.ARTIFACT.name
            shutil.copyfile(signing.ARTIFACT, artifact)
            supply = sandbox / "supply"
            supply.mkdir()
            for path in files[2:6]:
                shutil.copyfile(path, supply / path.name)
            sbom = supply / "sbom.spdx.json"
            signed = sandbox / "signed"
            signing.create_offline_bundle(private, private.with_suffix(".pub"), signed,
                                          artifact=artifact, supply_chain=supply, allow_temporary_key=True)
            public = signed / "release-signing-key.pub"
            def verify():
                return signing.verify_offline_bundle(signed, public, artifact=artifact, sbom=sbom)
            report["offline_positive"] = verify()
            def control(name, expected, verifier, operation, path):
                report["controls"].append(rejection(name, expected, verifier, operation,
                    {"mutation_digest": digest.artifact_byte_digest(path).to_json()}))
            pristine = artifact.read_bytes()
            artifact.write_bytes(pristine[:-1] + bytes([pristine[-1] ^ 1]))
            control("archive-replacement", "SUBJECT_DIGEST", "m7_030.verify_offline_bundle", verify, artifact)
            artifact.write_bytes(pristine)
            original = sbom.read_bytes()
            changed = json.loads(original)
            changed["packages"][0]["versionInfo"] = "TEST_ONLY-wrong-version"
            sbom.write_bytes(signing.canonical_json(changed))
            control("sbom-mismatch", "SUBJECT_DIGEST", "m7_030.verify_offline_bundle", verify, sbom)
            sbom.write_bytes(original)
            for subject in ("artifact", "sbom", "release-manifest"):
                signature = signed / f"{subject}.sig"
                saved = signature.read_bytes()
                signature.unlink()
                report["controls"].append(rejection(f"missing-{subject}-signature", "SIGNATURE_MISSING",
                    "m7_030.verify_offline_bundle", verify, {"missing": f"{subject}.sig"}))
                signature.write_bytes(saved)
            manifest = signed / "release-manifest.json"
            original = manifest.read_bytes()
            changed = json.loads(original)
            changed["provider"]["sourceContentSha256"] = "0" * 64
            manifest.write_bytes(signing.canonical_json(changed))
            control("wrong-source-binding", "SIGNATURE_INVALID", "m7_030.verify_offline_bundle", verify, manifest)
            manifest.write_bytes(original)
            changed = json.loads(original)
            changed["signingPolicy"]["repository"] = "example/TEST_ONLY-wrong-source"
            manifest.write_bytes(signing.canonical_json(changed))
            source_signature = signed / "release-manifest.sig"
            original_signature = source_signature.read_bytes()
            signing.sign_file(private, manifest, source_signature)
            signing.verify_file(signing.public_key(private), manifest, source_signature)
            control("signed-wrong-source-policy", "MANIFEST_POLICY", "m7_030.verify_offline_bundle", verify, manifest)
            manifest.write_bytes(original)
            source_signature.write_bytes(original_signature)
            signature = signed / "release-manifest.sig"
            saved = signature.read_bytes()
            signing.sign_file(wrong, manifest, signature)
            control("wrong-signer", "SIGNATURE_INVALID", "m7_030.verify_offline_bundle", verify, signature)
            signature.write_bytes(saved)
            stale = json.loads((supply / "build-fingerprint.json").read_bytes())
            stale["buildFingerprint"] = "0" * 64
            (supply / "build-fingerprint.json").write_bytes(signing.canonical_json(stale))
            control("stale-supply-report", "SUPPLY_CHAIN_STALE", "m7_030.build_release_manifest",
                    lambda: signing.build_release_manifest(artifact, supply), supply / "build-fingerprint.json")
            final = isolated_final()
            try:
                final.verify_fuzz()
                report["historical_fuzz_baseline"] = {"status": "PASS", "qualification": "NOT_QUALIFIED"}
            except payload_release.ReleaseError as error:
                report["historical_fuzz_baseline"] = {"status": "BLOCKED", "error": error_code(error),
                    "detail": str(error).replace(str(ROOT), "<repo>").replace(str(Path.home()), "$HOME"),
                    "qualification": "NOT_QUALIFIED"}
            stale_fuzz = sandbox / "fuzz-report.json"
            changed = json.loads(files[-1].read_bytes())
            changed["final_release_inputs"] = {"TEST_ONLY": "stale-candidate"}
            stale_fuzz.write_bytes(signing.canonical_json(changed))
            final.FUZZ_REPORT = stale_fuzz
            report["controls"].append(fuzz_control(
                report["historical_fuzz_baseline"]["status"], final.verify_fuzz,
                {"mutation_digest": digest.artifact_byte_digest(stale_fuzz).to_json(),
                 "pristine_baseline": report["historical_fuzz_baseline"]["status"]}))
            installed = payload_release.extract_archive(native_artifact, sandbox / "installed")
            payload_release.collect_payload(installed)
            report["native_payload_positive"] = "PASS"
            provider = installed / "target/native/current/provider-manifest.json"
            original = provider.read_bytes()
            for field in ("capabilities", "test_only_key_log"):
                changed = json.loads(original)
                if field == "capabilities":
                    changed[field] = [*changed[field], "key-log"]
                else:
                    changed[field] = True
                provider.write_bytes(signing.canonical_json(changed))
                control(f"keylog-{field}", "KEYLOG_CAPABILITY_FORBIDDEN", "m7_021.collect_payload",
                        lambda: payload_release.collect_payload(installed), provider)
                provider.write_bytes(original)
            native_archive = installed / "target/native/current/lib/libwirestack_tls_provider.a"
            pristine_native = native_archive.read_bytes()
            native_archive.write_bytes(pristine_native[:-1] + bytes([pristine_native[-1] ^ 1]))
            control("native-static-archive-replacement", "NATIVE_ARCHIVE_PROVENANCE", "m7_021.collect_payload",
                    lambda: payload_release.collect_payload(installed), native_archive)
            native_archive.write_bytes(pristine_native)
            source = sandbox / "smoke.c"
            source.write_text('#include <stdint.h>\n#include <stdio.h>\nextern uint32_t wirestack_tls_provider_abi_version(void);\nint main(void) { uint32_t abi = wirestack_tls_provider_abi_version(); if (abi != 1) return 1; puts("M12_004_SELECTED_NATIVE_ABI=PASS"); return 0; }\n')
            binary = sandbox / "smoke"
            run_command(["cc", str(source), str(native_archive), "-pthread", "-ldl", "-o", str(binary)], sandbox, report["commands"], 60)
            smoke = run_command([str(binary)], sandbox, report["commands"])
            report["native_smoke"] = {"status": "PASS" if smoke.stdout == b"M12_004_SELECTED_NATIVE_ABI=PASS\n" else "FAIL",
                                      "source_digest": digest.text_evidence_digest(source).to_json()}
            report["offline_restored"] = verify()
    report["temporary_material_removed"] = not Path(temporary).exists()
    after = {input_name(path): digest.artifact_byte_digest(path).to_json() for path in files}
    report["original_inputs_untouched"] = originals == after
    baseline = report.get("historical_fuzz_baseline", {}).get("status", "NOT_RUN")
    report["positive_controls"] = {
        "pristine_fuzz_verifier": baseline,
        "stale_candidate_fuzz_credit": "NOT_GRANTED" if baseline != "PASS" else "GRANTED"}
    report["status"] = suite_status(report)
    return report


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scratch-parent", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--native-artifact", type=Path, default=NATIVE)
    args = parser.parse_args(argv)
    def expired(_signum, _frame):
        raise RuntimeError("CONTROL_LIFETIME_EXCEEDED")
    previous_handler = signal.signal(signal.SIGALRM, expired)
    signal.alarm(180)
    try:
        report = run_controls(args.scratch_parent, args.native_artifact)
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired, digest.DigestError) as error:
        report = {"schema_version": 1, "task_id": "M12-004", "family": "verifier-controls", "status": "BLOCKED",
                  "SDKpolicy": "STS_ONLY", "qualification": "NOT_QUALIFIED", "error": error_code(error)}
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, previous_handler)
    signing.atomic_json(args.output, report)
    print(json.dumps(report, sort_keys=True))
    return 0 if report["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
