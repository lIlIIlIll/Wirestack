#!/usr/bin/env python3
"""Validate the M7-020 Linux architecture audit against the current tree."""

from __future__ import annotations

from tools import evidence_digest

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any

TOOLS_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(TOOLS_DIR))

import architecture_guard as guard  # noqa: E402


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_AUDIT = ROOT / "docs/evidence/M7-020/linux_x86_64/audit.data"
CHECK_IDS = [f"ARCH-{index:02d}" for index in range(1, 8)]
REQUIRED_RULES = [
    "std-net-boundary",
    "public-low-level-socket-type",
    "public-native-provider-type",
    "private-runtime-socket-abi",
    "legacy-stdx-network-stack",
    "legacy-tls-ffi",
    "legacy-tls-dynamic-bridge",
    "legacy-global-tls-provider",
    "openssl-dynamic-loader-bridge",
    "system-openssl-loader",
    "system-openssl-link",
]
DIGEST_RE = re.compile(r"[0-9a-f]{64}")
ALLOWED_STD_NET_PATH = Path("src/internal/transport_stdnet")


class AuditError(ValueError):
    """Raised when the checked architecture no longer matches the audit."""


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise AuditError(message)


def _package(path: Path) -> str | None:
    semantic = guard.strip_cangjie_comments_and_literals(path.read_text(encoding="utf-8"))
    match = guard.PACKAGE_RE.search(semantic)
    return None if match is None else match.group(1)


def _std_net_files(root: Path) -> list[str]:
    matches = []
    for path in guard.source_files(root):
        semantic = guard.strip_cangjie_comments_and_literals(path.read_text(encoding="utf-8"))
        if guard.STD_NET_RE.search(semantic):
            matches.append(path.relative_to(root).as_posix())
    return matches


def validate_audit(
    path: Path = DEFAULT_AUDIT,
    repo_root: Path = ROOT,
    *,
    verify_current_sources: bool = True,
) -> dict[str, Any]:
    try:
        audit = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise AuditError(f"cannot load audit: {error}") from error

    _require(audit.get("schema_version") == 1, "schema_version must be 1")
    _require(audit.get("task_id") == "M7-020", "task_id must be M7-020")
    _require(audit.get("platform") == "linux-x86_64-glibc", "unexpected platform")
    _require(audit.get("decision") == "PASS", "architecture decision must be PASS")

    hashes = audit.get("source_sha256")
    _require(isinstance(hashes, dict), "source_sha256 must be an object")
    for relative in (
        "docs/product/prd.md",
        "docs/planning/implementation-backlog.md",
        "tools/architecture_guard.py",
        "cjpm.toml",
    ):
        digest = hashes.get(relative)
        _require(
            isinstance(digest, str) and DIGEST_RE.fullmatch(digest) is not None,
            f"source hash is invalid for {relative}",
        )
        if verify_current_sources:
            _require(
                digest == evidence_digest.text_evidence_sha256(repo_root / relative),
                f"source hash is stale for {relative}",
            )

    checks = audit.get("checks")
    _require(isinstance(checks, list), "checks must be a list")
    _require(
        [check.get("id") for check in checks if isinstance(check, dict)] == CHECK_IDS,
        "architecture check inventory is incomplete or reordered",
    )
    for check in checks:
        check_id = check["id"]
        _require(check.get("status") == "PASS", f"{check_id}: status must be PASS")
        _require(bool(check.get("requirement")), f"{check_id}: missing requirement")
        evidence = check.get("evidence")
        _require(isinstance(evidence, list) and evidence, f"{check_id}: missing evidence")
        for relative in evidence:
            _require(isinstance(relative, str) and relative, f"{check_id}: invalid evidence path")
            candidate = Path(relative)
            _require(
                not candidate.is_absolute() and ".." not in candidate.parts
                and candidate.as_posix() == relative,
                f"{check_id}: invalid evidence path {relative}",
            )
            if verify_current_sources:
                _require((repo_root / relative).exists(), f"{check_id}: missing {relative}")

    _require(audit.get("guard_rules") == REQUIRED_RULES, "guard rule inventory changed")

    inventory = audit.get("inventory")
    inventory_keys = {
        "cangjie_files",
        "configuration_and_native_files",
        "public_api_package_files",
        "semantic_std_net_files",
    }
    _require(isinstance(inventory, dict) and set(inventory) == inventory_keys,
             "scanned file inventory schema is invalid")
    for field in inventory_keys - {"semantic_std_net_files"}:
        _require(type(inventory[field]) is int and inventory[field] > 0,
                 f"scanned file inventory field is invalid: {field}")
    recorded_std_net = inventory["semantic_std_net_files"]
    _require(
        isinstance(recorded_std_net, list)
        and bool(recorded_std_net)
        and all(isinstance(relative, str) and relative for relative in recorded_std_net),
        "scanned std.net inventory is invalid",
    )
    _require(
        len(recorded_std_net) == len(set(recorded_std_net)),
        "scanned std.net inventory is invalid",
    )
    for relative in recorded_std_net:
        candidate = Path(relative)
        _require(
            not candidate.is_absolute()
            and ".." not in candidate.parts
            and candidate.as_posix() == relative
            and candidate.suffix == ".cj",
            f"std.net inventory path is invalid: {relative}",
        )
        _require(
            candidate.is_relative_to(ALLOWED_STD_NET_PATH),
            f"std.net escaped the adapter package in {relative}",
        )
        if verify_current_sources:
            source = repo_root / candidate
            _require(source.is_file(), f"std.net inventory source is missing: {relative}")
            _require(
                _package(source) == guard.ALLOWED_STD_NET_PACKAGE,
                f"std.net escaped the adapter package in {relative}",
            )

    if verify_current_sources:
        available_rules = {"std-net-boundary"} | {
            rule
            for rule, _pattern, _message in (
                guard.SOURCE_RULES + guard.PUBLIC_API_RULES + guard.CONFIG_RULES
            )
        }
        _require(
            set(REQUIRED_RULES).issubset(available_rules),
            "required guard rule is absent",
        )
        source_paths = list(guard.source_files(repo_root))
        config_paths = list(guard.configuration_files(repo_root))
        public_count = sum(_package(path) in guard.PUBLIC_API_PACKAGES for path in source_paths)
        expected_inventory = {
            "cangjie_files": len(source_paths),
            "configuration_and_native_files": len(config_paths),
            "public_api_package_files": public_count,
            "semantic_std_net_files": _std_net_files(repo_root),
        }
        _require(inventory == expected_inventory, "scanned file inventory is stale")
        violations = guard.run_guard(repo_root)
        _require(not violations, guard.render_text(violations))

    non_claims = audit.get("non_claims")
    _require(isinstance(non_claims, list), "non_claims must be a list")
    for fragment in ("runtime/std", "release artifact", "global M7"):
        _require(
            any(fragment in statement for statement in non_claims),
            f"non_claims must cover {fragment}",
        )
    return audit


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("audit", nargs="?", type=Path, default=DEFAULT_AUDIT)
    args = parser.parse_args()
    try:
        audit = validate_audit(args.audit)
    except AuditError as error:
        print(f"M7-020 architecture audit: FAIL: {error}")
        return 1
    inventory = audit["inventory"]
    print(
        "M7-020 architecture audit: PASS "
        f"({inventory['cangjie_files']} Cangjie files, "
        f"{inventory['configuration_and_native_files']} config/native files, "
        f"{len(audit['guard_rules'])} required rules)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
