#!/usr/bin/env python3
"""Generate or verify the complete checked-in yjson public declaration snapshot.

The release-delta TOML remains the human compatibility review. This snapshot is
the fail-closed companion: any added, removed, or changed public Cangjie
declaration (including public-interface members) or exported YJ_* C prototype
must update the checked-in baseline explicitly.
"""

from __future__ import annotations

import argparse
import pathlib
import re
import sys


ROOT = pathlib.Path(__file__).resolve().parents[1]
SNAPSHOT = ROOT / "release" / "public-api-snapshot.txt"
PACKAGE_ROOTS = {
    "yjson": ROOT / "src",
    "yjson_macros": ROOT / "packages/yjson_macros/src",
    "yjson_native": ROOT / "packages/yjson_native/src",
    "yjson_yyjson": ROOT / "packages/yjson_yyjson/src",
    "yjson_schema_formats": ROOT / "packages/yjson_schema_formats/src",
    "yjson_all": ROOT / "packages/yjson_all/src",
}
TYPE_RE = re.compile(
    r"^(?:(public|private|protected|internal)\s+)?"
    r"(?:(?:abstract|open|sealed)\s+)*(class|interface|struct|enum)\s+([A-Za-z_]\w*)"
)
PUBLIC_DECL_RE = re.compile(
    r"^public\s+(?:(?:static|open|abstract|override|operator|unsafe)\s+)*"
    r"(?:class|interface|struct|enum|extend|func|init|prop|let|var|type|macro)\b"
)
INTERFACE_MEMBER_RE = re.compile(
    r"^(?:(?:public|static|open|abstract|override|operator|unsafe)\s+)*"
    r"(?:func|init|prop|let|var|type)\b"
)


def sanitize_lines(text: str) -> list[str]:
    """Remove comments/string contents while preserving line and brace layout."""
    result: list[str] = []
    current: list[str] = []
    i = 0
    block_comment = False
    string_quote: str | None = None
    while i < len(text):
        ch = text[i]
        nxt = text[i + 1] if i + 1 < len(text) else ""
        if ch == "\n":
            result.append("".join(current))
            current = []
            i += 1
            continue
        if block_comment:
            if ch == "*" and nxt == "/":
                block_comment = False
                current.extend("  ")
                i += 2
            else:
                current.append(" ")
                i += 1
            continue
        if string_quote is not None:
            if ch == "\\":
                current.append(" ")
                if nxt:
                    current.append(" ")
                    i += 2
                else:
                    i += 1
            elif text.startswith(string_quote, i):
                current.extend(" " * len(string_quote))
                i += len(string_quote)
                string_quote = None
            else:
                current.append(" ")
                i += 1
            continue
        if ch == "/" and nxt == "/":
            current.extend(" " * (len(text) - i if "\n" not in text[i:] else text.index("\n", i) - i))
            i = text.index("\n", i) if "\n" in text[i:] else len(text)
            continue
        if ch == "/" and nxt == "*":
            block_comment = True
            current.extend("  ")
            i += 2
            continue
        if text.startswith('"""', i):
            string_quote = '"""'
            current.extend("   ")
            i += 3
            continue
        if ch in {'"', "'"}:
            string_quote = ch
            current.append(" ")
            i += 1
            continue
        current.append(ch)
        i += 1
    result.append("".join(current))
    return result


def normalized_header(lines: list[str], sanitized: list[str], start: int) -> str:
    parts: list[str] = []
    parens = 0
    brackets = 0
    for index in range(start, min(len(lines), start + 80)):
        raw = lines[index].strip()
        clean = sanitized[index].strip()
        if raw:
            parts.append(raw)
        for ch in clean:
            if ch == "(":
                parens += 1
            elif ch == ")":
                parens -= 1
            elif ch == "[":
                brackets += 1
            elif ch == "]":
                brackets -= 1
            elif ch == "{" and parens == 0 and brackets == 0:
                text = " ".join(parts)
                text = text[: text.find("{")]
                return re.sub(r"\s+", " ", text).strip()
        if parens == 0 and brackets == 0:
            if (clean.endswith(",") or clean.endswith("&") or clean.endswith("where")
                    or clean.endswith("<:")):
                continue
            return re.sub(r"\s+", " ", " ".join(parts)).strip()
    raise ValueError(f"unterminated declaration near line {start + 1}")


def cangjie_declarations(package: str, path: pathlib.Path) -> list[str]:
    text = path.read_text(encoding="utf-8")
    lines = text.splitlines()
    sanitized = sanitize_lines(text)
    declarations: list[str] = []
    depth = 0
    # Track every type, not only public types. Otherwise an explicitly public
    # interface implementation inside a private class looks like a top-level
    # declaration and leaks into the API snapshot.
    type_scopes: list[tuple[int, str, str, bool]] = []
    pending_type: tuple[str, str, bool] | None = None
    for index, clean_line in enumerate(sanitized[: len(lines)]):
        stripped = clean_line.strip()
        while type_scopes and depth < type_scopes[-1][0]:
            type_scopes.pop()
        owner = type_scopes[-1] if type_scopes else None
        is_direct_type_member = owner is not None and depth == owner[0]
        is_public_owner = is_direct_type_member and owner[3]
        is_explicit_public = (
            PUBLIC_DECL_RE.match(stripped) is not None
            and (owner is None or is_public_owner)
        )
        is_interface_member = (
            is_public_owner
            and owner[1] == "interface"
            and INTERFACE_MEMBER_RE.match(stripped) is not None
        )
        is_enum_case = (
            is_public_owner
            and owner[1] == "enum"
            and stripped.startswith("|")
        )
        if is_explicit_public or is_interface_member or is_enum_case:
            signature = normalized_header(lines, sanitized, index)
            owner_name = owner[2] if is_direct_type_member else "<top-level>"
            declarations.append(f"{package}|{path.relative_to(ROOT)}|{owner_name}|{signature}")

        opens = clean_line.count("{")
        closes = clean_line.count("}")
        type_match = TYPE_RE.match(stripped)
        declared_type: tuple[str, str, bool] | None = None
        if type_match:
            declared_public = type_match.group(1) == "public"
            externally_visible = declared_public and (owner is None or is_public_owner)
            declared_type = (type_match.group(2), type_match.group(3), externally_visible)
        opening_type = declared_type if declared_type is not None else pending_type
        if opening_type is not None and opens > 0:
            type_scopes.append((depth + 1, opening_type[0], opening_type[1], opening_type[2]))
            pending_type = None
        elif declared_type is not None:
            pending_type = declared_type
        depth += opens - closes
    return declarations


def c_prototypes(path: pathlib.Path) -> list[str]:
    declarations: list[str] = []
    pending: list[str] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if not pending and re.search(r"\bYJ_\w+\s*\(", stripped) is None:
            continue
        if stripped.startswith("#") or stripped.startswith("//"):
            continue
        pending.append(stripped)
        if ";" in stripped:
            signature = re.sub(r"\s+", " ", " ".join(pending)).strip()
            declarations.append(f"c-abi|{path.relative_to(ROOT)}|<top-level>|{signature}")
            pending = []
    return declarations


def generate() -> str:
    declarations: list[str] = []
    for package, root in PACKAGE_ROOTS.items():
        if not root.exists():
            continue
        for path in sorted(root.rglob("*.cj"), key=lambda item: item.relative_to(root).as_posix()):
            if path.name.startswith("test_") or path.name.startswith("example_"):
                continue
            declarations.extend(cangjie_declarations(package, path))
    for path in sorted((ROOT / "native").glob("*.h")):
        declarations.extend(c_prototypes(path))
    unique = sorted(set(declarations))
    return "# Generated by scripts/generate_public_api_snapshot.py; do not edit manually.\n" + "\n".join(unique) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--write", action="store_true", help="replace the checked-in snapshot")
    args = parser.parse_args()
    generated = generate()
    if args.write:
        SNAPSHOT.write_text(generated, encoding="utf-8")
        print(f"wrote {SNAPSHOT.relative_to(ROOT)} with {generated.count(chr(10)) - 1} declarations")
        return 0
    if not SNAPSHOT.is_file():
        raise SystemExit("public API snapshot missing; run with --write and review the result")
    expected = SNAPSHOT.read_text(encoding="utf-8")
    if expected != generated:
        raise SystemExit(
            "public API snapshot differs; run scripts/generate_public_api_snapshot.py --write "
            "and classify every declaration change"
        )
    print(f"public API snapshot passed: {generated.count(chr(10)) - 1} declarations")
    return 0


if __name__ == "__main__":
    sys.exit(main())
