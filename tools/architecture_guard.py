#!/usr/bin/env python3
"""Enforce Wirestack source/package, dependency, and native-link boundaries.

The guard uses only the Python standard library so it can run before a Cangjie
SDK is installed. It scans production source and build metadata, not docs or
generated output.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Iterator, Sequence

SCHEMA_VERSION = 1
ALLOWED_STD_NET_PACKAGE = "wirestack.internal.transport_stdnet"
PUBLIC_API_PACKAGES = {"wirestack", "wirestack.http", "wirestack.tls"}
IGNORED_DIRS = {
    ".git", ".cjpm", ".codex", ".idea", ".local", ".vscode",
    "__pycache__", "build", "dist", "out", "target",
}
PACKAGE_RE = re.compile(
    r"(?m)^\s*package\s+([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*)\s*$"
)
STD_NET_RE = re.compile(r"(?<![A-Za-z0-9_])std\s*\.\s*net\b")
PUBLIC_DECLARATION_RE = re.compile(
    r"^\s*public\s+(?P<kind>class|struct|interface|enum|func|prop|let|var|type)\b"
)

SOURCE_RULES: tuple[tuple[str, re.Pattern[str], str], ...] = (
    (
        "private-runtime-socket-abi",
        re.compile(r"\bCJ_MRT_Sock[A-Za-z0-9_]*\b"),
        "Wirestack production source must not use the private CJ_MRT_Sock* ABI.",
    ),
    (
        "legacy-stdx-network-stack",
        re.compile(r"(?<![A-Za-z0-9_])stdx\s*\.\s*net\s*\.\s*(?:tls|http)(?:\b|\s*\.)"),
        "The new stack must not depend on legacy stdx.net.tls/http packages.",
    ),
    (
        "legacy-tls-ffi",
        re.compile(r"(?<![A-Za-z0-9_])(?:-l)?stdx\s*\.\s*net\s*\.\s*tlsFFI\b"),
        "The new stack must not link or reference stdx.net.tlsFFI.",
    ),
    (
        "legacy-tls-dynamic-bridge",
        re.compile(r"\bCJ_TLS_DYN_[A-Za-z0-9_]*\b"),
        "The new stack must not use the legacy CJ_TLS_DYN_* bridge.",
    ),
    (
        "legacy-global-tls-provider",
        re.compile(r"\b(?:TlsKit|setGlobalTlsKit|getGlobalTlsKit)\b"),
        "The new stack must not define or use the legacy global TLS provider API.",
    ),
)

PUBLIC_API_RULES: tuple[tuple[str, re.Pattern[str], str], ...] = (
    (
        "public-low-level-socket-type",
        re.compile(r"\b(?:TcpSocket|TcpServerSocket|StreamingSocket|SocketException)\b"),
        "Wirestack public packages must not expose low-level socket types.",
    ),
    (
        "public-native-provider-type",
        re.compile(r"\b(?:SSL_CTX|SSL|X509|EVP_PKEY|AwsLc[A-Za-z0-9_]*)\b"),
        "Wirestack public packages must not expose native TLS provider types.",
    ),
)

CONFIG_RULES: tuple[tuple[str, re.Pattern[str], str], ...] = SOURCE_RULES + (
    (
        "openssl-dynamic-loader-bridge",
        re.compile(r"(?<![A-Za-z0-9_])(?:-l)?cangjie-dynamicLoader-opensslFFI\b"),
        "Wirestack build configuration must not use the legacy OpenSSL dynamic-loader bridge.",
    ),
    (
        "system-openssl-loader",
        re.compile(
            r"\b(?:dlopen|LoadLibrary(?:A|W)?)\s*\([^\n)]*"
            r"(?:lib)?(?:ssl|crypto)(?:\.|[\"'])",
            re.IGNORECASE,
        ),
        "Wirestack must not load a system OpenSSL library at runtime.",
    ),
    (
        "system-openssl-link",
        re.compile(
            r"(?<![A-Za-z0-9_])(?:-l(?:ssl|crypto)\b|"
            r"(?:lib)?(?:ssl|crypto)\.(?:a|so(?:\.[0-9.]+)?|dylib|lib|dll)\b)",
            re.IGNORECASE,
        ),
        "Default Wirestack build configuration must not link a system OpenSSL library.",
    ),
)
CONFIG_NAMES = {"CMakeLists.txt", "Makefile", "build.cj", "build.py", "cjpm.toml"}
CONFIG_SUFFIXES = {".c", ".cc", ".cmake", ".cpp", ".h", ".hpp", ".mk", ".toml"}


@dataclass(frozen=True, order=True)
class Violation:
    path: str
    line: int
    column: int
    rule: str
    message: str
    excerpt: str


def _is_ignored(path: Path) -> bool:
    return any(part in IGNORED_DIRS for part in path.parts)


def _blank(text: str) -> str:
    return "".join("\n" if ch == "\n" else " " for ch in text)


def strip_cangjie_comments_and_literals(text: str) -> str:
    """Blank comments and quoted literals while preserving offsets/newlines."""
    out: list[str] = []
    i = 0
    size = len(text)
    while i < size:
        if text.startswith("//", i):
            end = text.find("\n", i + 2)
            if end == -1:
                end = size
            out.append(_blank(text[i:end]))
            i = end
            continue
        if text.startswith("/*", i):
            start = i
            i += 2
            depth = 1
            while i < size and depth > 0:
                if text.startswith("/*", i):
                    depth += 1
                    i += 2
                elif text.startswith("*/", i):
                    depth -= 1
                    i += 2
                else:
                    i += 1
            out.append(_blank(text[start:i]))
            continue
        if text.startswith('"""', i):
            start = i
            i += 3
            while i < size:
                if text.startswith('"""', i):
                    i += 3
                    break
                i += 2 if text[i] == "\\" and i + 1 < size else 1
            out.append(_blank(text[start:i]))
            continue
        if text[i] in {'"', "'"}:
            quote = text[i]
            start = i
            i += 1
            while i < size:
                if text[i] == "\\" and i + 1 < size:
                    i += 2
                    continue
                if text[i] == quote:
                    i += 1
                    break
                i += 1
            out.append(_blank(text[start:i]))
            continue
        out.append(text[i])
        i += 1
    return "".join(out)


def expected_package(source_root: Path, path: Path) -> str:
    relative = path.relative_to(source_root)
    parts = list(relative.parent.parts)
    return "wirestack" if not parts else "wirestack." + ".".join(parts)


def public_declaration_spans(text: str) -> Iterator[tuple[int, str]]:
    """Yield public declaration headers with offsets into stripped source."""
    lines = text.splitlines(keepends=True)
    offsets: list[int] = []
    offset = 0
    for line in lines:
        offsets.append(offset)
        offset += len(line)

    index = 0
    while index < len(lines):
        match = PUBLIC_DECLARATION_RE.match(lines[index])
        if match is None:
            index += 1
            continue
        start = offsets[index]
        kind = match.group("kind")
        end_index = index
        parentheses = 0
        while end_index < len(lines):
            line = lines[end_index]
            parentheses += line.count("(") - line.count(")")
            if "{" in line:
                break
            if kind in {"func", "prop"} and parentheses <= 0:
                break
            if kind in {"let", "var", "type"}:
                break
            end_index += 1
        end = offsets[end_index] + len(lines[end_index])
        yield start, text[start:end]
        index = end_index + 1


def _position(text: str, offset: int) -> tuple[int, int, str]:
    line = text.count("\n", 0, offset) + 1
    line_start = text.rfind("\n", 0, offset) + 1
    line_end = text.find("\n", offset)
    if line_end == -1:
        line_end = len(text)
    return line, offset - line_start + 1, text[line_start:line_end].strip()


def _violation(root: Path, path: Path, text: str, offset: int,
               rule: str, message: str) -> Violation:
    line, column, excerpt = _position(text, offset)
    return Violation(
        path=path.relative_to(root).as_posix(),
        line=line,
        column=column,
        rule=rule,
        message=message,
        excerpt=excerpt,
    )


def source_files(root: Path) -> Iterator[Path]:
    source_root = root / "src"
    if not source_root.is_dir():
        return
    for path in sorted(source_root.rglob("*.cj")):
        relative = path.relative_to(root)
        if path.is_file() and not _is_ignored(relative):
            yield path


def configuration_files(root: Path) -> Iterator[Path]:
    candidates: set[Path] = set()
    for path in root.rglob("*"):
        if not path.is_file():
            continue
        relative = path.relative_to(root)
        if _is_ignored(relative):
            continue
        if path.name in CONFIG_NAMES or path.suffix.lower() in CONFIG_SUFFIXES:
            candidates.add(path)
    yield from sorted(candidates)


def inspect_source(root: Path, path: Path) -> list[Violation]:
    text = path.read_text(encoding="utf-8")
    semantic = strip_cangjie_comments_and_literals(text)
    violations: list[Violation] = []
    wanted = expected_package(root / "src", path)
    package_match = PACKAGE_RE.search(semantic)
    if package_match is None:
        violations.append(_violation(
            root, path, text, 0, "package-declaration-missing",
            f"Expected package declaration: package {wanted}",
        ))
        actual_package: str | None = None
    else:
        actual_package = package_match.group(1)
        if actual_package != wanted:
            violations.append(_violation(
                root, path, text, package_match.start(1), "package-path-mismatch",
                f"Package {actual_package!r} does not match path; expected {wanted!r}.",
            ))
    if actual_package != ALLOWED_STD_NET_PACKAGE:
        for match in STD_NET_RE.finditer(semantic):
            violations.append(_violation(
                root, path, text, match.start(), "std-net-boundary",
                f"Only {ALLOWED_STD_NET_PACKAGE} may reference std.net.",
            ))
    if actual_package in PUBLIC_API_PACKAGES:
        for start, declaration in public_declaration_spans(semantic):
            for rule, pattern, message in PUBLIC_API_RULES:
                for match in pattern.finditer(declaration):
                    violations.append(_violation(
                        root, path, text, start + match.start(), rule, message,
                    ))
    for rule, pattern, message in SOURCE_RULES:
        for match in pattern.finditer(semantic):
            violations.append(_violation(root, path, text, match.start(), rule, message))
    return violations


def inspect_configuration(root: Path, path: Path) -> list[Violation]:
    text = path.read_text(encoding="utf-8")
    violations: list[Violation] = []
    for rule, pattern, message in CONFIG_RULES:
        for match in pattern.finditer(text):
            violations.append(_violation(root, path, text, match.start(), rule, message))
    return violations


def run_guard(root: Path) -> list[Violation]:
    root = root.resolve()
    violations: list[Violation] = []
    for path in source_files(root):
        violations.extend(inspect_source(root, path))
    for path in configuration_files(root):
        violations.extend(inspect_configuration(root, path))
    return sorted(set(violations))


def render_text(violations: Sequence[Violation]) -> str:
    if not violations:
        return "architecture guard: PASS"
    lines = [f"architecture guard: FAIL ({len(violations)} violation(s))"]
    for item in violations:
        lines.append(f"{item.path}:{item.line}:{item.column}: [{item.rule}] {item.message}")
        if item.excerpt:
            lines.append(f"  {item.excerpt}")
    return "\n".join(lines)


def render_json(root: Path, violations: Sequence[Violation]) -> str:
    return json.dumps({
        "schema_version": SCHEMA_VERSION,
        "root": str(root.resolve()),
        "ok": not violations,
        "violation_count": len(violations),
        "violations": [asdict(item) for item in violations],
    }, ensure_ascii=False, indent=2, sort_keys=True)


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path,
                        default=Path(__file__).resolve().parents[1])
    parser.add_argument("--format", choices=("text", "json"), default="text")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    if not args.root.is_dir():
        print(f"architecture guard: repository root does not exist: {args.root}", file=sys.stderr)
        return 2
    violations = run_guard(args.root)
    print(render_json(args.root, violations) if args.format == "json"
          else render_text(violations))
    return 0 if not violations else 1


if __name__ == "__main__":
    raise SystemExit(main())
