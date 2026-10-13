"""Real signature/policy and atomic deployment controls, not release qualification."""
import argparse
import datetime as dt
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

from tools import evidence_digest as digest
from tools import m12_004_rollback as rollback
from tools import m7_030_linux_release as signing


class RollbackTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.key = self.work / "test-only-authority"
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(self.key)], check=True)
        self.artifact = self.work / "archive.tar.gz"
        self.artifact.write_bytes(b"exact historical bytes for atomic deployment unit test")
        self.binding = digest.artifact_byte_digest(self.artifact).to_json()
        self.report = {"bindings": {"artifact": self.binding, "qualification": {"domain": "text-utf8-lf-v1", "sha256": "a" * 64}}}
        self.policy = self.work / "security.json"
        now = dt.datetime.now(dt.timezone.utc)
        self.disposition = {"schema_version": 1, "purpose": "nonproduction-rollback", "decision": "ALLOW",
                            "artifact": self.binding, "qualification": self.report["bindings"]["qualification"],
                            "candidate_sha256": "b" * 64, "signing_commit": "c" * 40,
                            "issued_at": (now - dt.timedelta(minutes=1)).isoformat(),
                            "expires_at": (now + dt.timedelta(hours=1)).isoformat(),
                            "advisory_review_complete": True, "advisories": []}
        self.review_root = self.work / 'review-fixture'
        for relative in rollback.REVIEW_PATHS:
            path = self.review_root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            signing.atomic_json(path, {'findings': [{'id': 'FIXTURE-FINDING', 'status': 'OPEN'}],
                'coverageGaps': [{'id': 'FIXTURE-GAP', 'status': 'NOT_COMPLETED'}]})
        intake = self.review_root / rollback.INTAKE
        intake.parent.mkdir(parents=True, exist_ok=True)
        response = intake.parent / 'advisory-repository-advisories.txt'
        response.write_text(json.dumps([{'ghsa_id': 'GHSA-test-0000-0000'}]))
        signing.atomic_json(intake, {'status': 'PASS', 'advisory_intake': {'channels': [
            {'channel': 'repository-advisories', 'status': 'AVAILABLE', 'intake_utc': now.isoformat(),
             'response': response.name, 'digest': digest.text_evidence_digest(response).to_json()}]}})
        with mock.patch.object(rollback, 'ROOT', self.review_root):
            inputs, known = rollback.security_requirements()
        self.disposition['current_review_inputs'] = inputs
        self.disposition['advisories'] = [{'id': identity, 'disposition': 'not_affected',
            'evidence': 'test-only-fixture'} for identity in sorted(known)]
        self.args = argparse.Namespace(security_disposition=self.policy, security_key=Path(str(self.key) + ".pub"),
                                       security_key_sha256=digest.artifact_byte_sha256(Path(str(self.key) + ".pub")),
                                       candidate_sha256="b" * 64, signing_commit="c" * 40)

    def sign(self):
        signing.atomic_json(self.policy, self.disposition)
        signing.sign_file(self.key, self.policy, Path(str(self.policy) + ".sig"))

    def check_security(self):
        with mock.patch.object(rollback, 'ROOT', self.review_root):
            rollback.security(self.args, self.report)

    def rejected(self, code):
        with self.assertRaises(signing.ReleaseError) as result:
            self.check_security()
        self.assertEqual(result.exception.code, code)

    def test_valid_nonproduction_disposition_signature(self):
        self.sign()
        self.check_security()
        self.assertEqual(self.report["security"]["status"], "PASS")

    def test_tampered_signed_disposition(self):
        self.sign()
        self.policy.write_bytes(self.policy.read_bytes() + b" ")
        self.rejected("SIGNATURE_INVALID")

    def test_replaced_authority_key(self):
        self.sign()
        self.args.security_key_sha256 = "0" * 64
        self.rejected("SECURITY_KEY_DRIFT")

    def test_wrong_artifact_even_with_valid_signature(self):
        self.disposition["artifact"] = {"domain": "artifact-bytes-v1", "sha256": "d" * 64}
        self.sign()
        self.rejected("SECURITY_BINDING")

    def test_stale_signed_disposition(self):
        self.disposition["expires_at"] = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(seconds=1)).isoformat()
        self.sign()
        self.rejected("SECURITY_STALE")

    def test_unresolved_advisory_not_waived(self):
        self.disposition["advisories"] = [{"id": "TEST-ADVISORY", "disposition": "risk_accepted", "evidence": "test-only"}]
        self.sign()
        self.rejected("SECURITY_UNRESOLVED")

    def test_current_findings_cannot_be_omitted(self):
        self.disposition["advisories"] = []
        self.sign()
        self.rejected("SECURITY_OMISSION")

    def test_fresh_public_advisories_cannot_be_omitted(self):
        self.disposition['advisories'] = [item for item in self.disposition['advisories']
            if not item['id'].startswith('GHSA-')]
        self.sign()
        self.rejected("SECURITY_OMISSION")

    def test_review_coverage_gaps_cannot_be_omitted(self):
        self.disposition['advisories'] = [item for item in self.disposition['advisories']
            if item['id'] != 'FIXTURE-GAP']
        self.sign()
        self.rejected('SECURITY_OMISSION')

    def test_changed_official_response_invalidates_signed_disposition(self):
        self.sign()
        response = self.review_root / Path(rollback.INTAKE).parent / 'advisory-repository-advisories.txt'
        response.write_text('[]')
        self.rejected('SECURITY_INTAKE_DRIFT')

    def test_preflight_cannot_be_security_disposition(self):
        self.disposition = {"kind": "qualified-sdk-preflight", "status": "PASS"}
        self.sign()
        self.rejected("SECURITY_TIME")

    def deployment(self):
        deployed = self.work / "deployment"
        deployed.mkdir()
        (deployed / ".wirestack-nonproduction").write_text("M12-004\n")
        candidate = b"installed candidate bytes"
        current_digest = digest.artifact_byte_digest_bytes(candidate).to_json()
        version = deployed / "versions" / current_digest["sha256"]
        version.mkdir(parents=True)
        (version / "artifact.tar.gz").write_bytes(candidate)
        signing.atomic_json(deployed / "current.json", {"artifact": current_digest, "version": version.name})
        history = self.work / "signatures"
        history.mkdir(parents=True)
        (history / "artifact.sigstore.json").write_bytes(b"original signature bytes")
        return argparse.Namespace(deployment=deployed, work_root=self.work, candidate_sha256=current_digest["sha256"], history_root=self.work)

    def test_atomic_restore_preserves_exact_archive_and_original_sidecar(self):
        args = self.deployment()
        before = (args.deployment / "current.json").read_bytes()
        rollback.restore(args, self.artifact, self.report)
        version = args.deployment / "versions" / self.binding["sha256"]
        self.assertEqual((version / "artifact.tar.gz").read_bytes(), self.artifact.read_bytes())
        self.assertEqual((version / "artifact.sigstore.json").read_bytes(), b"original signature bytes")
        self.assertEqual((args.deployment / "previous-current.json").read_bytes(), before)
        self.assertEqual(json.loads((args.deployment / "current.json").read_text())["artifact"], self.binding)

    def test_candidate_drift_leaves_active_deployment_unchanged(self):
        args = self.deployment()
        before = (args.deployment / "current.json").read_bytes()
        (args.deployment / "versions" / args.candidate_sha256 / "artifact.tar.gz").write_bytes(b"changed candidate")
        with self.assertRaises(signing.ReleaseError) as result:
            rollback.restore(args, self.artifact, self.report)
        self.assertEqual(result.exception.code, "DEPLOYMENT_CHANGED")
        self.assertEqual((args.deployment / "current.json").read_bytes(), before)

    def test_actual_cli_rejects_missing_archive_without_replacement(self):
        args = self.deployment()
        before = (args.deployment / "current.json").read_bytes()
        output = self.work / "result.json"
        command = ["python3", str(Path(rollback.__file__)), "--artifact", str(self.work / "missing.tar.gz"),
                   "--history-root", str(self.work), "--qualification", str(self.work / "missing.json"),
                   "--sdk-root", str(Path.home() / "cangjie_sdk/sts1.1.3"), "--work-root", str(self.work),
                   "--deployment", str(args.deployment), "--output", str(output), "--signing-commit", "c" * 40,
                   "--candidate-sha256", args.candidate_sha256, "--restore"]
        result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=30)
        self.assertEqual(result.returncode, 1, result.stderr)
        report = json.loads(output.read_text())
        self.assertEqual(report["blocker"]["code"], "ARTIFACT_BOUND")
        self.assertTrue(report["deployment_unchanged"])
        self.assertEqual((args.deployment / "current.json").read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
