#!/usr/bin/env python3
"""Configure and verify independent authorization for M8-007 release signing."""

from __future__ import annotations

if __package__ in {None, ""}:
    import sys
    from pathlib import Path

    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import argparse
import json
import re
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Mapping, Sequence

from tools import evidence_digest
from tools.m7_021_linux_release import ReleaseError

ROOT = Path(__file__).resolve().parents[1]
POLICY_RELATIVE = "docs/evidence/M8-007/linux_x86_64/signing-authorization.json"
APPROVAL_RELATIVE = "docs/evidence/M8-007/linux_x86_64/signing-approval.json"
WORKFLOW_RELATIVE = ".github/workflows/m8-007-linux-release-attestation.yml"
TOOL_RELATIVE = "tools/m8_007_signing_authorization.py"
POLICY_FILES = (WORKFLOW_RELATIVE, TOOL_RELATIVE)

OWNER = "lIlIIlIll"
REPOSITORY = "Wirestack"
REPOSITORY_ID = 1342891507
RELEASE_OWNER_ID = 180488944
ENVIRONMENT = "m8-007-release"
APPROVED_SHA_VARIABLE = "M8_007_APPROVED_SIGNING_SHA"
SIGNING_TAG_PATTERN = "m8-007-signing-*"
CREATION_RULESET_NAME = "M8-007 signing tags administrators only"
IMMUTABLE_RULESET_NAME = "M8-007 signing tags immutable"
ADMINISTRATOR_ROLE_ID = 5
API_VERSION = "2022-11-28"
SHA_RE = re.compile(r"^[0-9a-f]{40}$")


class AuthorizationError(ReleaseError):
    """Raised when signing authorization is absent, stale, or ambiguous."""


def _now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def _object_pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise AuthorizationError(f"SIGNING_JSON_DUPLICATE: duplicate key {key}")
        result[key] = value
    return result


def _load_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=_object_pairs)
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise AuthorizationError(f"SIGNING_JSON_INVALID: {path}: {error}") from error
    if not isinstance(value, dict):
        raise AuthorizationError(f"SIGNING_JSON_INVALID: {path} must contain an object")
    return value


def _gh_api(
    method: str,
    endpoint: str,
    payload: Mapping[str, Any] | None = None,
    *,
    allow_not_found: bool = False,
) -> Any:
    command = [
        "gh",
        "api",
        "--method",
        method,
        "-H",
        "Accept: application/vnd.github+json",
        "-H",
        f"X-GitHub-Api-Version: {API_VERSION}",
        endpoint,
    ]
    serialized = None
    if payload is not None:
        command.extend(["--input", "-"])
        serialized = json.dumps(payload, sort_keys=True, separators=(",", ":"))
    completed = subprocess.run(
        command,
        input=serialized,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if completed.returncode != 0:
        status = re.search(r"HTTP (\d{3})", completed.stderr)
        if allow_not_found and status is not None and status.group(1) == "404":
            return None
        code = status.group(1) if status is not None else "UNKNOWN"
        detail = " ".join((completed.stdout + " " + completed.stderr).split())[:500]
        raise AuthorizationError(
            f"GITHUB_API_{code}: {method} {endpoint} failed: {detail or 'no response detail'}"
        )
    if not completed.stdout.strip():
        return None
    try:
        return json.loads(completed.stdout, object_pairs_hook=_object_pairs)
    except json.JSONDecodeError as error:
        raise AuthorizationError(f"GITHUB_API_JSON: {method} {endpoint}") from error


def _repository_endpoint(suffix: str) -> str:
    return f"repos/{OWNER}/{REPOSITORY}{suffix}"


def _environment_endpoint(suffix: str = "") -> str:
    return _repository_endpoint(f"/environments/{ENVIRONMENT}{suffix}")


def _ruleset_shape(ruleset: Mapping[str, Any]) -> dict[str, Any]:
    rules = []
    for rule in ruleset.get("rules", []):
        item = {"type": rule.get("type")}
        if "parameters" in rule:
            item["parameters"] = rule["parameters"]
        rules.append(item)
    actors = [
        {
            "actor_id": actor.get("actor_id"),
            "actor_type": actor.get("actor_type"),
            "bypass_mode": actor.get("bypass_mode"),
        }
        for actor in ruleset.get("bypass_actors", [])
    ]
    return {
        "id": ruleset.get("id"),
        "name": ruleset.get("name"),
        "target": ruleset.get("target"),
        "enforcement": ruleset.get("enforcement"),
        "conditions": ruleset.get("conditions"),
        "bypass_actors": actors,
        "rules": rules,
    }


def _environment_shape(environment: Mapping[str, Any] | None) -> dict[str, Any]:
    if environment is None:
        return {"state": "ABSENT"}
    protection_rules = []
    for rule in environment.get("protection_rules", []):
        item: dict[str, Any] = {"id": rule.get("id"), "type": rule.get("type")}
        if rule.get("type") == "required_reviewers":
            item["prevent_self_review"] = rule.get("prevent_self_review")
            item["reviewers"] = [
                {
                    "type": reviewer.get("type"),
                    "id": (reviewer.get("reviewer") or {}).get("id"),
                    "login": (reviewer.get("reviewer") or {}).get("login"),
                }
                for reviewer in rule.get("reviewers", [])
            ]
        elif rule.get("type") == "wait_timer":
            item["wait_timer"] = rule.get("wait_timer")
        protection_rules.append(item)
    result = {
        "state": "PRESENT",
        "id": environment.get("id"),
        "name": environment.get("name"),
        "protection_rules": protection_rules,
        "deployment_branch_policy": environment.get("deployment_branch_policy"),
    }
    if "can_admins_bypass" in environment:
        result["can_admins_bypass"] = environment.get("can_admins_bypass")
    return result


def _policy_shape(policies: Mapping[str, Any] | None) -> list[dict[str, Any]]:
    if policies is None:
        return []
    return [
        {"id": item.get("id"), "name": item.get("name"), "type": item.get("type")}
        for item in policies.get("branch_policies", [])
    ]


def _variable_shape(variable: Mapping[str, Any] | None) -> dict[str, Any]:
    if variable is None:
        return {"state": "ABSENT"}
    return {
        "state": "PRESENT",
        "name": variable.get("name"),
        "value": variable.get("value"),
        "created_at": variable.get("created_at"),
        "updated_at": variable.get("updated_at"),
    }


def _signing_rulesets() -> list[dict[str, Any]]:
    listed = _gh_api("GET", _repository_endpoint("/rulesets"))
    if not isinstance(listed, list):
        raise AuthorizationError("RULESET_API: repository rulesets response is invalid")
    result = []
    for item in listed:
        if item.get("name") in {CREATION_RULESET_NAME, IMMUTABLE_RULESET_NAME}:
            detail = _gh_api("GET", _repository_endpoint(f"/rulesets/{item.get('id')}"))
            if not isinstance(detail, dict):
                raise AuthorizationError("RULESET_API: ruleset detail response is invalid")
            result.append(_ruleset_shape(detail))
    return sorted(result, key=lambda item: str(item["name"]))


def _target_variable() -> dict[str, Any] | None:
    result = _gh_api(
        "GET",
        _environment_endpoint(f"/variables/{APPROVED_SHA_VARIABLE}"),
        allow_not_found=True,
    )
    if result is not None and not isinstance(result, dict):
        raise AuthorizationError("ENVIRONMENT_VARIABLE_API: response is invalid")
    return result


def _authority() -> tuple[dict[str, Any], dict[str, Any]]:
    user = _gh_api("GET", "user")
    repository = _gh_api("GET", _repository_endpoint(""))
    if not isinstance(user, dict) or not isinstance(repository, dict):
        raise AuthorizationError("SIGNING_AUTHORITY: GitHub identity response is invalid")
    permissions = repository.get("permissions") or {}
    if (
        user.get("login") != OWNER
        or user.get("id") != RELEASE_OWNER_ID
        or repository.get("id") != REPOSITORY_ID
        or permissions.get("admin") is not True
    ):
        raise AuthorizationError(
            "SIGNING_AUTHORITY: authenticated release owner lacks admin authority"
        )
    return user, repository


def _creation_ruleset_payload() -> dict[str, Any]:
    return {
        "name": CREATION_RULESET_NAME,
        "target": "tag",
        "enforcement": "active",
        "bypass_actors": [
            {
                "actor_id": ADMINISTRATOR_ROLE_ID,
                "actor_type": "RepositoryRole",
                "bypass_mode": "always",
            }
        ],
        "conditions": {
            "ref_name": {"include": [f"refs/tags/{SIGNING_TAG_PATTERN}"], "exclude": []}
        },
        "rules": [{"type": "creation"}],
    }


def _immutable_ruleset_payload() -> dict[str, Any]:
    return {
        "name": IMMUTABLE_RULESET_NAME,
        "target": "tag",
        "enforcement": "active",
        "bypass_actors": [],
        "conditions": {
            "ref_name": {"include": [f"refs/tags/{SIGNING_TAG_PATTERN}"], "exclude": []}
        },
        "rules": [{"type": "deletion"}, {"type": "update"}],
    }


def _validate_ruleset(actual: Mapping[str, Any], expected: Mapping[str, Any]) -> None:
    for key in ("name", "target", "enforcement", "conditions", "bypass_actors"):
        if actual.get(key) != expected.get(key):
            raise AuthorizationError(f"RULESET_POLICY: {expected['name']} has invalid {key}")
    actual_rules = actual.get("rules")
    expected_rules = expected.get("rules")
    if not isinstance(actual_rules, list) or {
        json.dumps(item, sort_keys=True) for item in actual_rules
    } != {json.dumps(item, sort_keys=True) for item in expected_rules}:
        raise AuthorizationError(f"RULESET_POLICY: {expected['name']} has invalid rules")
    if not isinstance(actual.get("id"), int):
        raise AuthorizationError(f"RULESET_POLICY: {expected['name']} has no stable id")


def _ensure_rulesets() -> list[dict[str, Any]]:
    existing = {item["name"]: item for item in _signing_rulesets()}
    expected_payloads = (_creation_ruleset_payload(), _immutable_ruleset_payload())
    for payload in expected_payloads:
        current = existing.get(payload["name"])
        if current is not None:
            _validate_ruleset(current, payload)
            continue
        created = _gh_api("POST", _repository_endpoint("/rulesets"), payload)
        if not isinstance(created, dict):
            raise AuthorizationError(f"RULESET_API: {payload['name']} was not created")
        _validate_ruleset(_ruleset_shape(created), payload)
    configured = _signing_rulesets()
    _validate_configured_rulesets(configured)
    return configured


def _reviewer_payload(environment: Mapping[str, Any] | None) -> list[dict[str, Any]]:
    reviewers: list[dict[str, Any]] = []
    if environment is not None:
        for rule in environment.get("protection_rules", []):
            if rule.get("type") != "required_reviewers":
                continue
            for entry in rule.get("reviewers", []):
                reviewer = entry.get("reviewer") or {}
                if entry.get("type") in {"User", "Team"} and isinstance(reviewer.get("id"), int):
                    reviewers.append({"type": entry["type"], "id": reviewer["id"]})
    owner = {"type": "User", "id": RELEASE_OWNER_ID}
    if reviewers and reviewers != [owner]:
        raise AuthorizationError("ENVIRONMENT_POLICY: existing reviewers permit approval without the release owner")
    return [owner]


def _wait_timer(environment: Mapping[str, Any] | None) -> int:
    if environment is not None:
        for rule in environment.get("protection_rules", []):
            if rule.get("type") == "wait_timer" and isinstance(rule.get("wait_timer"), int):
                return rule["wait_timer"]
    return 0


def _ensure_environment(initial: Mapping[str, Any] | None) -> dict[str, Any]:
    payload = {
        "wait_timer": _wait_timer(initial),
        "prevent_self_review": False,
        "reviewers": _reviewer_payload(initial),
        "deployment_branch_policy": {
            "protected_branches": False,
            "custom_branch_policies": True,
        },
        "can_admins_bypass": False,
    }
    result = _gh_api("PUT", _environment_endpoint(), payload)
    if not isinstance(result, dict):
        raise AuthorizationError(
            "ENVIRONMENT_API: protected release environment was not configured"
        )
    return result


def _ensure_initial_tag_policy() -> list[dict[str, Any]]:
    response = _gh_api("GET", _environment_endpoint("/deployment-branch-policies"))
    policies = _policy_shape(response)
    if not policies:
        created = _gh_api(
            "POST",
            _environment_endpoint("/deployment-branch-policies"),
            {"name": SIGNING_TAG_PATTERN, "type": "tag"},
        )
        if not isinstance(created, dict):
            raise AuthorizationError("DEPLOYMENT_POLICY_API: tag policy was not created")
    elif (
        len(policies) != 1
        or policies[0].get("name") != SIGNING_TAG_PATTERN
        or policies[0].get("type") != "tag"
    ):
        raise AuthorizationError(
            "DEPLOYMENT_POLICY: existing environment policy is not the signing tag pattern"
        )
    configured = _policy_shape(
        _gh_api("GET", _environment_endpoint("/deployment-branch-policies"))
    )
    _validate_deployment_policies(configured, SIGNING_TAG_PATTERN)
    return configured


def _validate_environment(environment: Mapping[str, Any]) -> None:
    shaped = (
        dict(environment)
        if environment.get("state") is not None
        else _environment_shape(environment)
    )
    if shaped.get("state") != "PRESENT" or shaped.get("name") != ENVIRONMENT:
        raise AuthorizationError("ENVIRONMENT_POLICY: release environment is absent")
    if shaped.get("deployment_branch_policy") != {
        "protected_branches": False,
        "custom_branch_policies": True,
    }:
        raise AuthorizationError("ENVIRONMENT_POLICY: custom tag policy is not enforced")
    if shaped.get("can_admins_bypass") is not False:
        raise AuthorizationError("ENVIRONMENT_POLICY: administrator bypass is enabled")
    reviewers = [
        rule
        for rule in shaped.get("protection_rules", [])
        if rule.get("type") == "required_reviewers"
    ]
    if len(reviewers) != 1 or reviewers[0].get("prevent_self_review") is not False:
        raise AuthorizationError("ENVIRONMENT_POLICY: required reviewer policy is invalid")
    allowed = reviewers[0].get("reviewers", [])
    if len(allowed) != 1 or allowed[0].get("type") != "User" or allowed[0].get("id") != RELEASE_OWNER_ID:
        raise AuthorizationError("ENVIRONMENT_POLICY: only the release owner may approve")


def _validate_deployment_policies(policies: Any, expected_name: str) -> None:
    if not isinstance(policies, list) or len(policies) != 1:
        raise AuthorizationError("DEPLOYMENT_POLICY: exactly one release tag policy is required")
    policy = policies[0]
    if (
        not isinstance(policy, dict)
        or not isinstance(policy.get("id"), int)
        or policy.get("name") != expected_name
        or policy.get("type") != "tag"
    ):
        raise AuthorizationError("DEPLOYMENT_POLICY: release tag policy is invalid")


def _validate_configured_rulesets(rulesets: Any) -> None:
    if not isinstance(rulesets, list) or len(rulesets) != 2:
        raise AuthorizationError("RULESET_POLICY: both signing tag rulesets are required")
    by_name = {item.get("name"): item for item in rulesets if isinstance(item, dict)}
    for expected in (_creation_ruleset_payload(), _immutable_ruleset_payload()):
        actual = by_name.get(expected["name"])
        if actual is None:
            raise AuthorizationError(f"RULESET_POLICY: {expected['name']} is absent")
        _validate_ruleset(actual, expected)


def _file_records(root: Path) -> list[dict[str, Any]]:
    records = []
    for relative in POLICY_FILES:
        path = root / relative
        records.append(
            {
                "path": relative,
                "digest": evidence_digest.text_evidence_digest(path).to_json(),
            }
        )
    return records


def _validate_file_records(root: Path, records: Any) -> None:
    if (
        not isinstance(records, list)
        or [item.get("path") for item in records if isinstance(item, dict)]
        != list(POLICY_FILES)
    ):
        raise AuthorizationError("SIGNING_POLICY_FILES: policy file inventory is invalid")
    for item in records:
        if not isinstance(item, dict):
            raise AuthorizationError("SIGNING_POLICY_FILES: file record is invalid")
        try:
            expected = evidence_digest.parse_text_digest(
                item.get("digest"), item.get("path", "file")
            )
            actual = evidence_digest.text_evidence_digest(root / item["path"])
        except (OSError, evidence_digest.DigestError) as error:
            raise AuthorizationError(f"SIGNING_POLICY_FILES: {error}") from error
        if expected != actual:
            raise AuthorizationError(
                f"SIGNING_POLICY_FILES: {item['path']} changed after policy capture"
            )


def _validate_policy_document(root: Path, policy: Mapping[str, Any]) -> None:
    if (
        policy.get("schema_version") != 1
        or policy.get("source_task") != "M8-007"
        or policy.get("status") != "PASS"
    ):
        raise AuthorizationError("SIGNING_POLICY_SCHEMA: policy status or task is invalid")
    repository = policy.get("repository")
    if (
        not isinstance(repository, dict)
        or repository.get("id") != REPOSITORY_ID
        or repository.get("full_name") != f"{OWNER}/{REPOSITORY}"
    ):
        raise AuthorizationError("SIGNING_POLICY_REPOSITORY: repository identity is invalid")
    authority = policy.get("authority")
    if (
        not isinstance(authority, dict)
        or authority.get("id") != RELEASE_OWNER_ID
        or authority.get("login") != OWNER
        or authority.get("repository_admin") is not True
    ):
        raise AuthorizationError("SIGNING_POLICY_AUTHORITY: release authority is invalid")
    probe = policy.get("non_admin_probe")
    if probe != {
        "status": "NOT_RUN",
        "reason": "non-admin credential unavailable",
        "claim": "No non-admin enforcement probe was performed",
    }:
        raise AuthorizationError("SIGNING_POLICY_PROBE: non-admin probe claim is invalid")
    configured = policy.get("configured")
    if not isinstance(configured, dict):
        raise AuthorizationError("SIGNING_POLICY_CONFIGURED: configured API evidence is absent")
    _validate_environment(configured.get("environment") or {})
    _validate_deployment_policies(configured.get("deployment_branch_policies"), SIGNING_TAG_PATTERN)
    _validate_configured_rulesets(configured.get("signing_rulesets"))
    if configured.get("approved_sha_variable") != {"state": "ABSENT"}:
        raise AuthorizationError(
            "SIGNING_POLICY_APPROVAL: initial policy must not preapprove a source"
        )
    _validate_file_records(root, policy.get("files"))


def verify_policy(root: Path) -> dict[str, Any]:
    """Verify the captured protected signing policy and its source-file binding."""
    policy = _load_json(root / POLICY_RELATIVE)
    _validate_policy_document(root, policy)
    return policy


def capture_policy(root: Path = ROOT) -> dict[str, Any]:
    """Capture initial state, add protected signing controls, and record live API evidence."""
    policy_path = root / POLICY_RELATIVE
    if policy_path.exists():
        return verify_policy(root)
    if (root / APPROVAL_RELATIVE).exists():
        raise AuthorizationError("SIGNING_POLICY_LOCKED: source approval already exists")
    user, repository = _authority()
    initial_environment = _gh_api("GET", _environment_endpoint(), allow_not_found=True)
    initial_rulesets = _gh_api("GET", _repository_endpoint("/rulesets"))
    if not isinstance(initial_rulesets, list):
        raise AuthorizationError("RULESET_API: repository rulesets response is invalid")
    initial_policies = None
    initial_variable = None
    if initial_environment is not None:
        initial_policies = _gh_api("GET", _environment_endpoint("/deployment-branch-policies"))
        initial_variable = _target_variable()
        if initial_variable is not None:
            raise AuthorizationError(
                "SIGNING_POLICY_APPROVAL: approved SHA variable already exists"
            )

    rulesets = _ensure_rulesets()
    _ensure_environment(initial_environment)
    policies = _ensure_initial_tag_policy()
    environment = _gh_api("GET", _environment_endpoint())
    variable = _target_variable()
    if not isinstance(environment, dict):
        raise AuthorizationError("ENVIRONMENT_API: configured environment response is invalid")
    _validate_environment(environment)
    if variable is not None:
        raise AuthorizationError("SIGNING_POLICY_APPROVAL: capture must not set an approved SHA")

    policy = {
        "schema_version": 1,
        "source_task": "M8-007",
        "status": "PASS",
        "captured_at": _now(),
        "api_version": API_VERSION,
        "repository": {
            "id": repository.get("id"),
            "full_name": repository.get("full_name"),
            "private": repository.get("private"),
        },
        "authority": {
            "id": user.get("id"),
            "login": user.get("login"),
            "repository_admin": (repository.get("permissions") or {}).get("admin") is True,
        },
        "initial": {
            "environment": _environment_shape(initial_environment),
            "deployment_branch_policies": _policy_shape(initial_policies),
            "approved_sha_variable": _variable_shape(initial_variable),
            "repository_rulesets": [
                {
                    "id": item.get("id"),
                    "name": item.get("name"),
                    "target": item.get("target"),
                    "enforcement": item.get("enforcement"),
                }
                for item in initial_rulesets
            ],
        },
        "configured": {
            "environment": _environment_shape(environment),
            "deployment_branch_policies": policies,
            "approved_sha_variable": _variable_shape(variable),
            "signing_rulesets": rulesets,
        },
        "non_admin_probe": {
            "status": "NOT_RUN",
            "reason": "non-admin credential unavailable",
            "claim": "No non-admin enforcement probe was performed",
        },
        "files": _file_records(root),
    }
    _validate_policy_document(root, policy)
    evidence_digest.atomic_json(policy_path, policy)
    return policy


def _policy_digest(root: Path) -> dict[str, str]:
    return evidence_digest.text_evidence_digest(root / POLICY_RELATIVE).to_json()


def _validate_approval_document(root: Path, approval: Mapping[str, Any]) -> str:
    policy = verify_policy(root)
    if (
        approval.get("schema_version") != 1
        or approval.get("source_task") != "M8-007"
        or approval.get("status") != "PASS"
    ):
        raise AuthorizationError("SIGNING_APPROVAL_SCHEMA: approval status or task is invalid")
    commit = approval.get("approved_source_commit")
    if not isinstance(commit, str) or SHA_RE.fullmatch(commit) is None:
        raise AuthorizationError("SIGNING_APPROVAL_COMMIT: approved commit is not a full SHA")
    if approval.get("approved_ref") != f"refs/tags/m8-007-signing-{commit}":
        raise AuthorizationError("SIGNING_APPROVAL_REF: approved tag does not bind the commit")
    approver = approval.get("approved_by")
    if (
        not isinstance(approver, dict)
        or approver.get("id") != RELEASE_OWNER_ID
        or approver.get("login") != OWNER
    ):
        raise AuthorizationError("SIGNING_APPROVAL_AUTHORITY: independent approver is invalid")
    selection = approval.get("selection")
    if selection != {"method": "explicit-cli-argument", "hosted_report_used": False}:
        raise AuthorizationError(
            "SIGNING_APPROVAL_SELECTION: hosted metadata cannot select the source"
        )
    policy_binding = approval.get("policy")
    if not isinstance(policy_binding, dict) or policy_binding.get("path") != POLICY_RELATIVE:
        raise AuthorizationError("SIGNING_APPROVAL_POLICY: policy path is invalid")
    try:
        recorded_policy_digest = evidence_digest.parse_text_digest(
            policy_binding.get("digest"), "signing approval policy"
        )
    except evidence_digest.DigestError as error:
        raise AuthorizationError(f"SIGNING_APPROVAL_POLICY: {error}") from error
    if recorded_policy_digest.to_json() != _policy_digest(root):
        raise AuthorizationError("SIGNING_APPROVAL_POLICY: policy changed after approval")
    if approval.get("files") != policy.get("files"):
        raise AuthorizationError(
            "SIGNING_APPROVAL_FILES: approved source controls are not policy-bound"
        )
    remote = approval.get("remote_commit")
    if (
        not isinstance(remote, dict)
        or remote.get("sha") != commit
        or remote.get("repository_id") != REPOSITORY_ID
    ):
        raise AuthorizationError("SIGNING_APPROVAL_REMOTE: remote committed source is not bound")
    configured = approval.get("configured")
    if not isinstance(configured, dict):
        raise AuthorizationError("SIGNING_APPROVAL_CONFIGURED: approval API evidence is absent")
    _validate_environment(configured.get("environment") or {})
    _validate_deployment_policies(
        configured.get("deployment_branch_policies"), f"m8-007-signing-{commit}"
    )
    _validate_configured_rulesets(configured.get("signing_rulesets"))
    variable = configured.get("approved_sha_variable")
    if (
        not isinstance(variable, dict)
        or variable.get("state") != "PRESENT"
        or variable.get("name") != APPROVED_SHA_VARIABLE
        or variable.get("value") != commit
    ):
        raise AuthorizationError(
            "SIGNING_APPROVAL_VARIABLE: environment does not bind the approved commit"
        )
    return commit


def approved_source_commit(root: Path) -> str:
    """Return the independently selected source SHA after fail-closed approval validation."""
    approval = _load_json(root / APPROVAL_RELATIVE)
    return _validate_approval_document(root, approval)


def approve_source(commit: str, root: Path = ROOT) -> dict[str, Any]:
    """Authorize one existing remote commit without creating a tag or approving a deployment."""
    if SHA_RE.fullmatch(commit) is None:
        raise AuthorizationError(
            "SIGNING_APPROVAL_COMMIT: --commit requires 40 lowercase hex characters"
        )
    approval_path = root / APPROVAL_RELATIVE
    if approval_path.exists():
        approved = approved_source_commit(root)
        if approved != commit:
            raise AuthorizationError(
                f"SIGNING_APPROVAL_LOCKED: source {approved} is already approved"
            )
        return _load_json(approval_path)
    policy = verify_policy(root)
    user, repository = _authority()
    remote = _gh_api("GET", _repository_endpoint(f"/git/commits/{commit}"), allow_not_found=True)
    if not isinstance(remote, dict) or remote.get("sha") != commit:
        raise AuthorizationError(
            "SIGNING_APPROVAL_REMOTE: commit does not exist in the remote repository"
        )

    environment = _gh_api("GET", _environment_endpoint())
    policies_response = _gh_api("GET", _environment_endpoint("/deployment-branch-policies"))
    if not isinstance(environment, dict):
        raise AuthorizationError("ENVIRONMENT_API: protected release environment is absent")
    _validate_environment(environment)
    _validate_configured_rulesets(_signing_rulesets())
    policies = _policy_shape(policies_response)
    if len(policies) != 1 or policies[0].get("type") != "tag" or policies[0].get("name") not in {
        SIGNING_TAG_PATTERN,
        f"m8-007-signing-{commit}",
    }:
        raise AuthorizationError(
            "DEPLOYMENT_POLICY: source approval cannot narrow an unexpected policy"
        )

    exact_tag = f"m8-007-signing-{commit}"
    _gh_api(
        "PUT",
        _environment_endpoint(f"/deployment-branch-policies/{policies[0]['id']}"),
        {"name": exact_tag},
    )
    existing_variable = _target_variable()
    if existing_variable is None:
        _gh_api(
            "POST",
            _environment_endpoint("/variables"),
            {"name": APPROVED_SHA_VARIABLE, "value": commit},
        )
    else:
        _gh_api(
            "PATCH",
            _environment_endpoint(f"/variables/{APPROVED_SHA_VARIABLE}"),
            {"name": APPROVED_SHA_VARIABLE, "value": commit},
        )

    configured_environment = _gh_api("GET", _environment_endpoint())
    configured_policies = _policy_shape(
        _gh_api("GET", _environment_endpoint("/deployment-branch-policies"))
    )
    configured_variable = _target_variable()
    configured_rulesets = _signing_rulesets()
    if not isinstance(configured_environment, dict):
        raise AuthorizationError("ENVIRONMENT_API: configured environment response is invalid")
    _validate_environment(configured_environment)
    _validate_deployment_policies(configured_policies, exact_tag)
    _validate_configured_rulesets(configured_rulesets)
    if configured_variable is None or configured_variable.get("value") != commit:
        raise AuthorizationError(
            "SIGNING_APPROVAL_VARIABLE: environment variable update did not bind commit"
        )

    approval = {
        "schema_version": 1,
        "source_task": "M8-007",
        "status": "PASS",
        "approved_at": _now(),
        "approved_source_commit": commit,
        "approved_ref": f"refs/tags/{exact_tag}",
        "approved_by": {"id": user.get("id"), "login": user.get("login")},
        "selection": {"method": "explicit-cli-argument", "hosted_report_used": False},
        "repository": {"id": repository.get("id"), "full_name": repository.get("full_name")},
        "remote_commit": {
            "repository_id": repository.get("id"),
            "sha": remote.get("sha"),
            "api_url": remote.get("url"),
        },
        "policy": {"path": POLICY_RELATIVE, "digest": _policy_digest(root)},
        "files": policy.get("files"),
        "configured": {
            "environment": _environment_shape(configured_environment),
            "deployment_branch_policies": configured_policies,
            "approved_sha_variable": _variable_shape(configured_variable),
            "signing_rulesets": configured_rulesets,
        },
        "non_admin_probe": {
            "status": "NOT_RUN",
            "reason": "non-admin credential unavailable",
            "claim": "No non-admin enforcement probe was performed",
        },
    }
    _validate_approval_document(root, approval)
    evidence_digest.atomic_json(approval_path, approval)
    return approval


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--root", type=Path, default=ROOT)
    commands = result.add_subparsers(dest="command", required=True)
    commands.add_parser("capture-policy")
    approve = commands.add_parser("approve-source")
    approve.add_argument("--commit", required=True)
    return result


def main(argv: Sequence[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        if args.command == "capture-policy":
            policy = capture_policy(args.root)
            print(f"M8-007 signing policy: {policy['status']} ({args.root / POLICY_RELATIVE})")
        else:
            approval = approve_source(args.commit, args.root)
            print(f"M8-007 signing source approved: {approval['approved_source_commit']}")
    except (AuthorizationError, evidence_digest.DigestError) as error:
        print(f"M8-007 signing authorization: FAIL: {error}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
