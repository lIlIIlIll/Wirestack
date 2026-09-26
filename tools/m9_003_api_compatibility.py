#!/usr/bin/env python3
"""Compare M9-003's public API with its sealed M9-002 predecessor."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any
import sys

if __package__ in {None, ""}:
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from tools.evidence_digest import text_evidence_digest

ROOT = Path(__file__).resolve().parents[1]
BASELINE_API = Path("docs/evidence/M9-002/api-inventory.json")
BASELINE_NATIVE = Path("docs/evidence/M9-002/native-options.json")
CURRENT_API = Path("docs/evidence/M9-003/api-inventory.json")
CURRENT_NATIVE = Path("docs/evidence/M9-003/native-udp.json")
REPORT = Path("docs/evidence/M9-003/api-compatibility.json")
REQUIRED_MULTICAST_SCENARIOS = ("udp-multicast-ipv4", "udp-multicast-ipv6")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def declaration_index(inventory: dict[str, Any]) -> dict[tuple[str, str, str], dict[str, Any]]:
    result: dict[tuple[str, str, str], dict[str, Any]] = {}
    for declaration in inventory["declarations"]:
        key = (declaration["package"], declaration["kind"], declaration["name"])
        require(key not in result, f"duplicate API declaration: {key}")
        result[key] = declaration
    return result


def compare_inventories(previous: dict[str, Any], current: dict[str, Any]) -> dict[str, Any]:
    old = declaration_index(previous)
    new = declaration_index(current)
    removed_declarations = sorted(old.keys() - new.keys())
    added_declarations = sorted(new.keys() - old.keys())
    changed_declarations: list[dict[str, Any]] = []
    removed_members: list[dict[str, str]] = []
    added_members: list[dict[str, str]] = []

    for key in sorted(old.keys() & new.keys()):
        before, after = old[key], new[key]
        if before["signature"] != after["signature"]:
            changed_declarations.append({
                "package": key[0], "kind": key[1], "name": key[2],
                "before": before["signature"], "after": after["signature"],
            })
        before_members = {(member["kind"], member["name"], member["signature"])
                          for member in before.get("members", [])}
        after_members = {(member["kind"], member["name"], member["signature"])
                         for member in after.get("members", [])}
        for kind, name, signature in sorted(before_members - after_members):
            removed_members.append({"package": key[0], "declaration": key[2],
                                    "kind": kind, "name": name, "signature": signature})
        for kind, name, signature in sorted(after_members - before_members):
            added_members.append({"package": key[0], "declaration": key[2],
                                  "kind": kind, "name": name, "signature": signature})

    compatible = not removed_declarations and not changed_declarations and not removed_members
    return {
        "source_compatible": compatible,
        "added_declarations": [
            {"package": package, "kind": kind, "name": name}
            for package, kind, name in added_declarations
        ],
        "added_members": added_members,
        "removed_declarations": [
            {"package": package, "kind": kind, "name": name}
            for package, kind, name in removed_declarations
        ],
        "changed_declarations": changed_declarations,
        "removed_members": removed_members,
    }


def load_receipt(root: Path, path: Path, task: str, field: str) -> tuple[dict[str, Any], dict[str, Any]]:
    receipt = json.loads((root / path).read_text(encoding="utf-8"))
    require(receipt.get("source_task") == task and receipt.get("status") == "PASS",
            f"{path} is not a passing {task} receipt")
    value = receipt.get(field)
    require(isinstance(value, dict), f"{path} has no {field} object")
    return receipt, value


def build_report(root: Path = ROOT) -> dict[str, Any]:
    previous_api_receipt, previous = load_receipt(root, BASELINE_API, "M9-002", "inventory")
    current_api_receipt, current = load_receipt(root, CURRENT_API, "M9-003", "inventory")
    previous_native, _ = load_receipt(root, BASELINE_NATIVE, "M9-002", "observed_capabilities")
    current_native, observed = load_receipt(root, CURRENT_NATIVE, "M9-003", "observed_capabilities")
    require(previous["profile"] == current["profile"] == "linux-x86_64-glibc",
            "API inventories do not describe the same qualified profile")
    require(previous_native["platform"] == current_native["platform"] == "linux-x86_64-glibc",
            "native capability receipts do not describe the same platform")
    previous_udp = previous_native["observed_capabilities"].get("UdpSocket", {})
    current_udp = observed.get("UdpSocket", {})
    require(previous_udp.get("multicast") is False and current_udp.get("multicast") is True,
            "the qualified UDP multicast capability transition is missing")
    current_scenarios = {scenario.get("id"): scenario.get("status")
                         for scenario in current_native.get("scenarios", [])}
    require(all(current_scenarios.get(name) == "PASS" for name in REQUIRED_MULTICAST_SCENARIOS),
            "both IPv4 and IPv6 multicast scenarios must pass natively")

    diff = compare_inventories(previous, current)
    require(diff["source_compatible"], "the predecessor public API contains removals or signature changes")
    api_inputs = (BASELINE_API, CURRENT_API, BASELINE_NATIVE, CURRENT_NATIVE)
    report = {
        "schema_version": 1,
        "source_task": "M9-003",
        "status": "PASS",
        "platform": "linux-x86_64-glibc",
        "source_state": "WORKING_TREE_UNSEALED",
        "source_compatibility": "ADDITIVE_ONLY",
        "binary_compatibility": "NOT_RUN; consumers must rebuild and relink",
        "forward_compatibility": "NOT_RUN",
        "baseline": {
            "source_task": "M9-002",
            "api_inventory": BASELINE_API.as_posix(),
            "inventory_sha256": previous["inventorySha256"],
            "receipt_sha256": text_evidence_digest(root / BASELINE_API).to_json(),
        },
        "current": {
            "source_task": "M9-003",
            "api_inventory": CURRENT_API.as_posix(),
            "inventory_sha256": current["inventorySha256"],
            "receipt_sha256": text_evidence_digest(root / CURRENT_API).to_json(),
        },
        "api_diff": diff,
        "semantic_changes": [
            {
                "member": "UdpSocket.capabilities.multicast",
                "from": False,
                "to": True,
                "qualification": "IPv4 and IPv6 native membership and packet delivery passed",
                "evidence": [CURRENT_NATIVE.as_posix(), *REQUIRED_MULTICAST_SCENARIOS],
            }
        ],
        "binary_compatibility_nonclaim": "No old binary was loaded against this package; source compatibility does not imply ABI compatibility.",
        "input_digests": {
            path.as_posix(): text_evidence_digest(root / path).to_json()
            for path in api_inputs
        },
        "unchanged_api_declaration_count": len(previous["declarations"]),
    }
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--report", type=Path, default=REPORT)
    args = parser.parse_args()
    root = args.root.resolve()
    report_path = args.report if args.report.is_absolute() else root / args.report
    try:
        report = build_report(root)
    except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError) as error:
        print(f"M9-003 API compatibility: FAIL: {error}")
        return 1
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print("M9-003 API compatibility: PASS")
    print(f"source_compatibility={report['source_compatibility']}")
    print(f"added_members={len(report['api_diff']['added_members'])}")
    print(f"report={report_path.relative_to(root)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())