#!/usr/bin/env python3
"""Require rendered documentation for the explicitly maintained API surface.

This gate examines cjdoc's output, not comment-looking text in source files.
The separate API inventory gate remains responsible for API compatibility.
"""
from __future__ import annotations

import argparse
from collections import Counter
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
DEFAULT_CONTRACT = ROOT / "release" / "api-documentation-required.json"


def nonempty(value: object) -> bool:
    return isinstance(value, str) and bool(value.strip())


def validate(document: dict, required: dict[str, dict[str, int]]) -> dict:
    if document.get("schemaVersion") != "cjdoc.doc-ir/8":
        raise ValueError("documentation gate requires cjdoc Doc IR v8")
    if document.get("project", {}).get("name") != "yjson":
        raise ValueError("documentation gate requires the yjson package")
    declarations = document.get("declarations")
    if not isinstance(declarations, list) or not all(isinstance(d, dict) for d in declarations):
        raise ValueError("declarations must be an array of objects")
    if not isinstance(required, dict) or not required:
        raise ValueError("required documentation contract must be nonempty")
    failures: list[str] = []
    selected: list[dict] = []
    for name, expected in sorted(required.items()):
        if not isinstance(expected, dict) or not expected or not all(
            isinstance(k, str) and isinstance(v, int) and not isinstance(v, bool) and v > 0
            for k, v in expected.items()
        ):
            raise ValueError(f"invalid member inventory for {name}")
        owners = [d for d in declarations if d.get("qualifiedName") == f"yjson.{name}"
                  and d.get("ownerId") is None and d.get("visibility") == "public"]
        if len(owners) != 1:
            failures.append(f"{name}: expected exactly one public type, found {len(owners)}")
            continue
        owner = owners[0]
        members = [d for d in declarations if d.get("ownerId") == owner.get("id")
                   and d.get("visibility") == "public"]
        counts = Counter(d.get("name") for d in members)
        for member, count in expected.items():
            if counts[member] < count:
                failures.append(f"{name}.{member}: expected at least {count} overload(s), found {counts[member]}")
        # Newly added public members also need comments. Do not silently pass
        # them just because they are absent from the initial member inventory.
        selected.extend([owner, *members])
    parameter_count = 0
    for declaration in selected:
        label = declaration.get("qualifiedName", declaration.get("name", "<unknown>"))
        doc = declaration.get("documentation")
        if not isinstance(doc, dict) or not nonempty(doc.get("summary")):
            failures.append(f"{label}: missing bound documentation summary")
            continue
        for parameter in declaration.get("parameters", []):
            parameter_count += 1
            if not nonempty(parameter.get("documentation")):
                failures.append(f"{label}: missing bound @param {parameter.get('name')}")
        result = declaration.get("returnType")
        if declaration.get("kind") == "function" and isinstance(result, dict) and result.get("spelling", "").strip() != "Unit":
            if not any(isinstance(t, dict) and t.get("name") == "return"
                       and nonempty(t.get("description")) for t in doc.get("tags", [])):
                failures.append(f"{label}: missing @return description")
    if failures:
        raise ValueError("API documentation contract failed:\n" + "\n".join(failures))
    public = [d for d in declarations if d.get("visibility") == "public"]
    documented = sum(isinstance(d.get("documentation"), dict)
                     and nonempty(d["documentation"].get("summary")) for d in public)
    return {"schemaVersion": "yjson.documentation-coverage/1", "package": "yjson",
            "publicDeclarations": len(public), "documentedPublicDeclarations": documented,
            "requiredTypes": len(required), "requiredDeclarations": len(selected),
            "documentedRequiredParameters": parameter_count,
            "scope": "Required application-facing types and all their direct public members; not whole-repository 100% coverage."}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("site", type=pathlib.Path)
    parser.add_argument("--contract", type=pathlib.Path, default=DEFAULT_CONTRACT)
    args = parser.parse_args()
    try:
        document = json.loads((args.site / "yjson" / "docs.json").read_text(encoding="utf-8"))
        required = json.loads(args.contract.read_text(encoding="utf-8"))
        report = validate(document, required)
        output = args.site / "documentation-coverage.json"
        output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    except (OSError, ValueError, TypeError, AttributeError) as error:
        print(f"API documentation error: {error}", file=sys.stderr)
        return 1
    print(f"API documentation contract passed: {report['requiredDeclarations']} declarations, "
          f"{report['documentedRequiredParameters']} parameters; "
          f"{report['documentedPublicDeclarations']}/{report['publicDeclarations']} public summaries overall")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
