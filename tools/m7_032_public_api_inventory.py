#!/usr/bin/env python3
"""Generate and validate the M7-032 pre-1.0 public API inventory."""

from __future__ import annotations

if __package__ in {None, ""}:
    import sys
    from pathlib import Path
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tools import evidence_digest

import argparse
import json
import sys
from pathlib import Path
from typing import Any, Mapping, Sequence

import m7_026_linux_api_freeze as api_scan


ROOT = Path(__file__).resolve().parents[1]
TASK_ID = "M7-032"
SCHEMA_VERSION = 1
PROFILE = "linux-x86_64-glibc"
DEFAULT_INVENTORY = ROOT / "docs/api/baselines/wirestack-linux-pre1-m7-032.json"
DEFAULT_REPORT = ROOT / "docs/evidence/M7-032/linux_x86_64/public-api.json"
PUBLIC_PACKAGES = frozenset(api_scan.PUBLIC_PACKAGES)


class PublicApiInventoryError(RuntimeError):
    """Raised when the checked public contract is invalid or stale."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise PublicApiInventoryError(message)


def canonical_json(value: Any) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def load_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise PublicApiInventoryError(f"cannot read {path}: {error}") from error
    require(isinstance(value, dict), f"expected a JSON object in {path}")
    return value


def build_inventory(root: Path = ROOT) -> dict[str, Any]:
    scanned = api_scan.build_inventory(root)
    for alias in scanned["resolvedAliases"]:
        require(
            alias["targetPackage"] in PUBLIC_PACKAGES,
            f"public alias {alias['package']}.{alias['name']} targets non-public package "
            f"{alias['targetPackage']}",
        )
        require(
            alias["targetDeclaration"]["package"] in PUBLIC_PACKAGES,
            f"public alias target is not owned by a public package: {alias['name']}",
        )
    core = {
        key: value for key, value in scanned.items()
        if key not in {"inventorySha256", "taskId"}
    }
    core.update({
        "taskId": TASK_ID,
        "contractKind": "PRE_1_0_PUBLIC_API_INVENTORY",
        "compatibilityPolicy": "NOT_EVALUATED_PRE_1_0",
    })
    return {
        **core,
        "inventorySha256": evidence_digest.text_evidence_bytes_sha256(canonical_json(core)),
    }


def build_report(inventory_path: Path, inventory: Mapping[str, Any]) -> dict[str, Any]:
    return {
        "schemaVersion": SCHEMA_VERSION,
        "taskId": TASK_ID,
        "source_task": TASK_ID,
        "profile": PROFILE,
        "platform": PROFILE,
        "status": "PASS",
        "decision": "PASS",
        "acceptance_status": "PASS",
        "contractKind": inventory["contractKind"],
        "compatibilityPolicy": inventory["compatibilityPolicy"],
        "historicalM7026Baseline": "RETAINED_NOT_COMPARED",
        "publicPackages": inventory["publicPackages"],
        "declarationCount": len(inventory["declarations"]),
        "resolvedAliasCount": len(inventory["resolvedAliases"]),
        "internalAliasCount": 0,
        "inventorySha256": inventory["inventorySha256"],
        "inventoryFileSha256": evidence_digest.text_evidence_sha256(inventory_path),
        "generatorSha256": evidence_digest.text_evidence_sha256(Path(__file__)),
        "checks": {
            "publicOwners": "PASS",
            "publicAliasTargets": "PASS",
            "forbiddenPublicDeclarations": "PASS",
            "cancellationHandles": "PASS",
            "skippedAsPass": False,
        },
        "nonClaims": [
            "This inventory does not assert compatibility with the historical M7-026 API.",
            "This static inventory does not replace runtime, artifact, performance, or soak gates.",
        ],
    }


def write_json(path: Path, value: Mapping[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_bytes(canonical_json(value))
    temporary.replace(path)


def validate(
    root: Path = ROOT,
    inventory_path: Path = DEFAULT_INVENTORY,
    report_path: Path = DEFAULT_REPORT,
) -> dict[str, Any]:
    current = build_inventory(root)
    require(load_json(inventory_path) == current, "committed public API inventory is stale")
    report = build_report(inventory_path, current)
    require(load_json(report_path) == report, "committed public API report is stale")
    return report


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--inventory", type=Path, default=DEFAULT_INVENTORY)
    parser.add_argument("--report", type=Path, default=DEFAULT_REPORT)
    parser.add_argument("--write", action="store_true")
    parser.add_argument("--json", action="store_true")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    try:
        inventory = build_inventory(args.root)
        if args.write:
            write_json(args.inventory, inventory)
            write_json(args.report, build_report(args.inventory, inventory))
        report = validate(args.root, args.inventory, args.report)
    except (PublicApiInventoryError, api_scan.ApiFreezeError) as error:
        payload = {"taskId": TASK_ID, "status": "FAIL", "error": str(error)}
        print(json.dumps(payload, sort_keys=True) if args.json
              else f"M7-032 public API inventory: FAIL: {error}")
        return 1
    if args.json:
        print(json.dumps(report, sort_keys=True))
    else:
        print(
            "M7-032 public API inventory: PASS\n"
            f"declarations={report['declarationCount']}\n"
            f"resolved_aliases={report['resolvedAliasCount']}\n"
            f"internal_aliases={report['internalAliasCount']}\n"
            f"inventory_sha256={report['inventorySha256']}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
