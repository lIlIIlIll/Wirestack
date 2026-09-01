#!/usr/bin/env python3
"""Enforce Wirestack source/package, dependency, and native-link boundaries.

The guard uses only the Python standard library so it can run before a Cangjie
SDK is installed. It scans production source and build metadata, not docs or
generated output.
"""

from __future__ import annotations

import argparse
import ast
import json
import re
import sys
from dataclasses import asdict, dataclass
from pathlib import Path
from collections import deque
from typing import Iterator, Mapping, Sequence

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
RAW_DIGEST_COMMAND_RE = re.compile(
    r"(?:"
    r"\b(?:sha256sum|shasum(?:\s+-a\s+256)?|Get-FileHash|certutil(?:\.exe)?\s+-hashfile)\b"
    r"|\bopenssl(?:\.exe)?\s+dgst\b[^\r\n]*(?:-sha256|-sha-256)\b"
    r"|\bopenssl(?:\.exe)?\s+(?:sha256|sha-256)\b"
    r"|\bcksum\b[^\r\n]*(?:-a\s+sha256|--algorithm(?:=|\s+)sha256)\b"
    r"|\bhashlib\s*\.\s*(?:sha256|new\s*\([^\r\n]*sha256)"
    r"|\bfrom\s+hashlib\s+import\s+(?:sha256|new)\b"
    r"|\b(?:python(?:3(?:\.\d+)*)?|py)\b[^\r\n]*\s-c(?:\s|=)[^\r\n]*\bsha-?256\b"
    r"|\[?\s*(?:System\.)?Security\.Cryptography\.SHA256"
    r"(?:Managed|CryptoServiceProvider)?\s*\]?\s*(?:::|\.)\s*(?:Create|HashData)\b"
    r"|\.\s*ComputeHash\s*\("
    r")",
    re.IGNORECASE,
)
TEXT_COMMAND_OPERAND_RE = re.compile(
    r"(?:"
    r"\.(?:json|md|markdown|log|txt|yaml|yml|cj|py|c|cc|cpp|h|hpp|sh)"
    r"(?=$|[\s'\";)])"
    r"|(?:^|[/\\\s'\"])(?:LICENSE|NOTICE)(?=$|[\s'\";)])"
    r")",
    re.IGNORECASE,
)
SHELL_VARIABLE_OPERAND_RE = re.compile(
    r"\$(?:\{[A-Za-z_][A-Za-z0-9_]*\}|[A-Za-z_][A-Za-z0-9_]*)"
)
NON_PYTHON_DOMAIN_MANIFEST = Path("tools/evidence-digest-non-python.json")
PYTHON_TEXT_PATH_MARKERS = (
    "evidence", "report", "markdown", "log_path", "source_path",
    "validation", "read_text", ".json", ".md", ".markdown", ".log",
    ".txt", ".yaml", ".yml", ".cj", ".py", ".c", ".cc", ".cpp",
    ".h", ".hpp", ".sh",
)
TYPE_CONTAINER_RE = re.compile(
    r"^\s*(?P<public>public\s+)?(?:open\s+)?(?:class|struct|interface|enum)\b"
)
IMPORT_RE = re.compile(
    r"(?m)^\s*import\s+(?P<path>[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_*][A-Za-z0-9_*]*)*)"
    r"(?:\s+as\s+(?P<alias>[A-Za-z_][A-Za-z0-9_]*))?\s*$"
)
INTERNAL_PACKAGE_PREFIX = "wirestack.internal."

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
PROVIDER_SPECIFIC_TYPE_RE = re.compile(r"\bAwsLc[A-Za-z0-9_]*\b")
TEST_PROVIDER_RE = re.compile(r"\bTestTlsProvider(?:Factory)?\b")
EVIDENCE_DIGEST_IMPLEMENTATION = "tools/evidence_digest.py"


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
    """Yield exported declaration headers with offsets into stripped source."""
    lines = text.splitlines(keepends=True)
    offsets: list[int] = []
    offset = 0
    for line in lines:
        offsets.append(offset)
        offset += len(line)

    index = 0
    brace_depth = 0
    top_level_container_public = False
    while index < len(lines):
        match = PUBLIC_DECLARATION_RE.match(lines[index])
        exported = brace_depth == 0 or top_level_container_public
        if match is None or not exported:
            if brace_depth == 0:
                container = TYPE_CONTAINER_RE.match(lines[index])
                if container is not None and "{" in lines[index]:
                    top_level_container_public = container.group("public") is not None
            brace_depth += lines[index].count("{") - lines[index].count("}")
            if brace_depth == 0:
                top_level_container_public = False
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
        if brace_depth == 0 and kind in {"class", "struct", "interface", "enum"}:
            top_level_container_public = True
        for consumed in lines[index:end_index + 1]:
            brace_depth += consumed.count("{") - consumed.count("}")
        if brace_depth == 0:
            top_level_container_public = False
        index = end_index + 1


def internal_import_names(text: str) -> set[str]:
    """Return names that resolve directly to an internal import."""
    names: set[str] = set()
    for match in IMPORT_RE.finditer(text):
        path = match.group("path")
        if not path.startswith(INTERNAL_PACKAGE_PREFIX):
            continue
        alias = match.group("alias")
        if alias is not None:
            names.add(alias)
            continue
        final = path.rsplit(".", 1)[-1]
        if final != "*":
            names.add(final)
    return names


def resolved_imports(text: str, packages: set[str]) -> Iterator[tuple[str, int]]:
    """Yield imported packages and source offsets using the longest known prefix."""
    for match in IMPORT_RE.finditer(text):
        path = match.group("path").removesuffix(".*")
        candidates = [package for package in packages
                      if path == package or path.startswith(package + ".")]
        if candidates:
            yield max(candidates, key=len), match.start("path")


def public_internal_references(declaration: str, imported_names: set[str]) -> Iterator[tuple[int, str]]:
    direct = re.compile(r"\bwirestack\s*\.\s*internal(?:\s*\.\s*[A-Za-z_][A-Za-z0-9_]*)+")
    for match in direct.finditer(declaration):
        yield match.start(), "wirestack.internal"
    for name in sorted(imported_names):
        pattern = re.compile(rf"\b{re.escape(name)}\s*\.")
        for match in pattern.finditer(declaration):
            yield match.start(), name


def is_public_type_alias(declaration: str) -> bool:
    return re.match(r"^\s*public\s+type\b", declaration) is not None


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
        imported_internal_names = internal_import_names(semantic)
        for start, declaration in public_declaration_spans(semantic):
            for offset, _ in public_internal_references(declaration, imported_internal_names):
                alias = is_public_type_alias(declaration)
                violations.append(_violation(
                    root,
                    path,
                    text,
                    start + offset,
                    "public-internal-alias" if alias else "public-internal-type",
                    "Wirestack public declarations must not expose wirestack.internal.* types.",
                ))
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


def dependency_cycle_violations(root: Path, paths: Sequence[Path]) -> list[Violation]:
    """Reject import cycles that cross from a public package into internal code."""
    sources: list[tuple[Path, str, str]] = []
    packages: set[str] = set()
    for path in paths:
        text = path.read_text(encoding="utf-8")
        semantic = strip_cangjie_comments_and_literals(text)
        match = PACKAGE_RE.search(semantic)
        if match is None:
            continue
        package = match.group(1)
        packages.add(package)
        sources.append((path, text, semantic))

    graph: dict[str, set[str]] = {package: set() for package in packages}
    edges: list[tuple[str, str, Path, str, int]] = []
    for path, text, semantic in sources:
        match = PACKAGE_RE.search(semantic)
        if match is None:
            continue
        source = match.group(1)
        for target, offset in resolved_imports(semantic, packages):
            if target == source:
                continue
            graph[source].add(target)
            edges.append((source, target, path, text, offset))

    def path_between(start: str, wanted: str) -> list[str] | None:
        queue: deque[tuple[str, list[str]]] = deque([(start, [start])])
        seen = {start}
        while queue:
            current, route = queue.popleft()
            for target in sorted(graph.get(current, ())):
                if target == wanted:
                    return route + [target]
                if target not in seen:
                    seen.add(target)
                    queue.append((target, route + [target]))
        return None

    violations: list[Violation] = []
    for source, target, path, text, offset in sorted(
        edges, key=lambda item: (item[0], item[1], item[2].as_posix(), item[4])
    ):
        if source not in PUBLIC_API_PACKAGES or not target.startswith(INTERNAL_PACKAGE_PREFIX):
            continue
        route = path_between(target, source)
        if route is None:
            continue
        cycle = " -> ".join([source, *route])
        violations.append(_violation(
            root,
            path,
            text,
            offset,
            "public-internal-dependency-cycle",
            f"Public and internal packages must not form an import cycle: {cycle}",
        ))
    return violations


def provider_boundary_violations(root: Path, paths: Sequence[Path]) -> list[Violation]:
    """Keep provider implementations out of generic TLS, HTTP, build, and payload code."""
    violations: list[Violation] = []
    for path in paths:
        relative = path.relative_to(root).as_posix()
        text = path.read_text(encoding="utf-8")
        semantic = strip_cangjie_comments_and_literals(text)
        is_test = path.name.endswith("_test.cj")
        is_generic_tls_or_http = relative.startswith(("src/tls/", "src/http/", "src/internal/tls_engine/", "src/internal/http1/", "src/internal/http2/"))
        if is_generic_tls_or_http and not is_test:
            for match in PROVIDER_SPECIFIC_TYPE_RE.finditer(semantic):
                violations.append(_violation(
                    root, path, text, match.start(), "generic-provider-specific-type",
                    "Generic TLS and HTTP source must depend only on the TlsProvider contract.",
                ))
        if not is_test:
            for match in TEST_PROVIDER_RE.finditer(semantic):
                violations.append(_violation(
                    root, path, text, match.start(), "test-provider-in-production",
                    "TestTlsProvider is test-only and must not enter production source.",
                ))

    build_file = root / "build.cj"
    if build_file.is_file():
        text = build_file.read_text(encoding="utf-8")
        for pattern in (r"aws[_-]lc", r"AWS-LC", r"build_linux_tls_provider"):
            match = re.search(pattern, text, re.IGNORECASE)
            if match:
                violations.append(_violation(
                    root, build_file, text, match.start(), "provider-specific-root-build",
                    "build.cj must call only the provider-neutral TLS build entry.",
                ))

    generic_builder = root / "tools/build_tls_provider.py"
    if generic_builder.is_file():
        text = generic_builder.read_text(encoding="utf-8")
        match = re.search(r"native/tls/aws_lc", text)
        if match:
            violations.append(_violation(
                root, generic_builder, text, match.start(), "provider-path-in-generic-build",
                "The provider-neutral builder must not embed an AWS-LC source path.",
            ))
    return violations


def _python_import_aliases(tree: ast.AST) -> dict[str, str]:
    aliases: dict[str, str] = {}
    for node in ast.walk(tree):
        if isinstance(node, ast.ImportFrom) and node.module:
            for item in node.names:
                if item.name != "*":
                    aliases[item.asname or item.name] = f"{node.module}.{item.name}"
        elif isinstance(node, ast.Import):
            for item in node.names:
                local = item.asname or item.name.split(".", 1)[0]
                aliases[local] = item.name if item.asname else local
    return aliases


def _python_expression_name(node: ast.AST) -> str | None:
    if isinstance(node, ast.Name):
        return node.id
    if isinstance(node, ast.Attribute):
        value = _python_expression_name(node.value)
        return f"{value}.{node.attr}" if value else node.attr
    return None


def _python_callable_aliases(tree: ast.AST, imported: dict[str, str]) -> dict[str, str]:
    aliases = dict(imported)
    digest_names = {
        "artifact_byte_digest", "artifact_byte_digest_bytes", "artifact_byte_sha256",
        "artifact_bytes_sha256", "parse_artifact_digest", "signed_payload_sha256",
        "text_evidence_digest", "text_evidence_digest_bytes", "parse_text_digest",
        "text_evidence_sha256", "text_evidence_bytes_sha256",
        "text_evidence_inventory_sha256", "sha256_path", "canonical_text_sha256",
        "repository_text_sha256",
    }
    pending: list[tuple[str, ast.AST]] = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Assign):
            pending.extend(
                (target.id, node.value) for target in node.targets if isinstance(target, ast.Name)
            )
        elif isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name) \
                and node.value is not None:
            pending.append((node.target.id, node.value))
    while pending:
        remaining: list[tuple[str, ast.AST]] = []
        changed = False
        for target, value in pending:
            name = _python_expression_name(value)
            if name is None:
                continue
            root, separator, remainder = name.partition(".")
            if root in aliases:
                name = aliases[root] + (separator + remainder if separator else "")
            final = name.rsplit(".", 1)[-1]
            if final in digest_names or name == "hashlib.sha256":
                aliases[target] = name
                changed = True
            else:
                remaining.append((target, value))
        if not changed:
            break
        pending = remaining
    return aliases


def _python_call_name(node: ast.Call, aliases: dict[str, str] | None = None) -> str | None:
    name = _python_expression_name(node.func)
    if name is None:
        return None
    if aliases:
        root, separator, remainder = name.partition(".")
        if root in aliases:
            name = aliases[root] + (separator + remainder if separator else "")
    if name == "hashlib.sha256":
        return name
    final = name.rsplit(".", 1)[-1]
    if final in {
        "artifact_byte_digest", "artifact_byte_digest_bytes", "artifact_byte_sha256",
        "artifact_bytes_sha256", "parse_artifact_digest", "text_evidence_digest",
        "text_evidence_digest_bytes", "parse_text_digest", "text_evidence_sha256",
        "text_evidence_bytes_sha256", "text_evidence_inventory_sha256",
        "signed_payload_sha256", "sha256_path", "canonical_text_sha256",
        "repository_text_sha256",
    }:
        return final
    return name


def _python_digest_wrappers(
    tree: ast.AST, aliases: dict[str, str],
) -> dict[str, tuple[str, str, int | None]]:
    typed_calls = {
        "artifact_byte_digest", "artifact_byte_digest_bytes", "artifact_byte_sha256",
        "artifact_bytes_sha256", "parse_artifact_digest", "signed_payload_sha256",
        "text_evidence_digest", "text_evidence_digest_bytes", "parse_text_digest",
        "text_evidence_sha256", "text_evidence_bytes_sha256",
        "text_evidence_inventory_sha256",
    }
    candidates: list[tuple[ast.FunctionDef | ast.AsyncFunctionDef, ast.Call]] = []
    for node in ast.walk(tree):
        if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            continue
        body = list(node.body)
        if (body and isinstance(body[0], ast.Expr)
                and isinstance(body[0].value, ast.Constant)
                and isinstance(body[0].value.value, str)):
            body = body[1:]
        if len(body) != 1 or not isinstance(body[0], ast.Return) or body[0].value is None:
            continue
        if isinstance(body[0].value, ast.Call):
            candidates.append((node, body[0].value))

    wrappers: dict[str, tuple[str, str, int | None]] = {}
    pending = list(candidates)
    while pending:
        remaining: list[tuple[ast.FunctionDef | ast.AsyncFunctionDef, ast.Call]] = []
        changed = False
        for node, call in pending:
            target = _python_call_name(call, aliases)
            if target in typed_calls:
                base_target = target
                forwarded = _python_primary_argument(call, {"path", "raw", "value"})
            elif target in wrappers:
                base_target, target_parameter, target_index = wrappers[target]
                forwarded = _python_call_argument_for_parameter(
                    call, target_parameter, target_index,
                )
            else:
                remaining.append((node, call))
                continue
            if not isinstance(forwarded, ast.Name):
                continue
            positional = list(node.args.posonlyargs) + list(node.args.args)
            positional_names = [argument.arg for argument in positional]
            keyword_names = [argument.arg for argument in node.args.kwonlyargs]
            if forwarded.id in positional_names:
                parameter_index: int | None = positional_names.index(forwarded.id)
            elif forwarded.id in keyword_names:
                parameter_index = None
            else:
                continue
            wrappers[node.name] = (base_target, forwarded.id, parameter_index)
            changed = True
        if not changed:
            break
        pending = remaining
    return wrappers


def _python_call_argument_for_parameter(
    node: ast.Call, parameter: str, positional_index: int | None,
) -> ast.AST | None:
    keyword = next(
        (item.value for item in node.keywords if item.arg == parameter), None,
    )
    if keyword is not None:
        return keyword
    if positional_index is not None and positional_index < len(node.args):
        return node.args[positional_index]
    return None


def _python_primary_argument(node: ast.Call, keyword_names: set[str]) -> ast.AST | None:
    if node.args:
        return node.args[0]
    return next(
        (keyword.value for keyword in node.keywords if keyword.arg in keyword_names),
        None,
    )


def _python_call_contains_raw_digest(
    node: ast.Call, call_name: str | None, index: "_PythonAssignmentIndex",
) -> bool:
    if call_name not in {
        "subprocess.run", "subprocess.call", "subprocess.check_call",
        "subprocess.check_output", "subprocess.Popen",
        "os.system", "os.popen",
    }:
        return False
    candidate = _python_primary_argument(node, {"args", "command", "cmd"})
    return candidate is not None and RAW_DIGEST_COMMAND_RE.search(
        _python_argument_hint(candidate, node, index)
    ) is not None


class _PythonAssignmentIndex(ast.NodeVisitor):
    def __init__(self) -> None:
        self.scope = 0
        self.node_scopes: dict[int, int] = {}
        self.assignments: dict[int, dict[str, list[tuple[int, ast.AST]]]] = {}

    def generic_visit(self, node: ast.AST) -> None:
        self.node_scopes[id(node)] = self.scope
        super().generic_visit(node)

    def _visit_scope(self, node: ast.AST) -> None:
        self.node_scopes[id(node)] = self.scope
        previous = self.scope
        self.scope = id(node)
        super().generic_visit(node)
        self.scope = previous

    visit_FunctionDef = _visit_scope
    visit_AsyncFunctionDef = _visit_scope
    visit_Lambda = _visit_scope
    visit_ClassDef = _visit_scope

    def _record(self, name: str, value: ast.AST, line: int) -> None:
        self.assignments.setdefault(self.scope, {}).setdefault(name, []).append((line, value))

    def visit_Assign(self, node: ast.Assign) -> None:
        self.node_scopes[id(node)] = self.scope
        for target in node.targets:
            if isinstance(target, ast.Name):
                self._record(target.id, node.value, node.lineno)
        self.generic_visit(node)

    def visit_AnnAssign(self, node: ast.AnnAssign) -> None:
        self.node_scopes[id(node)] = self.scope
        if isinstance(node.target, ast.Name) and node.value is not None:
            self._record(node.target.id, node.value, node.lineno)
        self.generic_visit(node)


def _python_argument_hint(
    expression: ast.AST, call: ast.Call, index: _PythonAssignmentIndex,
) -> str:
    call_line = getattr(call, "lineno", 0)
    scope = index.node_scopes.get(id(call), 0)
    pieces: list[str] = [ast.unparse(expression)]
    seen: set[tuple[int, str]] = set()

    def resolve(node: ast.AST, active_scope: int) -> None:
        for child in ast.walk(node):
            if isinstance(child, ast.Constant) and isinstance(child.value, str):
                pieces.append(child.value)
            elif isinstance(child, ast.Name):
                for candidate_scope in (active_scope, 0):
                    key = (candidate_scope, child.id)
                    if key in seen:
                        continue
                    assignments = index.assignments.get(candidate_scope, {}).get(child.id, [])
                    prior = [item for item in assignments if item[0] < call_line]
                    if prior:
                        seen.add(key)
                        resolve(max(prior, key=lambda item: item[0])[1], candidate_scope)
                        break

    resolve(expression, scope)
    return " ".join(pieces).lower()


def _python_offset(text: str, node: ast.AST) -> int:
    lines = text.splitlines(keepends=True)
    line = max(getattr(node, "lineno", 1) - 1, 0)
    return sum(len(value) for value in lines[:line]) + getattr(node, "col_offset", 0)


def _python_digest_field_accesses(
    node: ast.AST, index: _PythonAssignmentIndex | None = None,
) -> set[str]:
    """Find direct or assigned mapping keys that declare a SHA-256 digest field."""
    fields: set[str] = set()
    comparison_line = getattr(node, "lineno", 0)
    comparison_scope = index.node_scopes.get(id(node), 0) if index is not None else 0
    seen: set[tuple[int, str]] = set()

    def collect_direct(expression: ast.AST) -> None:
        for child in ast.walk(expression):
            key: object = None
            if isinstance(child, ast.Subscript) and isinstance(child.slice, ast.Constant):
                key = child.slice.value
            elif (isinstance(child, ast.Call) and isinstance(child.func, ast.Attribute)
                  and child.func.attr == "get" and child.args
                  and isinstance(child.args[0], ast.Constant)):
                key = child.args[0].value
            if isinstance(key, str) and "sha256" in key.lower():
                fields.add(key)

    def inspect(expression: ast.AST, active_scope: int) -> None:
        collect_direct(expression)
        if index is None or not isinstance(expression, ast.Name):
            return
        for candidate_scope in (active_scope, 0):
            assignment_key = (candidate_scope, expression.id)
            if assignment_key in seen:
                continue
            assignments = index.assignments.get(candidate_scope, {}).get(expression.id, [])
            prior = [item for item in assignments if item[0] < comparison_line]
            if prior:
                seen.add(assignment_key)
                inspect(max(prior, key=lambda item: item[0])[1], candidate_scope)
                break

    collect_direct(node)
    if isinstance(node, ast.Compare):
        for expression in (node.left, *node.comparators):
            inspect(expression, comparison_scope)
    return fields


def _logical_non_python_command(lines: Sequence[str], index: int) -> str:
    """Return the complete YAML block command containing a physical line."""
    physical = lines[index]
    physical_indent = len(physical) - len(physical.lstrip())
    for marker_index in range(index - 1, -1, -1):
        candidate = lines[marker_index]
        if not candidate.strip():
            continue
        candidate_indent = len(candidate) - len(candidate.lstrip())
        if candidate_indent >= physical_indent:
            continue
        if re.search(r"\brun\s*:\s*>[+-]?\s*(?:#.*)?$", candidate.strip()) is None:
            break
        block: list[str] = []
        for block_line in lines[marker_index + 1:]:
            if block_line.strip():
                indent = len(block_line) - len(block_line.lstrip())
                if indent <= candidate_indent:
                    break
            block.append(block_line.strip())
        return " ".join(value for value in block if value)
    return physical


def evidence_digest_boundary_violations(root: Path) -> list[Violation]:
    """Keep repository text evidence on the typed, normalized digest path."""
    violations: list[Violation] = []
    declared_non_python: dict[tuple[str, str], str] = {}
    manifest_path = root / NON_PYTHON_DOMAIN_MANIFEST
    if manifest_path.is_file():
        try:
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            entries = manifest["entries"] if (
                isinstance(manifest, dict) and set(manifest) == {"schema_version", "entries"}
                and manifest.get("schema_version") == 1 and isinstance(manifest.get("entries"), list)
            ) else None
            if entries is None:
                raise ValueError("schema")
            for entry in entries:
                if not isinstance(entry, dict) or set(entry) != {"path", "command", "domain"}:
                    raise ValueError("entry")
                relative, command, domain = entry["path"], entry["command"], entry["domain"]
                if not all(isinstance(item, str) and item for item in (relative, command, domain)):
                    raise ValueError("value")
                candidate = Path(relative)
                if candidate.is_absolute() or ".." in candidate.parts or domain not in {
                    "artifact-bytes-v1", "text-utf8-lf-v1",
                }:
                    raise ValueError("domain")
                key = (candidate.as_posix(), command)
                if key in declared_non_python:
                    raise ValueError("duplicate")
                declared_non_python[key] = domain
        except (OSError, UnicodeDecodeError, json.JSONDecodeError, KeyError, ValueError):
            text = manifest_path.read_text(encoding="utf-8", errors="replace") if manifest_path.exists() else ""
            violations.append(_violation(
                root, manifest_path, text, 0, "digest-domain-manifest-invalid",
                "The non-Python digest domain manifest must use the known fail-closed schema.",
            ))
    python_paths: list[Path] = []
    for python_root in (root / "tools", root / "scripts", root / ".github/actions"):
        if python_root.is_dir():
            python_paths.extend(python_root.rglob("*.py"))
    python_paths = sorted(set(python_paths))
    for path in python_paths:
        relative = path.relative_to(root).as_posix()
        if _is_ignored(path.relative_to(root)):
            continue
        try:
            text = path.read_text(encoding="utf-8")
            tree = ast.parse(text, filename=relative)
        except (OSError, UnicodeDecodeError, SyntaxError) as error:
            fallback = path.read_text(encoding="utf-8", errors="replace") if path.exists() else ""
            violations.append(_violation(
                root, path, fallback, 0, "digest-scan-unreadable",
                f"Repository helper must be readable strict UTF-8 Python: {type(error).__name__}.",
            ))
            continue
        typed_implementation = relative == "tools/evidence_digest.py"
        repository_control_plane = relative.startswith("tools/repository/")
        aliases = _python_callable_aliases(tree, _python_import_aliases(tree))
        assignment_index = _PythonAssignmentIndex()
        assignment_index.visit(tree)
        digest_wrappers = _python_digest_wrappers(tree, aliases)
        for node in ast.walk(tree):
            if isinstance(node, (ast.Import, ast.ImportFrom)) and not typed_implementation:
                names = [item.name for item in node.names]
                if "hashlib" in names or (
                    isinstance(node, ast.ImportFrom) and node.module == "hashlib"
                ):
                    violations.append(_violation(
                        root, path, text, _python_offset(text, node),
                        "untyped-evidence-digest",
                        "Repository code must use the typed digest module, not hashlib.",
                    ))
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and not typed_implementation:
                if node.name in {
                    "sha256", "sha256_bytes", "_sha256", "file_sha256", "sha256_path",
                    "canonical_text_sha256", "repository_text_sha256",
                }:
                    violations.append(_violation(
                        root, path, text, _python_offset(text, node),
                        "untyped-evidence-digest-helper",
                        "Repository digest helpers must declare the text or artifact byte domain.",
                    ))
            if isinstance(node, ast.Call):
                name = _python_call_name(node, aliases)
                wrapper = digest_wrappers.get(name or "")
                effective_name = wrapper[0] if wrapper is not None else name
                if (not typed_implementation
                        and effective_name in {"hmac.compare_digest", "compare_digest"}
                        and _python_digest_field_accesses(node, assignment_index)):
                    violations.append(_violation(
                        root, path, text, _python_offset(text, node),
                        "untyped-evidence-digest-comparison",
                        "Repository evidence digests must be parsed into a typed domain before comparison.",
                    ))
                if not typed_implementation and _python_call_contains_raw_digest(
                    node, name, assignment_index,
                ):
                    violations.append(_violation(
                        root, path, text, _python_offset(text, node),
                        "untyped-evidence-digest-command",
                        "Python repository tools must not invoke raw SHA-256 commands.",
                    ))
                if not typed_implementation and effective_name in {
                    "hashlib.sha256", "sha256_path", "canonical_text_sha256",
                    "repository_text_sha256",
                }:
                    violations.append(_violation(
                        root, path, text, _python_offset(text, node),
                        "untyped-evidence-digest",
                        "Repository code must not calculate an untyped SHA-256 digest.",
                    ))
                if not typed_implementation and effective_name in {
                    "artifact_byte_digest", "artifact_byte_digest_bytes", "artifact_byte_sha256",
                    "artifact_bytes_sha256", "parse_artifact_digest",
                }:
                    digest_argument = (
                        _python_call_argument_for_parameter(node, wrapper[1], wrapper[2])
                        if wrapper is not None
                        else _python_primary_argument(node, {"path", "raw", "value"})
                    )
                    argument = (
                        _python_argument_hint(digest_argument, node, assignment_index)
                        if digest_argument is not None else ""
                    )
                    if repository_control_plane or any(
                        marker in argument for marker in PYTHON_TEXT_PATH_MARKERS
                    ):
                        violations.append(_violation(
                            root, path, text, _python_offset(text, node),
                            "text-evidence-byte-digest",
                            "Text evidence must not enter the artifact byte-digest domain.",
                        ))
            if isinstance(node, ast.Compare) and not typed_implementation:
                if (any(isinstance(operator, (ast.Eq, ast.NotEq)) for operator in node.ops)
                        and _python_digest_field_accesses(node, assignment_index)):
                    violations.append(_violation(
                        root, path, text, _python_offset(text, node),
                        "untyped-evidence-digest-comparison",
                        "Repository evidence digests must be parsed into a typed domain before comparison.",
                    ))
            if isinstance(node, ast.ExceptHandler):
                caught = ast.unparse(node.type) if node.type is not None else ""
                if caught != "UnicodeDecodeError":
                    continue
                fallback_calls = {
                    _python_call_name(child) for child in ast.walk(node)
                    if isinstance(child, ast.Call)
                }
                if fallback_calls & {
                    "artifact_byte_digest", "artifact_byte_digest_bytes", "hashlib.sha256", "sha256_path"
                }:
                    violations.append(_violation(
                        root, path, text, _python_offset(text, node),
                        "text-evidence-byte-fallback",
                        "Invalid UTF-8 must fail closed and must not fall back to a byte digest.",
                    ))
    non_python_paths: list[Path] = []
    scripts_root = root / "scripts"
    if scripts_root.is_dir():
        non_python_paths.extend(
            path for path in scripts_root.rglob("*") if path.is_file() and path.suffix != ".py"
        )
    tools_root = root / "tools"
    if tools_root.is_dir():
        non_python_paths.extend(
            path for path in tools_root.rglob("*")
            if path.is_file() and path.suffix != ".py"
            and path.name != "evidence-digest-non-python.json"
            and not _is_ignored(path.relative_to(root))
        )
    workflows_root = root / ".github/workflows"
    if workflows_root.is_dir():
        non_python_paths.extend(
            path for path in workflows_root.rglob("*") if path.suffix in {".yml", ".yaml"}
        )
    actions_root = root / ".github/actions"
    if actions_root.is_dir():
        non_python_paths.extend(
            path for path in actions_root.rglob("*")
            if path.is_file() and path.suffix != ".py"
            and not _is_ignored(path.relative_to(root))
        )
    for path in sorted(set(non_python_paths)):
        relative = path.relative_to(root).as_posix()
        try:
            text = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError) as error:
            fallback = path.read_text(encoding="utf-8", errors="replace") if path.exists() else ""
            violations.append(_violation(
                root, path, fallback, 0, "digest-scan-unreadable",
                f"Repository helper must be readable strict UTF-8 text: {type(error).__name__}.",
            ))
            continue
        lines = text.splitlines(keepends=True)
        for index, line in enumerate(lines):
            match = RAW_DIGEST_COMMAND_RE.search(line)
            if match is None:
                continue
            logical_command = _logical_non_python_command(lines, index)
            context = "".join(lines[max(0, index - 4):index + 1]).lower()
            declared_domain = declared_non_python.get((relative, line.strip()))
            operand_source = logical_command
            artifact_declared = (
                "wirestack-digest-domain: artifact-bytes-v1" in context
                or declared_domain == "artifact-bytes-v1"
            )
            text_declared = (
                "wirestack-digest-domain: text-utf8-lf-v1" in context
                or declared_domain == "text-utf8-lf-v1"
            )
            obvious_text = (
                TEXT_COMMAND_OPERAND_RE.search(operand_source) is not None
                or SHELL_VARIABLE_OPERAND_RE.search(operand_source) is not None
            )
            if artifact_declared and not obvious_text:
                continue
            offset = sum(len(value) for value in lines[:index]) + match.start()
            violations.append(_violation(
                root, path, text, offset,
                "text-evidence-raw-digest"
                if text_declared or (artifact_declared and obvious_text)
                else "untyped-non-python-digest",
                "Text evidence must use the canonicalizing digest helper."
                if text_declared or (artifact_declared and obvious_text) else
                "Shell and workflow SHA-256 commands must declare an explicit artifact-byte domain.",
            ))
    return violations


def run_guard(root: Path) -> list[Violation]:
    root = root.resolve()
    violations: list[Violation] = []
    paths = list(source_files(root))
    for path in paths:
        violations.extend(inspect_source(root, path))
    violations.extend(dependency_cycle_violations(root, paths))
    violations.extend(provider_boundary_violations(root, paths))
    violations.extend(evidence_digest_boundary_violations(root))
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
        "kind": "architecture-guard",
        "status": "PASS" if not violations else "FAIL",
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
