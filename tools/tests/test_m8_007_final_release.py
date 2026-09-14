from __future__ import annotations

import contextlib
import io
import json
import unittest
from unittest import mock

from tools import m8_007_final_release as final_release


class M8007FinalReleaseTest(unittest.TestCase):
    def test_verify_all_rejects_hosted_revision_not_independently_approved(self) -> None:
        approved = "a" * 40
        approval = mock.Mock()
        approval.approved_source_commit.return_value = approved
        hosted = {
            "source_task": final_release.TASK_ID,
            "decision": "PASS",
            "source_revision": "b" * 40,
        }
        output = io.StringIO()
        with (
            mock.patch.object(final_release.release, "load_json", return_value=hosted),
            mock.patch.object(final_release, "authorization", approval, create=True),
            mock.patch.object(final_release, "verify_signatures", return_value={"decision": "PASS"}),
            contextlib.redirect_stdout(output),
        ):
            self.assertEqual(1, final_release.main(["verify-all"]))
        self.assertEqual("FAIL", json.loads(output.getvalue())["decision"])

    def test_frozen_command_rejects_weakened_release_contract(self) -> None:
        command = {"id": "final-candidate-soak", "argv": ["soak", "86400"]}
        original = {"source_paths": ["source.cj"], "required_evidence": ["report.json"],
                    "acceptance_commands": [command]}
        current = {**original, "required_evidence": []}
        with (
            mock.patch.object(final_release.repository, "load_task", return_value=current),
            mock.patch.object(final_release.subprocess, "run", return_value=mock.Mock(
                returncode=0, stdout=json.dumps(original))),
        ):
            with self.assertRaises(final_release.release.ReleaseError):
                final_release.frozen_command("a" * 40)

    def _verify_approved_report(self, current: dict, approved_task: dict) -> tuple[int, dict]:
        approved = "a" * 40
        approval = mock.Mock()
        approval.approved_source_commit.return_value = approved
        hosted = {"source_task": final_release.TASK_ID, "decision": "PASS", "source_revision": approved}
        output = io.StringIO()
        with (
            mock.patch.object(final_release.release, "load_json", return_value=hosted),
            mock.patch.object(final_release, "authorization", approval, create=True),
            mock.patch.object(final_release.repository, "load_task", return_value=current),
            mock.patch.object(final_release.subprocess, "run", return_value=mock.Mock(
                returncode=0, stdout=json.dumps(approved_task))),
            mock.patch.object(final_release, "verify_signatures", return_value={"decision": "PASS"}),
            contextlib.redirect_stdout(output),
        ):
            status = final_release.main(["verify-all"])
        return status, json.loads(output.getvalue())

    @staticmethod
    def _signing_inputs() -> list[str]:
        return [
            f"docs/evidence/M8-007/linux_x86_64/{name}"
            for name in (
                "frozen-candidate.json", "soak.json", "soak.log",
                "commands/formal-soak/final-candidate-soak.stdout.log",
                "commands/formal-soak/final-candidate-soak.stderr.log",
                "signatures/release-manifest.json", "signatures/artifact.sigstore.json",
                "signatures/sbom.sigstore.json", "signatures/release-manifest.sigstore.json",
            )
        ]

    def test_verify_all_rejects_unarchived_signing_inputs(self) -> None:
        task = {"source_paths": ["source.cj"], "required_evidence": ["report.json"]}
        current = {**task, "source_paths": task["source_paths"] + self._signing_inputs()[:-1]}
        status, result = self._verify_approved_report(current, task)
        self.assertEqual(1, status)
        self.assertEqual("FAIL", result["decision"])

    def test_verify_all_rejects_unarchived_formal_inputs(self) -> None:
        task = {"source_paths": ["source.cj"], "required_evidence": ["report.json"]}
        current = {**task, "source_paths": task["source_paths"] + [
            path for path in self._signing_inputs() if "/signatures/" in path
        ]}
        status, result = self._verify_approved_report(current, task)
        self.assertEqual(1, status)
        self.assertEqual("FAIL", result["decision"])

    def test_verify_all_rejects_weakened_approved_task(self) -> None:
        task = {"source_paths": ["source.cj"], "required_evidence": ["report.json"]}
        current = {"source_paths": task["source_paths"] + self._signing_inputs(), "required_evidence": []}
        status, result = self._verify_approved_report(current, task)
        self.assertEqual(1, status)
        self.assertEqual("FAIL", result["decision"])

    def test_verify_all_rejects_removed_approved_source_input(self) -> None:
        task = {"source_paths": ["source.cj"], "required_evidence": ["report.json"]}
        current = {**task, "source_paths": self._signing_inputs()}
        status, result = self._verify_approved_report(current, task)
        self.assertEqual(1, status)
        self.assertEqual("FAIL", result["decision"])

    def test_verify_all_accepts_additive_signing_proof_without_contract_changes(self) -> None:
        task = {"source_paths": ["source.cj"], "required_evidence": ["report.json"]}
        current = {**task, "source_paths": task["source_paths"] + self._signing_inputs() + ["command.stdout.log"]}
        status, result = self._verify_approved_report(current, task)
        self.assertEqual(0, status)
        self.assertEqual("PASS", result["decision"])



if __name__ == "__main__":
    unittest.main()
