from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from tools import m12_004_verifier_controls as controls
from tools import m7_030_linux_release as signing


class VerifierControlsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        parent = Path(os.environ.get("M12_004_TEST_SCRATCH", Path.home() / ".cache/agent-tmp"))
        parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        cls.temporary = tempfile.TemporaryDirectory(prefix="m12-004-tests-", dir=parent)
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.scratch = Path(cls.temporary.name)
        cls.output = cls.scratch / "verification.json"
        cls.command = [sys.executable, "tools/m12_004_verifier_controls.py", "--scratch-parent",
                       str(cls.scratch), "--output", str(cls.output)]
        cls.execution = subprocess.run(cls.command, cwd=controls.ROOT, capture_output=True, text=True, timeout=190)
        cls.report = json.loads(cls.output.read_text())

    def test_real_cli_rejects_all_mutations_with_exact_codes(self):
        self.assertEqual(0, self.execution.returncode, self.execution.stdout)
        expected = {
            "archive-replacement": "SUBJECT_DIGEST",
            "native-static-archive-replacement": "NATIVE_ARCHIVE_PROVENANCE",
            "sbom-mismatch": "SUBJECT_DIGEST",
            "missing-artifact-signature": "SIGNATURE_MISSING",
            "missing-sbom-signature": "SIGNATURE_MISSING",
            "missing-release-manifest-signature": "SIGNATURE_MISSING",
            "wrong-source-binding": "SIGNATURE_INVALID",
            "signed-wrong-source-policy": "MANIFEST_POLICY",
            "wrong-signer": "SIGNATURE_INVALID",
            "stale-supply-report": "SUPPLY_CHAIN_STALE",
            "stale-candidate-fuzz-report": "STALE_FUZZ_INPUTS",
            "keylog-capabilities": "KEYLOG_CAPABILITY_FORBIDDEN",
            "keylog-test_only_key_log": "KEYLOG_CAPABILITY_FORBIDDEN",
        }
        observed = self.report["controls"]
        self.assertEqual(expected, {item["id"]: item["error"] for item in observed})
        self.assertTrue(all(item["status"] == "PASS" for item in observed))
        self.assertEqual(len(expected), len(observed))

    def test_positive_fixtures_native_smoke_and_originals(self):
        self.assertEqual("PASS", self.report["offline_positive"]["decision"])
        self.assertEqual("PASS", self.report["offline_restored"]["decision"])
        self.assertEqual("PASS", self.report["native_payload_positive"])
        self.assertEqual("PASS", self.report["native_smoke"]["status"])
        self.assertTrue(self.report["original_inputs_untouched"])
        self.assertTrue(self.report["temporary_material_removed"])
        self.assertEqual(["verification.json"], [path.name for path in self.scratch.iterdir()])
        self.assertEqual([0, 0, 0, 0], [item["exit_code"] for item in self.report["commands"]])

    def test_report_cannot_claim_candidate_or_sdk_qualification(self):
        self.assertEqual(1, self.report["schema_version"])
        self.assertEqual("M12-004", self.report["task_id"])
        self.assertEqual("verifier-controls", self.report["family"])
        self.assertEqual("STS_ONLY", self.report["SDKpolicy"])
        self.assertEqual("NOT_QUALIFIED", self.report["qualification"])
        self.assertEqual("NOT_QUALIFIED", self.report["historical_fuzz_baseline"]["qualification"])
        self.assertTrue(self.report["limitations"])
        serialized = json.dumps(self.report)
        for secret in (str(Path.home()), str(controls.ROOT), str(self.scratch), "OPENSSH PRIVATE KEY"):
            self.assertNotIn(secret, serialized)

    def test_unrelated_errors_and_accidental_acceptance_never_pass(self):
        def unrelated():
            raise signing.ReleaseError("COMMAND_UNAVAILABLE", "ssh-keygen")
        rejected = controls.rejection("wrong-signer", "SIGNATURE_INVALID", "real-verifier", unrelated, {})
        self.assertEqual("FAIL", rejected["status"])
        self.assertEqual("COMMAND_UNAVAILABLE", rejected["error"])
        accepted = controls.rejection("wrong-signer", "SIGNATURE_INVALID", "real-verifier", lambda: None, {})
        self.assertEqual("FAIL", accepted["status"])
        self.assertEqual("ACCEPTED_MUTATION", accepted["error"])

    def test_message_text_cannot_override_structured_rejection_code(self):
        def unexpected():
            raise controls.payload_release.ReleaseError(
                "test-only TLS key logging cannot enter a release artifact", code="UNRELATED_FAILURE")
        observed = controls.rejection("keylog", "KEYLOG_CAPABILITY_FORBIDDEN", "collector", unexpected, {})
        self.assertEqual("FAIL", observed["status"])
        self.assertEqual("UNRELATED_FAILURE", observed["error"])
        self.assertEqual("UNEXPECTED_VERIFIER_ERROR", controls.error_code(RuntimeError(
            "test-only TLS key logging cannot enter a release artifact")))

    def test_external_native_artifact_is_bound_preserved_and_sanitized(self):
        from tools import evidence_digest as digest
        with tempfile.TemporaryDirectory(prefix="external-input-", dir=self.scratch) as directory:
            root = Path(directory)
            selected = root / "private-machine-input.tar.gz"
            selected.write_bytes(controls.NATIVE.read_bytes())
            expected = digest.artifact_byte_digest(selected).to_json()
            output = root / "external-verification.json"
            execution = subprocess.run([sys.executable, "tools/m12_004_verifier_controls.py",
                "--scratch-parent", str(root), "--native-artifact", str(selected),
                "--output", str(output)], cwd=controls.ROOT, capture_output=True, text=True, timeout=190)
            report = json.loads(output.read_text())
            self.assertEqual(0, execution.returncode, execution.stdout)
            self.assertEqual({"path": "<external-native-artifact>", "digest": expected}, report["native_artifact"])
            self.assertEqual(expected, digest.artifact_byte_digest(selected).to_json())
            self.assertTrue(report["original_inputs_untouched"])
            self.assertTrue(report["temporary_material_removed"])
            self.assertNotIn(str(root), json.dumps(report))
            self.assertNotIn(selected.name, json.dumps(report))


if __name__ == "__main__":
    unittest.main()
