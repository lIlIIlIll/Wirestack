#!/usr/bin/env python3
"""Validate the M0-015 TLS provider candidate matrix."""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any, Mapping, Sequence
from urllib.parse import urlparse

SCHEMA_VERSION = 1
ALLOWED_DISPOSITIONS = {
    "PRIMARY_POC", "SECONDARY_POC", "CONTROL_POC", "REFERENCE_ONLY",
    "CONDITIONAL_HOLD", "EXCLUDED_DEFAULT", "EXCLUDED_SINGLE_DEFAULT",
    "EXCLUDED",
}


class MatrixError(RuntimeError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise MatrixError(message)


def load_matrix(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise MatrixError(f"cannot load matrix: {error}") from error
    require(isinstance(value, dict), "matrix root must be an object")
    return value


def validate_url(value: str, candidate: str) -> None:
    parsed = urlparse(value)
    require(parsed.scheme == "https", f"{candidate}: evidence URL must use https: {value}")
    require(bool(parsed.netloc), f"{candidate}: evidence URL has no host: {value}")
    require(parsed.netloc not in {"medium.com", "reddit.com", "www.reddit.com"},
            f"{candidate}: third-party comparison source is not decision evidence: {value}")


def validate_candidate(candidate: Mapping[str, Any], platforms: set[str],
                       requirements: set[str], statuses: set[str],
                       platform_statuses: set[str]) -> None:
    identifier = candidate.get("id")
    require(isinstance(identifier, str) and identifier,
            "candidate id must be a non-empty string")
    require(candidate.get("disposition") in ALLOWED_DISPOSITIONS,
            f"{identifier}: unknown disposition")
    license_value = candidate.get("license")
    require(isinstance(license_value, dict), f"{identifier}: license must be an object")
    require(isinstance(license_value.get("expression"), str),
            f"{identifier}: license expression missing")
    require(isinstance(license_value.get("compatible"), bool),
            f"{identifier}: license compatible must be boolean")
    disposition = str(candidate["disposition"])
    if not license_value["compatible"]:
        require(disposition.startswith("EXCLUDED"),
                f"{identifier}: incompatible license must be excluded")

    requirement_values = candidate.get("requirements")
    require(isinstance(requirement_values, dict),
            f"{identifier}: requirements must be an object")
    require(set(requirement_values) == requirements,
            f"{identifier}: requirement keys differ from canonical set")
    for key, value in requirement_values.items():
        require(value in statuses, f"{identifier}: invalid status for {key}: {value}")

    platform_values = candidate.get("platforms")
    require(isinstance(platform_values, dict),
            f"{identifier}: platforms must be an object")
    require(set(platform_values) == platforms,
            f"{identifier}: platform keys differ from canonical set")
    for key, value in platform_values.items():
        require(value in platform_statuses,
                f"{identifier}: invalid platform status for {key}: {value}")

    for field in ("custom_io_model", "api_stability"):
        require(isinstance(candidate.get(field), str) and candidate[field].strip(),
                f"{identifier}: {field} must be non-empty")
    for field in ("strengths", "risks"):
        values = candidate.get(field)
        require(isinstance(values, list) and values,
                f"{identifier}: {field} must be a non-empty list")
        require(all(isinstance(item, str) and item.strip() for item in values),
                f"{identifier}: {field} contains invalid value")
    evidence = candidate.get("evidence")
    require(isinstance(evidence, list) and len(evidence) >= 2,
            f"{identifier}: at least two upstream evidence links required")
    for value in evidence:
        require(isinstance(value, str), f"{identifier}: evidence link must be text")
        validate_url(value, identifier)


def validate_matrix(value: Mapping[str, Any]) -> None:
    require(value.get("schema_version") == SCHEMA_VERSION,
            f"unsupported schema_version: {value.get('schema_version')}")
    require(value.get("task_id") == "M0-015", "task_id must be M0-015")
    require(isinstance(value.get("reviewed_at"), str) and value["reviewed_at"],
            "reviewed_at missing")
    require("not final provider selection" in str(value.get("decision_scope", "")),
            "decision scope must state that final selection is deferred")

    platform_list = value.get("platforms")
    require(isinstance(platform_list, list) and len(platform_list) == 6,
            "exactly six canonical platforms required")
    platforms = set(platform_list)
    require(len(platforms) == len(platform_list), "duplicate platform")

    requirement_list = value.get("hard_requirements")
    require(isinstance(requirement_list, list) and requirement_list,
            "hard_requirements missing")
    requirements = set(requirement_list)
    require(len(requirements) == len(requirement_list), "duplicate hard requirement")

    statuses = set(value.get("status_vocabulary", []))
    platform_statuses = set(value.get("platform_vocabulary", []))
    require(statuses == {"MET", "NOT_MET", "UNKNOWN", "POC_REQUIRED"},
            "status vocabulary changed")
    require(platform_statuses == {"DOCUMENTED", "PORTABLE_EXPECTED", "UNKNOWN", "NOT_TARGETED"},
            "platform vocabulary changed")

    candidates = value.get("candidates")
    require(isinstance(candidates, list) and len(candidates) >= 6,
            "at least six candidates required")
    identifiers: list[str] = []
    by_id: dict[str, Mapping[str, Any]] = {}
    for candidate in candidates:
        require(isinstance(candidate, dict), "candidate entry must be an object")
        validate_candidate(candidate, platforms, requirements, statuses, platform_statuses)
        identifier = str(candidate["id"])
        identifiers.append(identifier)
        by_id[identifier] = candidate
    require(len(set(identifiers)) == len(identifiers), "duplicate candidate id")

    shortlist = value.get("shortlist")
    require(isinstance(shortlist, dict), "shortlist must be an object")
    primary = shortlist.get("primary")
    secondary = shortlist.get("secondary")
    control = shortlist.get("control")
    require(primary in by_id and by_id[primary]["disposition"] == "PRIMARY_POC",
            "primary shortlist does not match PRIMARY_POC")
    require(secondary in by_id and by_id[secondary]["disposition"] == "SECONDARY_POC",
            "secondary shortlist does not match SECONDARY_POC")
    require(control in by_id and by_id[control]["disposition"] == "CONTROL_POC",
            "control shortlist does not match CONTROL_POC")
    require(len({primary, secondary, control}) == 3,
            "primary, secondary and control must be distinct")

    reference = shortlist.get("reference_only")
    conditional = shortlist.get("conditional")
    require(isinstance(reference, list) and reference,
            "reference_only shortlist missing")
    require(isinstance(conditional, list), "conditional shortlist must be a list")
    for identifier in reference:
        require(identifier in by_id and by_id[identifier]["disposition"] == "REFERENCE_ONLY",
                f"invalid reference-only candidate: {identifier}")
    for identifier in conditional:
        require(identifier in by_id and by_id[identifier]["disposition"] == "CONDITIONAL_HOLD",
                f"invalid conditional candidate: {identifier}")

    selected = {primary, secondary, control, *reference, *conditional}
    for identifier in selected:
        require(not str(by_id[identifier]["disposition"]).startswith("EXCLUDED"),
                f"excluded candidate appears in shortlist: {identifier}")

    # No external candidate may claim native Harmony evidence before M0-016.
    for candidate in candidates:
        if candidate["id"] != "platform-native":
            require(candidate["platforms"]["harmony"] != "DOCUMENTED",
                    f"{candidate['id']}: Harmony must remain unverified until M0-016")


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    root = Path(__file__).resolve().parents[1]
    parser.add_argument("--matrix", type=Path,
                        default=root / "docs/architecture/tls-provider-candidates.json")
    args = parser.parse_args(argv)
    try:
        value = load_matrix(args.matrix)
        validate_matrix(value)
    except MatrixError as error:
        print(f"TLS provider matrix: FAIL: {error}", file=sys.stderr)
        return 1
    print(f"TLS provider matrix: PASS ({len(value['candidates'])} candidates)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
