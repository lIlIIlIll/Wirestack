#!/usr/bin/env python3
"""Generate and validate the M7-026 Linux public API baseline."""

from __future__ import annotations

if __package__ in {None, ""}:
    import sys
    from pathlib import Path
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tools import evidence_digest

import argparse
import json
import re
import sys
import tomllib
from pathlib import Path
from typing import Any, Iterable, Mapping, Sequence


ROOT = Path(__file__).resolve().parents[1]
TASK_ID = "M7-026"
SCHEMA_VERSION = 1
PROFILE = "linux-x86_64-glibc"
PUBLIC_PACKAGES = ("wirestack", "wirestack.http", "wirestack.tls")
EXPECTED_PACKAGE_NAME = "wirestack"
EXPECTED_MAJOR = 0
DEFAULT_BASELINE = ROOT / "docs/api/baselines/wirestack-linux-v0.json"
DEFAULT_REPORT = ROOT / "docs/evidence/M7-026/linux_x86_64/api-compatibility.json"
REQUIRED_CANCELLATION_HANDLES = {
    "HttpRequestCancellationHandle": {
        "public prop isCancellationRequested: Bool { accessors:get }",
        "public prop scope: HttpCancellationScope { accessors:get }",
        "public func cancel(): Bool",
    },
    "HttpConnectionCancellationHandle": {
        "public prop isCancellationRequested: Bool { accessors:get }",
        "public prop scope: HttpCancellationScope { accessors:get }",
        "public func cancel(): Bool",
    },
    "HttpStreamCancellationHandle": {
        "public prop isCancellationRequested: Bool { accessors:get }",
        "public prop scope: HttpCancellationScope { accessors:get }",
        "public func cancel(): Bool",
    },
}
FORBIDDEN_PUBLIC_PATTERNS = {
    "global-tls-kit": re.compile(r"\b(?:TlsKit|setGlobalTlsKit|getGlobalTlsKit)\b"),
    "trust-all": re.compile(r"\bTrustAll\b"),
    "openssl-string": re.compile(
        r'"signature":"(?=[^"]*openssl)(?=[^"]*\bString\b)[^"]*"',
        re.IGNORECASE,
    ),
    "streaming-socket": re.compile(r"\bStreamingSocket\b"),
    "legacy-tls-socket": re.compile(r"\bTlsSocket\b"),
    "low-level-socket": re.compile(r"\b(?:TcpSocket|SocketException)\b"),
}
PACKAGE_RE = re.compile(
    r"(?m)^\s*package\s+([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*)\s*$"
)
IMPORT_ALIAS_RE = re.compile(
    r"(?m)^\s*import\s+([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*)"
    r"\s+as\s+([A-Za-z_][A-Za-z0-9_]*)\s*$"
)
TOP_LEVEL_RE = re.compile(
    r"^public\s+(?:(?:open|abstract|sealed)\s+)*"
    r"(?P<kind>class|struct|interface|enum|type|func|let|var)\b"
)
PUBLIC_MEMBER_RE = re.compile(
    r"^public\s+(?:(?:static|open|override|abstract|operator)\s+)*"
    r"(?P<kind>init|func|prop|let|var|class|struct|interface|enum)\b"
)
INTERFACE_MEMBER_RE = re.compile(
    r"^(?:(?:public|static|open|override|abstract|operator)\s+)*"
    r"(?P<kind>init|func|prop|let|var)\b"
)


class ApiFreezeError(RuntimeError):
    """Raised when the API baseline is incomplete, stale, or invalid."""


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise ApiFreezeError(message)


def canonical_json(value: Any) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def load_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ApiFreezeError(f"cannot read {path}: {error}") from error
    _require(isinstance(value, dict), f"expected a JSON object in {path}")
    return value


def _blank(value: str) -> str:
    return "".join("\n" if character == "\n" else " " for character in value)


def strip_comments(text: str) -> str:
    """Blank nested comments while preserving literals, offsets, and newlines."""
    output: list[str] = []
    index = 0
    while index < len(text):
        if text.startswith("//", index):
            end = text.find("\n", index + 2)
            if end < 0:
                end = len(text)
            output.append(_blank(text[index:end]))
            index = end
            continue
        if text.startswith("/*", index):
            start = index
            index += 2
            depth = 1
            while index < len(text) and depth > 0:
                if text.startswith("/*", index):
                    depth += 1
                    index += 2
                elif text.startswith("*/", index):
                    depth -= 1
                    index += 2
                else:
                    index += 1
            _require(depth == 0, "unterminated block comment")
            output.append(_blank(text[start:index]))
            continue
        quote = None
        if text.startswith('"""', index):
            quote = '"""'
        elif text[index] in {'"', "'"}:
            quote = text[index]
        if quote is not None:
            start = index
            index += len(quote)
            while index < len(text):
                if text[index] == "\\" and index + 1 < len(text):
                    index += 2
                elif text.startswith(quote, index):
                    index += len(quote)
                    break
                else:
                    index += 1
            output.append(text[start:index])
            continue
        output.append(text[index])
        index += 1
    return "".join(output)


def mask_literals(text: str) -> str:
    """Blank quoted literals so braces inside them do not affect nesting."""
    output: list[str] = []
    index = 0
    while index < len(text):
        quote = None
        if text.startswith('"""', index):
            quote = '"""'
        elif text[index] in {'"', "'"}:
            quote = text[index]
        if quote is None:
            output.append(text[index])
            index += 1
            continue
        start = index
        index += len(quote)
        while index < len(text):
            if text[index] == "\\" and index + 1 < len(text):
                index += 2
            elif text.startswith(quote, index):
                index += len(quote)
                break
            else:
                index += 1
        output.append(_blank(text[start:index]))
    return "".join(output)


def canonical_signature(value: str) -> str:
    return re.sub(r"\s+", " ", value).strip()


def _line_offsets(text: str) -> list[int]:
    offsets = [0]
    offsets.extend(match.end() for match in re.finditer("\n", text))
    return offsets


def _depths_at_lines(structural: str, offsets: Sequence[int]) -> list[int]:
    results: list[int] = []
    depth = 0
    cursor = 0
    for offset in offsets:
        while cursor < offset:
            if structural[cursor] == "{":
                depth += 1
            elif structural[cursor] == "}":
                depth -= 1
                _require(depth >= 0, "unbalanced closing brace")
            cursor += 1
        results.append(depth)
    return results


def _matching_brace(structural: str, opening: int) -> int:
    _require(opening >= 0 and structural[opening] == "{", "declaration body is absent")
    depth = 1
    for index in range(opening + 1, len(structural)):
        if structural[index] == "{":
            depth += 1
        elif structural[index] == "}":
            depth -= 1
            if depth == 0:
                return index
    raise ApiFreezeError("unterminated declaration body")


def _header_end(
    text: str,
    structural: str,
    start: int,
    limit: int,
    *,
    stop_at_newline: bool = True,
) -> tuple[int, int | None]:
    parentheses = 0
    brackets = 0
    for index in range(start, limit):
        character = structural[index]
        if character == "(":
            parentheses += 1
        elif character == ")":
            parentheses -= 1
        elif character == "[":
            brackets += 1
        elif character == "]":
            brackets -= 1
        elif character == "{" and parentheses == 0 and brackets == 0:
            return index, index
        elif (
            stop_at_newline
            and character == "\n"
            and parentheses == 0
            and brackets == 0
        ):
            return index, None
    return limit, None


def _symbol(kind: str, signature: str) -> str:
    if kind in {"class", "struct", "interface", "enum", "type"}:
        match = re.search(rf"\b{kind}\s+([A-Za-z_][A-Za-z0-9_]*)", signature)
    elif kind == "init":
        return "init"
    elif kind == "operator":
        match = re.search(r"\boperator\s+func\s+([^\s(]+)", signature)
    else:
        match = re.search(rf"\b{kind}\s+([A-Za-z_][A-Za-z0-9_]*)", signature)
    _require(match is not None, f"cannot parse {kind} symbol from {signature!r}")
    return match.group(1)


def _member_kind(signature: str, matched_kind: str) -> str:
    return "operator" if " operator func " in f" {signature} " else matched_kind


def _property_accessors(structural: str, opening: int, closing: int) -> list[str]:
    body = structural[opening + 1:closing]
    accessors = []
    for name in ("get", "set"):
        if re.search(rf"\b{name}\s*\(", body):
            accessors.append(name)
    _require(bool(accessors), "public property has no visible accessor")
    return accessors


def _member_entry(
    text: str,
    structural: str,
    start: int,
    limit: int,
    kind: str,
) -> tuple[dict[str, Any], int]:
    end, opening = _header_end(text, structural, start, limit)
    signature = canonical_signature(text[start:end])
    actual_kind = _member_kind(signature, kind)
    entry: dict[str, Any] = {
        "kind": actual_kind,
        "name": _symbol(actual_kind, signature),
        "signature": signature,
    }
    consumed = end
    if opening is not None:
        closing = _matching_brace(structural, opening)
        consumed = closing + 1
        if actual_kind == "prop":
            accessors = _property_accessors(structural, opening, closing)
            entry["signature"] += " { accessors:" + ",".join(accessors) + " }"
    return entry, consumed


def _type_entry(
    text: str,
    structural: str,
    line_offsets: Sequence[int],
    line_depths: Sequence[int],
    line_index: int,
    package: str,
    kind: str,
) -> tuple[dict[str, Any], int]:
    start = line_offsets[line_index]
    header_end, opening = _header_end(
        text, structural, start, len(text), stop_at_newline=False
    )
    _require(
        opening is not None,
        f"public {kind} declaration has no body at line {line_index + 1}",
    )
    closing = _matching_brace(structural, opening)
    signature = canonical_signature(text[start:header_end])
    entry: dict[str, Any] = {
        "package": package,
        "kind": kind,
        "name": _symbol(kind, signature),
        "signature": signature,
        "members": [],
    }
    base_depth = line_depths[line_index]
    saw_constructor = False
    index = line_index + 1
    while index < len(line_offsets) and line_offsets[index] < closing:
        if line_depths[index] != base_depth + 1:
            index += 1
            continue
        line_start = line_offsets[index]
        line_end = text.find("\n", line_start)
        if line_end < 0:
            line_end = len(text)
        stripped = text[line_start:line_end].strip()
        if not stripped:
            index += 1
            continue
        if kind == "enum" and stripped.startswith("|"):
            case_end, _ = _header_end(text, structural, line_start, closing)
            case_signature = canonical_signature(text[line_start:case_end])
            match = re.match(r"\|\s*([A-Za-z_][A-Za-z0-9_]*)", case_signature)
            _require(match is not None, f"cannot parse enum case {case_signature!r}")
            entry["members"].append({
                "kind": "case",
                "name": match.group(1),
                "signature": case_signature,
            })
            index += 1
            continue
        match = PUBLIC_MEMBER_RE.match(stripped)
        if match is None and kind == "interface":
            match = INTERFACE_MEMBER_RE.match(stripped)
        if match is None:
            if re.match(r"^(?:private|internal|protected)?\s*init\b", stripped):
                saw_constructor = True
            index += 1
            continue
        member_kind = match.group("kind")
        _require(
            member_kind not in {"class", "struct", "interface", "enum"},
            f"nested public declaration is unsupported in {entry['name']}",
        )
        member, consumed = _member_entry(text, structural, line_start, closing, member_kind)
        entry["members"].append(member)
        saw_constructor = saw_constructor or member["kind"] == "init"
        while index + 1 < len(line_offsets) and line_offsets[index + 1] < consumed:
            index += 1
        index += 1
    if kind in {"class", "struct"} and not saw_constructor:
        entry["members"].append({
            "kind": "init",
            "name": "init",
            "signature": "implicit public init()",
        })
    entry["members"] = sorted(
        entry["members"], key=lambda item: (item["kind"], item["name"], item["signature"])
    )
    return entry, closing + 1


def extract_public_declarations(path: Path) -> tuple[str, dict[str, str], list[dict[str, Any]]]:
    source = strip_comments(path.read_text(encoding="utf-8"))
    structural = mask_literals(source)
    package_match = PACKAGE_RE.search(structural)
    _require(package_match is not None, f"package declaration is absent: {path}")
    package = package_match.group(1)
    imports = {alias: target for target, alias in IMPORT_ALIAS_RE.findall(structural)}
    offsets = _line_offsets(source)
    depths = _depths_at_lines(structural, offsets)
    declarations: list[dict[str, Any]] = []
    line_index = 0
    while line_index < len(offsets):
        if depths[line_index] != 0:
            line_index += 1
            continue
        start = offsets[line_index]
        end = source.find("\n", start)
        if end < 0:
            end = len(source)
        stripped = source[start:end].strip()
        match = TOP_LEVEL_RE.match(stripped)
        if match is None:
            line_index += 1
            continue
        kind = match.group("kind")
        if kind in {"class", "struct", "interface", "enum"}:
            entry, consumed = _type_entry(
                source, structural, offsets, depths, line_index, package, kind
            )
        else:
            member, consumed = _member_entry(source, structural, start, len(source), kind)
            entry = {"package": package, **member}
        declarations.append(entry)
        while line_index + 1 < len(offsets) and offsets[line_index + 1] < consumed:
            line_index += 1
        line_index += 1
    return package, imports, declarations


def production_sources(root: Path) -> Iterable[Path]:
    for path in sorted((root / "src").rglob("*.cj")):
        if path.is_file() and not path.name.endswith("_test.cj"):
            yield path


def package_metadata(root: Path) -> dict[str, Any]:
    try:
        manifest = tomllib.loads((root / "cjpm.toml").read_text(encoding="utf-8"))
        package = manifest["package"]
        name = package["name"]
        version = package["version"]
    except (OSError, tomllib.TOMLDecodeError, KeyError, TypeError) as error:
        raise ApiFreezeError(f"cannot read package identity: {error}") from error
    _require(isinstance(name, str) and name, "package name is invalid")
    _require(isinstance(version, str), "package version is invalid")
    match = re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:[-+].*)?", version)
    _require(match is not None, f"package version is not semantic: {version!r}")
    return {"name": name, "version": version, "major": int(match.group(1))}


def _resolve_aliases(
    public_declarations: Sequence[dict[str, Any]],
    declarations_by_symbol: Mapping[tuple[str, str], dict[str, Any]],
    imports_by_package: Mapping[str, Mapping[str, str]],
) -> list[dict[str, Any]]:
    resolved: list[dict[str, Any]] = []
    for declaration in public_declarations:
        if declaration["kind"] != "type":
            continue
        match = re.fullmatch(
            r"public type ([A-Za-z_][A-Za-z0-9_]*) = "
            r"([A-Za-z_][A-Za-z0-9_]*)\.([A-Za-z_][A-Za-z0-9_]*)",
            declaration["signature"],
        )
        _require(match is not None, f"unsupported public type alias: {declaration['signature']}")
        name, import_alias, target_name = match.groups()
        target_package = imports_by_package.get(declaration["package"], {}).get(import_alias)
        _require(target_package is not None, f"cannot resolve import alias {import_alias!r}")
        target = declarations_by_symbol.get((target_package, target_name))
        _require(target is not None, f"cannot resolve public alias target {target_package}.{target_name}")
        declaration["signature"] = f"public type {name} = {target_package}.{target_name}"
        resolved.append({
            "package": declaration["package"],
            "name": name,
            "targetPackage": target_package,
            "targetName": target_name,
            "targetDeclaration": target,
        })
    return sorted(resolved, key=lambda item: (item["package"], item["name"]))


def _validate_forbidden(declarations: Sequence[Mapping[str, Any]]) -> None:
    serialized = canonical_json(declarations).decode("utf-8")
    for rule, pattern in FORBIDDEN_PUBLIC_PATTERNS.items():
        match = pattern.search(serialized)
        _require(match is None, f"forbidden public declaration [{rule}]: {match.group(0) if match else ''}")


def _validate_cancellation_handles(declarations: Sequence[Mapping[str, Any]]) -> None:
    index = {
        declaration.get("name"): declaration
        for declaration in declarations
        if declaration.get("package") == "wirestack.http"
    }
    for name, required_members in REQUIRED_CANCELLATION_HANDLES.items():
        declaration = index.get(name)
        _require(declaration is not None, f"required cancellation handle is absent: {name}")
        _require(declaration.get("kind") == "class", f"cancellation handle is not a class: {name}")
        actual = {member.get("signature") for member in declaration.get("members", [])}
        missing = sorted(required_members - actual)
        _require(not missing, f"cancellation handle {name} is incomplete: {missing}")


def build_inventory(root: Path = ROOT) -> dict[str, Any]:
    root = root.resolve()
    metadata = package_metadata(root)
    _require(metadata["name"] == EXPECTED_PACKAGE_NAME, "Wirestack package name changed")
    _require(metadata["major"] == EXPECTED_MAJOR, "Wirestack public major changed")
    all_declarations: list[dict[str, Any]] = []
    imports_by_package: dict[str, dict[str, str]] = {}
    seen_public_source_packages: set[str] = set()
    for path in production_sources(root):
        package, imports, declarations = extract_public_declarations(path)
        all_declarations.extend(declarations)
        if package in PUBLIC_PACKAGES:
            seen_public_source_packages.add(package)
            imports_by_package.setdefault(package, {}).update(imports)
    _require(
        seen_public_source_packages == set(PUBLIC_PACKAGES),
        f"public package inventory changed: {sorted(seen_public_source_packages)}",
    )
    declarations_by_symbol: dict[tuple[str, str], dict[str, Any]] = {}
    for declaration in all_declarations:
        key = (declaration["package"], declaration["name"])
        _require(key not in declarations_by_symbol, f"ambiguous top-level declaration: {key}")
        declarations_by_symbol[key] = declaration
    public_declarations = [
        declaration for declaration in all_declarations
        if declaration["package"] in PUBLIC_PACKAGES
    ]
    aliases = _resolve_aliases(public_declarations, declarations_by_symbol, imports_by_package)
    public_declarations = sorted(
        public_declarations,
        key=lambda item: (item["package"], item["kind"], item["name"], item["signature"]),
    )
    _validate_forbidden(public_declarations)
    _validate_forbidden([alias["targetDeclaration"] for alias in aliases])
    _validate_cancellation_handles(public_declarations)
    core = {
        "schemaVersion": SCHEMA_VERSION,
        "taskId": TASK_ID,
        "profile": PROFILE,
        "package": metadata,
        "publicPackages": list(PUBLIC_PACKAGES),
        "declarations": public_declarations,
        "resolvedAliases": aliases,
        "requiredCancellationHandles": sorted(REQUIRED_CANCELLATION_HANDLES),
        "forbiddenPublicRules": sorted(FORBIDDEN_PUBLIC_PATTERNS),
    }
    return {
        **core,
        "inventorySha256": evidence_digest.text_evidence_bytes_sha256(canonical_json(core)),
    }


def compare_inventory(baseline: Mapping[str, Any], current: Mapping[str, Any]) -> None:
    _require(baseline.get("schemaVersion") == SCHEMA_VERSION, "baseline schema is unsupported")
    if baseline == current:
        return
    baseline_declarations = {
        (item["package"], item["kind"], item["name"]): item
        for item in baseline.get("declarations", [])
    }
    current_declarations = {
        (item["package"], item["kind"], item["name"]): item
        for item in current.get("declarations", [])
    }
    removed = sorted(set(baseline_declarations) - set(current_declarations))
    added = sorted(set(current_declarations) - set(baseline_declarations))
    changed = sorted(
        key for key in set(baseline_declarations) & set(current_declarations)
        if baseline_declarations[key] != current_declarations[key]
    )
    details = []
    if baseline.get("package") != current.get("package"):
        details.append("package identity changed")
    if removed:
        details.append(f"removed={removed}")
    if added:
        details.append(f"added={added}")
    if changed:
        details.append(f"changed={changed}")
    if baseline.get("resolvedAliases") != current.get("resolvedAliases"):
        details.append("resolved alias declarations changed")
    if not details:
        details.append("inventory metadata changed")
    raise ApiFreezeError("public API differs from baseline: " + "; ".join(details))


def build_report(
    baseline_path: Path,
    inventory: Mapping[str, Any],
    generator_path: Path = Path(__file__),
) -> dict[str, Any]:
    declarations = inventory["declarations"]
    return {
        "schemaVersion": SCHEMA_VERSION,
        "taskId": TASK_ID,
        "profile": PROFILE,
        "decision": "PASS",
        "package": inventory["package"],
        "publicPackages": inventory["publicPackages"],
        "declarationCount": len(declarations),
        "resolvedAliasCount": len(inventory["resolvedAliases"]),
        "cancellationHandles": inventory["requiredCancellationHandles"],
        "inventorySha256": inventory["inventorySha256"],
        "baselineSha256": evidence_digest.text_evidence_sha256(baseline_path),
        "generatorSha256": evidence_digest.text_evidence_sha256(generator_path),
        "compatibilityEvidence": {
            "sourceAndInventory": "PASS_EXACT_BASELINE_MATCH",
            "packageAndMajor": "PASS_DEDICATED_MANIFEST_GATE",
            "abiBinary": "BASELINE_ONLY_NO_PREVIOUS_RELEASE",
            "semanticRuntime": "OUTSIDE_STATIC_GATE_USE_PROJECT_TESTS",
            "forward": "BASELINE_ONLY_NO_FUTURE_RELEASE",
        },
        "forbiddenPublicRules": inventory["forbiddenPublicRules"],
        "nonClaims": [
            "The first API freeze does not prove compatibility with a previous binary release.",
            "Static declaration comparison does not prove runtime semantic compatibility.",
            "Forward compatibility requires a future library and consumer matrix.",
            "runtime and std source changes are not Wirestack dependencies.",
        ],
    }


def validate(
    root: Path = ROOT,
    baseline_path: Path = DEFAULT_BASELINE,
    report_path: Path = DEFAULT_REPORT,
    *,
    validate_report: bool = True,
    generator_path: Path = Path(__file__),
) -> dict[str, Any]:
    current = build_inventory(root)
    baseline = load_json(baseline_path)
    compare_inventory(baseline, current)
    report = build_report(baseline_path, current, generator_path)
    if validate_report:
        _require(load_json(report_path) == report, "committed compatibility report is stale")
    return report


def write_json(path: Path, value: Mapping[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(canonical_json(value))


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--baseline", type=Path, default=DEFAULT_BASELINE)
    parser.add_argument("--report", type=Path, default=DEFAULT_REPORT)
    parser.add_argument("--write-baseline", action="store_true")
    parser.add_argument("--write-report", action="store_true")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    try:
        inventory = build_inventory(args.root)
        if args.write_baseline:
            write_json(args.baseline, inventory)
        else:
            compare_inventory(load_json(args.baseline), inventory)
        report = build_report(args.baseline, inventory)
        if args.write_report:
            write_json(args.report, report)
        else:
            _require(load_json(args.report) == report, "committed compatibility report is stale")
    except ApiFreezeError as error:
        print(f"M7-026 Linux API compatibility: FAIL: {error}")
        return 1
    print(
        "M7-026 Linux API compatibility: PASS\n"
        f"package={inventory['package']['name']}@{inventory['package']['version']}\n"
        f"declarations={len(inventory['declarations'])}\n"
        f"resolved_aliases={len(inventory['resolvedAliases'])}\n"
        f"inventory_sha256={inventory['inventorySha256']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
