from __future__ import annotations

import copy
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from tools import evidence_digest
from tools import m8_007_signing_authorization as authorization


class M8007SigningAuthorizationTest(unittest.TestCase):
    def fixture(self) -> tuple[tempfile.TemporaryDirectory[str], Path, dict]:
        directory = tempfile.TemporaryDirectory()
        root = Path(directory.name)
        for relative in authorization.POLICY_FILES:
            target = root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes((authorization.ROOT / relative).read_bytes())
        policy = {
            "schema_version": 1,
            "source_task": "M8-007",
            "status": "PASS",
            "captured_at": "2026-09-14T00:00:00Z",
            "api_version": authorization.API_VERSION,
            "repository": {
                "id": authorization.REPOSITORY_ID,
                "full_name": f"{authorization.OWNER}/{authorization.REPOSITORY}",
                "private": False,
            },
            "authority": {
                "id": authorization.RELEASE_OWNER_ID,
                "login": authorization.OWNER,
                "repository_admin": True,
            },
            "initial": {
                "environment": {"state": "ABSENT"},
                "deployment_branch_policies": [],
                "approved_sha_variable": {"state": "ABSENT"},
                "repository_rulesets": [],
            },
            "configured": {
                "environment": self.environment(),
                "deployment_branch_policies": [
                    {"id": 31, "name": authorization.SIGNING_TAG_PATTERN, "type": "tag"}
                ],
                "approved_sha_variable": {"state": "ABSENT"},
                "signing_rulesets": self.rulesets(),
            },
            "non_admin_probe": {
                "status": "NOT_RUN",
                "reason": "non-admin credential unavailable",
                "claim": "No non-admin enforcement probe was performed",
            },
            "files": authorization._file_records(root),
        }
        evidence_digest.atomic_json(root / authorization.POLICY_RELATIVE, policy)
        return directory, root, policy

    def environment(self) -> dict:
        return {
            "state": "PRESENT",
            "id": 21,
            "name": authorization.ENVIRONMENT,
            "can_admins_bypass": False,
            "protection_rules": [
                {
                    "id": 22,
                    "type": "required_reviewers",
                    "prevent_self_review": False,
                    "reviewers": [
                        {
                            "type": "User",
                            "id": authorization.RELEASE_OWNER_ID,
                            "login": authorization.OWNER,
                        }
                    ],
                }
            ],
            "deployment_branch_policy": {
                "protected_branches": False,
                "custom_branch_policies": True,
            },
        }

    def rulesets(self) -> list[dict]:
        result = []
        for index, payload in enumerate(
            (
                authorization._creation_ruleset_payload(),
                authorization._immutable_ruleset_payload(),
            ),
            start=41,
        ):
            item = copy.deepcopy(payload)
            item["id"] = index
            result.append(item)
        return sorted(result, key=lambda item: item["name"])

    def approval(self, root: Path, policy: dict, commit: str) -> dict:
        return {
            "schema_version": 1,
            "source_task": "M8-007",
            "status": "PASS",
            "approved_at": "2026-09-14T01:00:00Z",
            "approved_source_commit": commit,
            "approved_ref": f"refs/tags/m8-007-signing-{commit}",
            "approved_by": {
                "id": authorization.RELEASE_OWNER_ID,
                "login": authorization.OWNER,
            },
            "selection": {"method": "explicit-cli-argument", "hosted_report_used": False},
            "repository": {
                "id": authorization.REPOSITORY_ID,
                "full_name": f"{authorization.OWNER}/{authorization.REPOSITORY}",
            },
            "remote_commit": {
                "repository_id": authorization.REPOSITORY_ID,
                "sha": commit,
                "api_url": f"https://api.github.test/git/commits/{commit}",
            },
            "policy": {
                "path": authorization.POLICY_RELATIVE,
                "digest": evidence_digest.text_evidence_digest(
                    root / authorization.POLICY_RELATIVE
                ).to_json(),
            },
            "files": policy["files"],
            "configured": {
                "environment": self.environment(),
                "deployment_branch_policies": [
                    {"id": 31, "name": f"m8-007-signing-{commit}", "type": "tag"}
                ],
                "approved_sha_variable": {
                    "state": "PRESENT",
                    "name": authorization.APPROVED_SHA_VARIABLE,
                    "value": commit,
                    "created_at": "2026-09-14T01:00:00Z",
                    "updated_at": "2026-09-14T01:00:00Z",
                },
                "signing_rulesets": self.rulesets(),
            },
            "non_admin_probe": {
                "status": "NOT_RUN",
                "reason": "non-admin credential unavailable",
                "claim": "No non-admin enforcement probe was performed",
            },
        }

    def test_policy_binds_typed_frozen_files_and_rejects_mutation(self) -> None:
        directory, root, policy = self.fixture()
        self.addCleanup(directory.cleanup)
        self.assertEqual("PASS", authorization.verify_policy(root)["status"])

        workflow = root / authorization.WORKFLOW_RELATIVE
        workflow.write_bytes(workflow.read_bytes() + b"\n")
        with self.assertRaisesRegex(authorization.ReleaseError, "changed after policy capture"):
            authorization.verify_policy(root)

        workflow.write_bytes((authorization.ROOT / authorization.WORKFLOW_RELATIVE).read_bytes())
        policy["files"][0]["digest"]["domain"] = evidence_digest.ARTIFACT_BYTE_DOMAIN
        evidence_digest.atomic_json(root / authorization.POLICY_RELATIVE, policy)
        with self.assertRaisesRegex(authorization.ReleaseError, "digest domain"):
            authorization.verify_policy(root)

    def test_policy_requires_owner_approval_not_an_alternative_reviewer(self) -> None:
        directory, root, policy = self.fixture()
        self.addCleanup(directory.cleanup)
        reviewers = policy["configured"]["environment"]["protection_rules"][0]["reviewers"]
        reviewers.append({"type": "User", "id": 7, "login": "other-reviewer"})
        evidence_digest.atomic_json(root / authorization.POLICY_RELATIVE, policy)
        with self.assertRaises(authorization.ReleaseError):
            authorization.verify_policy(root)

    def test_approval_is_explicit_and_binds_exact_ref_variable_and_remote_commit(self) -> None:
        directory, root, policy = self.fixture()
        self.addCleanup(directory.cleanup)
        commit = "a" * 40
        approval = self.approval(root, policy, commit)
        evidence_digest.atomic_json(root / authorization.APPROVAL_RELATIVE, approval)
        self.assertEqual(commit, authorization.approved_source_commit(root))

        hosted = copy.deepcopy(approval)
        hosted["selection"] = {"method": "hosted-report", "hosted_report_used": True}
        evidence_digest.atomic_json(root / authorization.APPROVAL_RELATIVE, hosted)
        with self.assertRaisesRegex(authorization.ReleaseError, "hosted metadata"):
            authorization.approved_source_commit(root)

        mismatched = copy.deepcopy(approval)
        mismatched["configured"]["approved_sha_variable"]["value"] = "b" * 40
        evidence_digest.atomic_json(root / authorization.APPROVAL_RELATIVE, mismatched)
        with self.assertRaisesRegex(authorization.ReleaseError, "environment does not bind"):
            authorization.approved_source_commit(root)

    def test_capture_requires_release_owner_admin_before_any_policy_write(self) -> None:
        calls: list[tuple[str, str]] = []

        def api(method: str, endpoint: str, *_args, **_kwargs):
            calls.append((method, endpoint))
            if endpoint == "user":
                return {"id": 7, "login": "not-release-owner"}
            return {
                "id": authorization.REPOSITORY_ID,
                "full_name": f"{authorization.OWNER}/{authorization.REPOSITORY}",
                "permissions": {"admin": True},
            }

        with tempfile.TemporaryDirectory() as directory, mock.patch.object(
            authorization, "_gh_api", side_effect=api
        ):
            with self.assertRaisesRegex(authorization.ReleaseError, "lacks admin authority"):
                authorization.capture_policy(Path(directory))
        self.assertFalse(any(method in {"POST", "PUT", "PATCH", "DELETE"} for method, _ in calls))

    def test_approve_source_preserves_frozen_policy_and_publishes_exact_approval(self) -> None:
        directory, root, policy = self.fixture()
        self.addCleanup(directory.cleanup)
        commit = "c" * 40
        frozen_policy = (root / authorization.POLICY_RELATIVE).read_bytes()
        state = {"tag": authorization.SIGNING_TAG_PATTERN, "variable": None}
        raw_environment = {
            "id": 21,
            "name": authorization.ENVIRONMENT,
            "can_admins_bypass": False,
            "protection_rules": [{
                "id": 22,
                "type": "required_reviewers",
                "prevent_self_review": False,
                "reviewers": [{
                    "type": "User",
                    "reviewer": {"id": authorization.RELEASE_OWNER_ID, "login": authorization.OWNER},
                }],
            }],
            "deployment_branch_policy": {"protected_branches": False, "custom_branch_policies": True},
        }

        def api(method: str, endpoint: str, payload=None, **_kwargs):
            if endpoint.endswith(f"/git/commits/{commit}") and method == "GET":
                return {"sha": commit, "url": f"https://api.github.test/git/commits/{commit}"}
            if endpoint.endswith(f"/environments/{authorization.ENVIRONMENT}") and method == "GET":
                return raw_environment
            if endpoint.endswith("/deployment-branch-policies") and method == "GET":
                return {"branch_policies": [{"id": 31, "name": state["tag"], "type": "tag"}]}
            if endpoint.endswith("/deployment-branch-policies/31") and method == "PUT":
                state["tag"] = payload["name"]
                return {"id": 31, "name": state["tag"], "type": "tag"}
            if endpoint.endswith(f"/variables/{authorization.APPROVED_SHA_VARIABLE}") and method == "GET":
                return state["variable"]
            if endpoint.endswith("/variables") and method == "POST":
                if state["tag"] != f"m8-007-signing-{commit}":
                    raise AssertionError("approval became available before the deployment policy narrowed")
                state["variable"] = {**payload, "created_at": "2026-09-14T01:00:00Z",
                                     "updated_at": "2026-09-14T01:00:00Z"}
                return None
            raise AssertionError((method, endpoint, payload))

        user = {"id": authorization.RELEASE_OWNER_ID, "login": authorization.OWNER}
        repository = {
            "id": authorization.REPOSITORY_ID,
            "full_name": f"{authorization.OWNER}/{authorization.REPOSITORY}",
            "permissions": {"admin": True},
        }
        with (
            mock.patch.object(authorization, "_gh_api", side_effect=api),
            mock.patch.object(authorization, "_authority", return_value=(user, repository)),
            mock.patch.object(authorization, "_signing_rulesets", return_value=self.rulesets()),
        ):
            authorization.approve_source(commit, root)

        self.assertEqual(commit, authorization.approved_source_commit(root))
        self.assertEqual(f"m8-007-signing-{commit}", state["tag"])
        self.assertEqual(commit, state["variable"]["value"])
        self.assertEqual(frozen_policy, (root / authorization.POLICY_RELATIVE).read_bytes())


if __name__ == "__main__":
    unittest.main()
