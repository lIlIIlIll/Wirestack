#!/usr/bin/env python3
"""Fail-closed validator for the M0-018 Wirestack threat model."""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any, Mapping, Sequence

SCHEMA_VERSION = 1
TASK_RE = re.compile(r"^(?:M[0-7]-\d{3}|UP-\d{3})$")
BACKLOG_TASK_RE = re.compile(r"(?m)^\|\s*((?:M[0-7]-\d{3}|UP-\d{3}))\s*\|")
CONTROL_RE = re.compile(r"^C-[A-Z0-9-]+$")
THREAT_RE = re.compile(r"^T-[A-Z0-9-]+$")
ASSET_RE = re.compile(r"^A-[A-Z0-9_-]+$")
BOUNDARY_RE = re.compile(r"^B-[A-Z0-9_-]+$")

REQUIRED_DOMAINS = {
    "supply_chain", "certificate_identity", "key_boundary", "tls_protocol",
    "transport_lifecycle", "cancellation_race", "dns_route",
    "parser_smuggling", "resource_exhaustion", "connection_pool",
    "logging_secrets", "c_abi", "platform_adapter", "release_integrity",
}
REQUIRED_CONTROLS = {
    "C-SUPPLY", "C-TRUST", "C-KEY", "C-TLS", "C-LIFE", "C-DNS",
    "C-H1", "C-H2", "C-BOUND", "C-POOL", "C-OBS", "C-ABI",
    "C-PLAT", "C-EVID",
}
SEVERITIES = {"LOW", "MEDIUM", "HIGH", "CRITICAL"}
STATUSES = {"OPEN", "MITIGATED_BY_DESIGN", "DEFERRED", "ACCEPTED"}


class ThreatModelError(RuntimeError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ThreatModelError(message)


def load_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ThreatModelError(f"cannot load threat model: {error}") from error
    require(isinstance(value, dict), "threat model root must be an object")
    return value


def load_backlog_tasks(path: Path) -> set[str]:
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as error:
        raise ThreatModelError(f"cannot load backlog: {error}") from error
    tasks = set(BACKLOG_TASK_RE.findall(text))
    require(tasks, "backlog contains no recognized task IDs")
    return tasks


def nonempty_text(value: Any, field: str) -> str:
    require(isinstance(value, str) and value.strip(),
            f"{field} must be non-empty text")
    return value.strip()


def string_list(value: Any, field: str, minimum: int = 1) -> list[str]:
    require(isinstance(value, list) and len(value) >= minimum,
            f"{field} must contain at least {minimum} item(s)")
    require(all(isinstance(item, str) and item.strip() for item in value),
            f"{field} contains an empty or non-string item")
    values = [item.strip() for item in value]
    require(len(set(values)) == len(values), f"{field} contains duplicate values")
    return values


def validate_id_list(value: Any, field: str, pattern: re.Pattern[str],
                     minimum: int) -> set[str]:
    values = string_list(value, field, minimum)
    for identifier in values:
        require(pattern.fullmatch(identifier) is not None,
                f"{field} contains invalid identifier: {identifier}")
    return set(values)


def validate_task_ids(values: Any, field: str,
                      backlog_tasks: set[str]) -> list[str]:
    tasks = string_list(values, field)
    for task_id in tasks:
        require(TASK_RE.fullmatch(task_id) is not None,
                f"{field} contains malformed task id: {task_id}")
        require(task_id in backlog_tasks,
                f"{field} references task absent from backlog: {task_id}")
    return tasks


def validate_control(control: Mapping[str, Any], backlog_tasks: set[str]) -> str:
    identifier = control.get("id")
    require(isinstance(identifier, str) and
            CONTROL_RE.fullmatch(identifier) is not None,
            f"invalid control id: {identifier!r}")
    nonempty_text(control.get("rule"), f"{identifier}.rule")
    validate_task_ids(control.get("tasks"), f"{identifier}.tasks", backlog_tasks)
    return identifier


def validate_threat(threat: Mapping[str, Any], assets: set[str],
                    boundaries: set[str], controls: set[str],
                    backlog_tasks: set[str]) -> tuple[str, str]:
    identifier = threat.get("id")
    require(isinstance(identifier, str) and
            THREAT_RE.fullmatch(identifier) is not None,
            f"invalid threat id: {identifier!r}")
    domain = threat.get("domain")
    require(domain in REQUIRED_DOMAINS,
            f"{identifier}: unknown domain: {domain!r}")
    severity = threat.get("severity")
    require(severity in SEVERITIES,
            f"{identifier}: invalid severity: {severity!r}")
    status = threat.get("status")
    require(status in STATUSES,
            f"{identifier}: invalid status: {status!r}")
    release_blocker = threat.get("release_blocker")
    require(isinstance(release_blocker, bool),
            f"{identifier}: release_blocker must be boolean")

    nonempty_text(threat.get("scenario"), f"{identifier}.scenario")
    nonempty_text(threat.get("residual"), f"{identifier}.residual")
    asset_refs = string_list(threat.get("assets"), f"{identifier}.assets")
    boundary_refs = string_list(threat.get("boundaries"),
                                f"{identifier}.boundaries")
    control_refs = string_list(threat.get("controls"),
                               f"{identifier}.controls")
    validate_task_ids(threat.get("tasks"), f"{identifier}.tasks", backlog_tasks)

    unknown_assets = sorted(set(asset_refs) - assets)
    unknown_boundaries = sorted(set(boundary_refs) - boundaries)
    unknown_controls = sorted(set(control_refs) - controls)
    require(not unknown_assets,
            f"{identifier}: unknown asset reference(s): {unknown_assets}")
    require(not unknown_boundaries,
            f"{identifier}: unknown boundary reference(s): {unknown_boundaries}")
    require(not unknown_controls,
            f"{identifier}: unknown control reference(s): {unknown_controls}")

    if severity in {"HIGH", "CRITICAL"}:
        require(status != "ACCEPTED",
                f"{identifier}: HIGH/CRITICAL threat may not be ACCEPTED")
        require(release_blocker,
                f"{identifier}: HIGH/CRITICAL threat must block stable release")
    return identifier, str(domain)


def validate_model(value: Mapping[str, Any], backlog_tasks: set[str]) -> None:
    require(value.get("schema_version") == SCHEMA_VERSION,
            f"unsupported schema_version: {value.get('schema_version')!r}")
    require(value.get("task_id") == "M0-018", "task_id must be M0-018")
    nonempty_text(value.get("reviewed_at"), "reviewed_at")

    domains = set(string_list(value.get("required_domains"),
                              "required_domains", 14))
    require(domains == REQUIRED_DOMAINS,
            "required_domains differs from canonical set: "
            f"missing={sorted(REQUIRED_DOMAINS-domains)}, "
            f"extra={sorted(domains-REQUIRED_DOMAINS)}")
    assets = validate_id_list(value.get("assets"), "assets", ASSET_RE, 10)
    boundaries = validate_id_list(value.get("boundaries"), "boundaries",
                                  BOUNDARY_RE, 12)

    raw_controls = value.get("controls")
    require(isinstance(raw_controls, list) and len(raw_controls) >= 12,
            "controls must contain at least 12 entries")
    control_ids: list[str] = []
    for index, control in enumerate(raw_controls):
        require(isinstance(control, dict),
                f"controls[{index}] must be an object")
        control_ids.append(validate_control(control, backlog_tasks))
    require(len(set(control_ids)) == len(control_ids),
            "controls contains duplicate IDs")
    controls = set(control_ids)
    require(REQUIRED_CONTROLS <= controls,
            f"required controls missing: {sorted(REQUIRED_CONTROLS-controls)}")

    raw_threats = value.get("threats")
    require(isinstance(raw_threats, list) and len(raw_threats) >= 16,
            "threats must contain at least 16 entries")
    threat_ids: list[str] = []
    covered_domains: set[str] = set()
    for index, threat in enumerate(raw_threats):
        require(isinstance(threat, dict),
                f"threats[{index}] must be an object")
        identifier, domain = validate_threat(
            threat, assets, boundaries, controls, backlog_tasks
        )
        threat_ids.append(identifier)
        covered_domains.add(domain)
    require(len(set(threat_ids)) == len(threat_ids),
            "threats contains duplicate IDs")
    require(covered_domains == REQUIRED_DOMAINS,
            "threat register does not cover every required domain: "
            f"missing={sorted(REQUIRED_DOMAINS-covered_domains)}")

    release_policy = nonempty_text(value.get("release_policy"),
                                   "release_policy")
    require("may not be ACCEPTED" in release_policy,
            "release_policy must prohibit accepting HIGH/CRITICAL threats")
    require("block stable release" in release_policy,
            "release_policy must make unresolved blockers block stable release")


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    root = Path(__file__).resolve().parents[1]
    parser.add_argument("--model", type=Path,
                        default=root / "docs/security/threat-model.json")
    parser.add_argument("--backlog", type=Path,
                        default=root / "docs/planning/implementation-backlog.md")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    try:
        model = load_json(args.model)
        backlog_tasks = load_backlog_tasks(args.backlog)
        validate_model(model, backlog_tasks)
    except ThreatModelError as error:
        print(f"Wirestack threat model: FAIL: {error}", file=sys.stderr)
        return 1
    print(f"Wirestack threat model: PASS "
          f"({len(model['threats'])} threats, {len(model['controls'])} controls)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
