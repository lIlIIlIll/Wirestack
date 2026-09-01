#!/usr/bin/env python3
"""Typed SHA-256 domains for repository text evidence and binary artifacts."""

from __future__ import annotations

import argparse
import ast
import hashlib
import json
import os
import platform
import re
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Iterable, Mapping, Sequence

TEXT_EVIDENCE_DOMAIN = "text-utf8-lf-v1"
ARTIFACT_BYTE_DOMAIN = "artifact-bytes-v1"
DIGEST_KEYS = {"domain", "sha256"}
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
CHECKOUT_FIXTURE = Path("docs/evidence/P1-014/fixtures/line-endings.txt")
CHECKOUT_FIXTURE_TEXT = b"alpha\nbeta\n"
RAW_DIGEST_COMMAND = re.compile(
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
TEXT_COMMAND_OPERAND = re.compile(
    r"(?:"
    r"\.(?:json|md|markdown|log|txt|yaml|yml|cj|py|c|cc|cpp|h|hpp|sh)"
    r"(?=$|[\s'\";)])"
    r"|(?:^|[/\\\s'\"])(?:LICENSE|NOTICE)(?=$|[\s'\";)])"
    r")",
    re.IGNORECASE,
)
SHELL_VARIABLE_OPERAND = re.compile(
    r"\$(?:\{[A-Za-z_][A-Za-z0-9_]*\}|[A-Za-z_][A-Za-z0-9_]*)"
)
DIGEST_DOMAIN_MARKER = "wirestack-digest-domain:"
NON_PYTHON_DOMAIN_MANIFEST = Path("tools/evidence-digest-non-python.json")
PYTHON_TEXT_PATH_MARKERS = (
    "evidence", "report", "markdown", "log_path", "source_path",
    "validation", "read_text", ".json", ".md", ".markdown", ".log",
    ".txt", ".yaml", ".yml", ".cj", ".py", ".c", ".cc", ".cpp",
    ".h", ".hpp", ".sh",
)


class DigestError(ValueError):
    """Stable fail-closed error for digest domain and input violations."""

    def __init__(self, code: str, detail: str):
        super().__init__(detail)
        self.code = code
        self.detail = detail


def _validated_sha256(value: str) -> str:
    if not isinstance(value, str) or SHA256_RE.fullmatch(value) is None:
        raise DigestError("DIGEST_INVALID", "sha256 must be 64 lowercase hexadecimal characters")
    return value


@dataclass(frozen=True)
class TextEvidenceDigest:
    sha256: str

    def __post_init__(self) -> None:
        object.__setattr__(self, "sha256", _validated_sha256(self.sha256))

    def to_json(self) -> dict[str, str]:
        return {"domain": TEXT_EVIDENCE_DOMAIN, "sha256": self.sha256}


@dataclass(frozen=True)
class ArtifactByteDigest:
    sha256: str

    def __post_init__(self) -> None:
        object.__setattr__(self, "sha256", _validated_sha256(self.sha256))

    def to_json(self) -> dict[str, str]:
        return {"domain": ARTIFACT_BYTE_DOMAIN, "sha256": self.sha256}


def canonical_text_bytes(raw: bytes) -> bytes:
    try:
        text = raw.decode("utf-8", errors="strict")
    except UnicodeDecodeError as error:
        raise DigestError("TEXT_UTF8", "text evidence is not valid UTF-8") from error
    return text.replace("\r\n", "\n").replace("\r", "\n").encode("utf-8")


def text_evidence_digest_bytes(raw: bytes) -> TextEvidenceDigest:
    return TextEvidenceDigest(hashlib.sha256(canonical_text_bytes(raw)).hexdigest())


def text_evidence_digest(path: Path) -> TextEvidenceDigest:
    try:
        raw = path.read_bytes()
    except OSError as error:
        raise DigestError("DIGEST_READ", f"cannot read text evidence: {path}") from error
    return text_evidence_digest_bytes(raw)


def artifact_byte_digest_bytes(raw: bytes) -> ArtifactByteDigest:
    return ArtifactByteDigest(hashlib.sha256(raw).hexdigest())


def artifact_byte_digest(path: Path) -> ArtifactByteDigest:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(block)
    except OSError as error:
        raise DigestError("DIGEST_READ", f"cannot read binary artifact: {path}") from error
    return ArtifactByteDigest(digest.hexdigest())


def text_evidence_sha256(path: Path) -> str:
    """Return the hash component for protocols that define a SHA-256 string."""
    return text_evidence_digest(path).sha256


def text_evidence_bytes_sha256(raw: bytes) -> str:
    """Return the hash component for protocols that define a SHA-256 string."""
    return text_evidence_digest_bytes(raw).sha256


def artifact_byte_sha256(path: Path) -> str:
    """Return the hash component for protocols that define a SHA-256 string."""
    return artifact_byte_digest(path).sha256


def artifact_bytes_sha256(raw: bytes) -> str:
    """Return the hash component for protocols that define a SHA-256 string."""
    return artifact_byte_digest_bytes(raw).sha256


def text_evidence_sha256_equal(left: Any, right: Any) -> bool:
    """Compare two explicitly typed text-evidence digest objects."""
    try:
        return parse_text_digest(left, "left digest") == parse_text_digest(right, "right digest")
    except DigestError:
        return False


def artifact_byte_sha256_equal(left: Any, right: Any) -> bool:
    """Compare two explicitly typed artifact-byte digest objects."""
    try:
        return parse_artifact_digest(left, "left digest") == parse_artifact_digest(
            right, "right digest"
        )
    except DigestError:
        return False


def schema_text_sha256_equal(left: Any, right: Any) -> bool:
    """Compare SHA-256 strings only for a schema-owned text-digest field."""
    try:
        return TextEvidenceDigest(left) == TextEvidenceDigest(right)
    except DigestError:
        return False


def schema_artifact_sha256_equal(left: Any, right: Any) -> bool:
    """Compare SHA-256 strings only for a schema-owned artifact-digest field."""
    try:
        return ArtifactByteDigest(left) == ArtifactByteDigest(right)
    except DigestError:
        return False


def schema_text_sha256_map_equal(left: Any, right: Any) -> bool:
    """Compare a schema-owned mapping of text-digest SHA-256 strings."""
    if not isinstance(left, Mapping) or not isinstance(right, Mapping):
        return False
    if set(left) != set(right) or not all(isinstance(key, str) for key in left):
        return False
    return all(schema_text_sha256_equal(left[key], right[key]) for key in left)


def signed_payload_sha256(path: Path) -> str:
    """Return the exact byte digest of a payload whose signature binds raw bytes."""
    return artifact_byte_sha256(path)


def text_evidence_inventory_sha256(root: Path, paths: Iterable[Path]) -> str:
    """Hash a sorted repository text inventory and reject ambiguous NUL framing."""
    base = root.resolve()
    payload = bytearray()
    for path in sorted((value.resolve() for value in paths), key=lambda value: value.as_posix()):
        try:
            relative = path.relative_to(base).as_posix()
        except ValueError as error:
            raise DigestError("PATH_ESCAPE", f"text evidence path escapes repository: {path}") from error
        relative_bytes = relative.encode("utf-8")
        try:
            content = canonical_text_bytes(path.read_bytes())
        except OSError as error:
            raise DigestError("DIGEST_READ", f"cannot read text evidence: {path}") from error
        if b"\0" in relative_bytes or b"\0" in content:
            raise DigestError("TEXT_NUL", f"text evidence inventory contains NUL: {relative}")
        payload.extend(relative_bytes)
        payload.extend(b"\0")
        payload.extend(content)
        payload.extend(b"\0")
    return text_evidence_bytes_sha256(bytes(payload))


def _parse(raw: Any, expected_domain: str, factory: Callable[[str], Any], field: str) -> Any:
    if not isinstance(raw, dict):
        raise DigestError("DIGEST_TYPE", f"{field} must be a typed digest object")
    unknown = sorted(set(raw) - DIGEST_KEYS)
    if unknown or set(raw) != DIGEST_KEYS:
        raise DigestError("DIGEST_FIELDS", f"{field} must contain only domain and sha256")
    domain = raw.get("domain")
    if domain != expected_domain:
        raise DigestError("DIGEST_DOMAIN", f"{field} has unsupported or mismatched digest domain")
    return factory(raw.get("sha256"))


def parse_text_digest(raw: Any, field: str = "digest") -> TextEvidenceDigest:
    return _parse(raw, TEXT_EVIDENCE_DOMAIN, TextEvidenceDigest, field)


def parse_artifact_digest(raw: Any, field: str = "digest") -> ArtifactByteDigest:
    return _parse(raw, ARTIFACT_BYTE_DOMAIN, ArtifactByteDigest, field)


def atomic_json(path: Path, value: Mapping[str, Any], before_replace: Callable[[], None] | None = None) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    temporary = Path(name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as stream:
            json.dump(value, stream, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        if before_replace is not None:
            before_replace()
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def _revision(root: Path | None) -> str | None:
    if root is None:
        return os.environ.get("GITHUB_SHA")
    try:
        result = subprocess.run(
            ["git", "rev-parse", "HEAD"], cwd=root, capture_output=True,
            text=True, timeout=5, check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return os.environ.get("GITHUB_SHA")
    return result.stdout.strip() if result.returncode == 0 else os.environ.get("GITHUB_SHA")


def _effective_checkout_attributes(root: Path) -> dict[str, str]:
    try:
        result = subprocess.run(
            ["git", "check-attr", "text", "eol", "--", CHECKOUT_FIXTURE.as_posix()],
            cwd=root, capture_output=True, text=True, timeout=5, check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise DigestError("GITATTRIBUTES_CHECK", type(error).__name__) from error
    if result.returncode != 0:
        raise DigestError("GITATTRIBUTES_CHECK", f"exit {result.returncode}")
    attributes: dict[str, str] = {}
    prefix = f"{CHECKOUT_FIXTURE.as_posix()}: "
    for line in result.stdout.splitlines():
        if not line.startswith(prefix):
            raise DigestError("GITATTRIBUTES_CHECK", "unexpected output")
        name, separator, value = line[len(prefix):].partition(": ")
        if not separator or name not in {"text", "eol"}:
            raise DigestError("GITATTRIBUTES_CHECK", "unexpected attribute")
        attributes[name] = value
    if set(attributes) != {"text", "eol"}:
        raise DigestError("GITATTRIBUTES_CHECK", "missing attribute")
    if attributes["text"] not in {"set", "unset", "unspecified"}:
        raise DigestError("GITATTRIBUTES_CHECK", f"unexpected text {attributes['text']}")
    if attributes["eol"] not in {"lf", "crlf", "unspecified"}:
        raise DigestError("GITATTRIBUTES_CHECK", f"unexpected eol {attributes['eol']}")
    return attributes


def _normalized_architecture(value: str) -> str:
    normalized = value.strip().lower()
    if normalized in {"amd64", "x86_64"}:
        return "x86_64"
    if normalized in {"aarch64", "arm64"}:
        return "arm64"
    return normalized or "unknown"


def native_platform_identity() -> str:
    system = platform.system().strip().lower()
    architecture = _normalized_architecture(platform.machine())
    if system == "linux":
        libc_name = platform.libc_ver()[0].strip().lower()
        if libc_name in {"gnu libc", "glibc"}:
            libc_name = "glibc"
        elif "musl" in libc_name:
            libc_name = "musl"
        else:
            libc_name = libc_name or "unknown-libc"
        return f"linux-{architecture}-{libc_name}"
    if system == "windows":
        return f"windows-{architecture}"
    if system == "darwin":
        return f"macos-{architecture}"
    return f"{system or 'unknown'}-{architecture}"


def crlf_report(
    expected_platform: str | None = None,
    root: Path | None = None,
    expected_revision: str | None = None,
) -> dict[str, Any]:
    effective_root = root.resolve() if root is not None else Path(__file__).resolve().parents[1]
    actual = native_platform_identity()
    issues: list[dict[str, str]] = []
    if expected_platform and actual != expected_platform:
        issues.append({"code": "PLATFORM_MISMATCH", "detail": f"expected {expected_platform}, got {actual}"})
    revision = expected_revision or _revision(root)
    if expected_revision is not None and (
        not isinstance(revision, str) or re.fullmatch(r"[0-9a-f]{40}", revision) is None
    ):
        issues.append({
            "code": "REVISION_INVALID",
            "detail": "candidate revision must be a full lowercase Git SHA",
        })
    elif expected_revision is not None:
        checkout_revision = _revision(root)
        if checkout_revision != expected_revision:
            issues.append({
                "code": "REVISION_MISMATCH",
                "detail": "candidate revision does not match the checked-out Git HEAD",
            })
    variants = {
        "lf": b"alpha\nbeta\n",
        "crlf": b"alpha\r\nbeta\r\n",
        "bare_cr": b"alpha\rbeta\r",
    }
    text_digests = {name: text_evidence_digest_bytes(value).to_json() for name, value in variants.items()}
    byte_digests = {name: artifact_byte_digest_bytes(value).to_json() for name, value in variants.items()}
    if len({item["sha256"] for item in text_digests.values()}) != 1:
        issues.append({"code": "TEXT_LINE_ENDING_DRIFT", "detail": "canonical text digests differ"})
    if len({item["sha256"] for item in byte_digests.values()}) != len(variants):
        issues.append({"code": "BYTE_DOMAIN_COLLISION", "detail": "raw byte digests did not preserve line endings"})
    invalid_utf8 = "REJECTED"
    try:
        text_evidence_digest_bytes(b"valid\n\xff")
        invalid_utf8 = "ACCEPTED"
        issues.append({"code": "INVALID_UTF8_ACCEPTED", "detail": "invalid UTF-8 entered the text domain"})
    except DigestError as error:
        if error.code != "TEXT_UTF8":
            issues.append({"code": "INVALID_UTF8_ERROR", "detail": error.code})
    fixture_path = effective_root / CHECKOUT_FIXTURE
    fixture: dict[str, Any] = {"path": CHECKOUT_FIXTURE.as_posix(), "present": fixture_path.is_file()}
    if not fixture_path.is_file():
        issues.append({"code": "CHECKOUT_FIXTURE_MISSING", "detail": CHECKOUT_FIXTURE.as_posix()})
    else:
        fixture_bytes = fixture_path.read_bytes()
        fixture["byte_digest"] = artifact_byte_digest_bytes(fixture_bytes).to_json()
        try:
            fixture["text_digest"] = text_evidence_digest_bytes(fixture_bytes).to_json()
        except DigestError as error:
            issues.append({"code": error.code, "detail": CHECKOUT_FIXTURE.as_posix()})
        else:
            expected_fixture = text_evidence_digest_bytes(CHECKOUT_FIXTURE_TEXT).to_json()
            fixture["expected_text_digest"] = expected_fixture
            if fixture["text_digest"] != expected_fixture:
                issues.append({"code": "CHECKOUT_TEXT_DRIFT", "detail": CHECKOUT_FIXTURE.as_posix()})
        fixture["line_endings"] = (
            "CRLF" if b"\r\n" in fixture_bytes else "BARE_CR" if b"\r" in fixture_bytes else "LF"
        )
    gitattributes_dependency = False
    try:
        attributes = _effective_checkout_attributes(effective_root)
    except DigestError as error:
        text_attribute = "unknown"
        eol_attribute = "unknown"
        issues.append({"code": error.code, "detail": error.detail})
    else:
        text_attribute = attributes["text"]
        eol_attribute = attributes["eol"]
        if text_attribute == "unset":
            gitattributes_dependency = True
            issues.append({"code": "GITATTRIBUTES_DEPENDENCY", "detail": CHECKOUT_FIXTURE.as_posix()})
        if eol_attribute == "lf":
            gitattributes_dependency = True
            issues.append({"code": "GITATTRIBUTES_EOL_LF", "detail": CHECKOUT_FIXTURE.as_posix()})
    if actual.startswith("windows-") and fixture.get("line_endings") != "CRLF":
        issues.append({"code": "WINDOWS_CHECKOUT_NOT_CRLF", "detail": CHECKOUT_FIXTURE.as_posix()})
    return {
        "schema_version": 1,
        "kind": "p1-014-crlf-fault-injection",
        "status": "PASS" if not issues else "FAIL",
        "platform": {"system": platform.system(), "machine": platform.machine(), "identity": actual},
        "expected_platform": expected_platform,
        "revision": revision,
        "text_digests": text_digests,
        "byte_digests": byte_digests,
        "invalid_utf8": invalid_utf8,
        "checkout_fixture": fixture,
        "effective_text_attribute": text_attribute,
        "effective_eol_attribute": eol_attribute,
        "gitattributes_dependency": gitattributes_dependency,
        "issues": issues,
    }


_CALL_DOMAINS = {
    "text_evidence_digest": "text-evidence",
    "text_evidence_digest_bytes": "text-evidence",
    "parse_text_digest": "text-evidence",
    "artifact_byte_digest": "artifact-bytes",
    "artifact_byte_digest_bytes": "artifact-bytes",
    "parse_artifact_digest": "artifact-bytes",
    "text_evidence_sha256": "text-evidence",
    "text_evidence_bytes_sha256": "text-evidence",
    "artifact_byte_sha256": "artifact-bytes",
    "artifact_bytes_sha256": "artifact-bytes",
    "signed_payload_sha256": "artifact-bytes",
    "schema_text_sha256_equal": "text-evidence",
    "schema_text_sha256_map_equal": "text-evidence",
    "schema_artifact_sha256_equal": "artifact-bytes",
    "text_evidence_inventory_sha256": "text-evidence",
    "sha256_path": "legacy-task-local",
    "canonical_text_sha256": "legacy-task-local-text",
    "repository_text_sha256": "legacy-task-local-text",
}


def _import_aliases(tree: ast.AST) -> dict[str, str]:
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


def _expression_name(node: ast.AST) -> str | None:
    if isinstance(node, ast.Name):
        return node.id
    if isinstance(node, ast.Attribute):
        value = _expression_name(node.value)
        return f"{value}.{node.attr}" if value else node.attr
    return None


def _callable_aliases(tree: ast.AST, imported: dict[str, str]) -> dict[str, str]:
    aliases = dict(imported)
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
            name = _expression_name(value)
            if name is None:
                continue
            root, separator, remainder = name.partition(".")
            if root in aliases:
                name = aliases[root] + (separator + remainder if separator else "")
            final = name.rsplit(".", 1)[-1]
            if final in _CALL_DOMAINS or name == "hashlib.sha256":
                aliases[target] = name
                changed = True
            else:
                remaining.append((target, value))
        if not changed:
            break
        pending = remaining
    return aliases


def _call_name(node: ast.Call, aliases: dict[str, str] | None = None) -> str | None:
    name = _expression_name(node.func)
    if name is None:
        return None
    if aliases:
        root, separator, remainder = name.partition(".")
        if root in aliases:
            name = aliases[root] + (separator + remainder if separator else "")
    if name == "hashlib.sha256":
        return name
    final = name.rsplit(".", 1)[-1]
    return final if final in _CALL_DOMAINS else name


def _digest_wrappers(
    tree: ast.AST, aliases: dict[str, str],
) -> dict[str, tuple[str, str, int | None]]:
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
            target = _call_name(call, aliases)
            if target in _CALL_DOMAINS:
                base_target = target
                forwarded = _primary_argument(call, {"path", "raw", "value"})
            elif target in wrappers:
                base_target, target_parameter, target_index = wrappers[target]
                forwarded = _call_argument_for_parameter(
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


def _call_argument_for_parameter(
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


def _primary_argument(node: ast.Call, keyword_names: set[str]) -> ast.AST | None:
    if node.args:
        return node.args[0]
    return next(
        (keyword.value for keyword in node.keywords if keyword.arg in keyword_names),
        None,
    )


def _call_contains_raw_digest(
    node: ast.Call, call_name: str | None, index: "_AssignmentIndex",
) -> bool:
    if call_name not in {
        "subprocess.run", "subprocess.call", "subprocess.check_call",
        "subprocess.check_output", "subprocess.Popen",
        "os.system", "os.popen",
    }:
        return False
    candidate = _primary_argument(node, {"args", "command", "cmd"})
    return candidate is not None and RAW_DIGEST_COMMAND.search(
        _argument_hint(candidate, node, index)
    ) is not None


class _AssignmentIndex(ast.NodeVisitor):
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


def _argument_hint(expression: ast.AST, call: ast.Call, index: _AssignmentIndex) -> str:
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


def _declared_non_python_domains(root: Path) -> dict[tuple[str, str], str]:
    path = root / NON_PYTHON_DOMAIN_MANIFEST
    if not path.is_file():
        return {}
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise DigestError("DOMAIN_MANIFEST_INVALID", type(error).__name__) from error
    if not isinstance(value, dict) or set(value) != {"schema_version", "entries"}:
        raise DigestError("DOMAIN_MANIFEST_SCHEMA", "root fields")
    if value["schema_version"] != 1 or not isinstance(value["entries"], list):
        raise DigestError("DOMAIN_MANIFEST_SCHEMA", "version or entries")
    result: dict[tuple[str, str], str] = {}
    for entry in value["entries"]:
        if not isinstance(entry, dict) or set(entry) != {"path", "command", "domain"}:
            raise DigestError("DOMAIN_MANIFEST_SCHEMA", "entry fields")
        relative = entry["path"]
        command = entry["command"]
        domain = entry["domain"]
        if not all(isinstance(item, str) and item for item in (relative, command, domain)):
            raise DigestError("DOMAIN_MANIFEST_SCHEMA", "entry values")
        candidate = Path(relative)
        if candidate.is_absolute() or ".." in candidate.parts:
            raise DigestError("DOMAIN_MANIFEST_PATH", relative)
        if domain not in {TEXT_EVIDENCE_DOMAIN, ARTIFACT_BYTE_DOMAIN}:
            raise DigestError("DOMAIN_MANIFEST_DOMAIN", domain)
        key = (candidate.as_posix(), command)
        if key in result:
            raise DigestError("DOMAIN_MANIFEST_DUPLICATE", relative)
        result[key] = domain
    return result


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


def _digest_field_accesses(
    node: ast.AST, index: _AssignmentIndex | None = None,
) -> set[str]:
    """Find direct or assigned mapping keys that declare a SHA-256 digest field."""
    fields: set[str] = set()
    comparison_line = getattr(node, "lineno", 0)
    comparison_scope = index.node_scopes.get(id(node), 0) if index is not None else 0
    seen: set[tuple[int, str]] = set()

    def collect_direct(expression: ast.AST) -> None:
        for child in ast.walk(expression):
            key: Any = None
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


def digest_inventory(root: Path) -> dict[str, Any]:
    entries: list[dict[str, Any]] = []
    issues: list[dict[str, str]] = []
    try:
        declared_non_python = _declared_non_python_domains(root)
    except DigestError as error:
        declared_non_python = {}
        issues.append({"code": error.code, "detail": error.detail})
    for base in (root / "tools", root / "scripts", root / ".github/actions"):
        if not base.is_dir():
            continue
        for path in sorted(base.rglob("*.py")):
            if any(part in {"__pycache__", "build", "dist"} for part in path.parts):
                continue
            relative = path.relative_to(root).as_posix()
            try:
                tree = ast.parse(path.read_text(encoding="utf-8"), filename=relative)
            except (OSError, UnicodeDecodeError, SyntaxError) as error:
                issues.append({"code": "INVENTORY_PARSE", "detail": f"{relative}: {type(error).__name__}"})
                continue
            aliases = _callable_aliases(tree, _import_aliases(tree))
            assignment_index = _AssignmentIndex()
            assignment_index.visit(tree)
            digest_wrappers = _digest_wrappers(tree, aliases)
            for node in ast.walk(tree):
                if not (isinstance(node, ast.ImportFrom) and node.module == "hashlib"):
                    continue
                entries.append({
                    "path": relative, "line": node.lineno,
                    "symbol": "hashlib-import", "classification": "legacy-task-local",
                })
                issues.append({
                    "code": "UNTYPED_DIGEST",
                    "detail": f"{relative}:{node.lineno}:hashlib-import",
                })
            for node in ast.walk(tree):
                if not isinstance(node, ast.Call):
                    continue
                name = _call_name(node, aliases)
                if relative != "tools/evidence_digest.py" and _call_contains_raw_digest(
                    node, name, assignment_index,
                ):
                    entries.append({
                        "path": relative, "line": node.lineno,
                        "symbol": "raw-digest-command", "classification": "legacy-task-local",
                    })
                    issues.append({
                        "code": "UNTYPED_DIGEST",
                        "detail": f"{relative}:{node.lineno}:raw-digest-command",
                    })
                if (name == "hashlib.sha256" and isinstance(node.func, ast.Name)
                        and aliases.get(node.func.id) == "hashlib.sha256"):
                    # The direct import is already a fail-closed inventory entry.
                    continue
                wrapper = digest_wrappers.get(name or "")
                effective_name = wrapper[0] if wrapper is not None else name
                if (effective_name in {"hmac.compare_digest", "compare_digest"}
                        and _digest_field_accesses(node, assignment_index)):
                    entries.append({
                        "path": relative, "line": node.lineno,
                        "symbol": "bare-sha256-comparison",
                        "classification": "invalid-untyped-comparison",
                    })
                    issues.append({
                        "code": "UNTYPED_DIGEST",
                        "detail": f"{relative}:{node.lineno}:bare-sha256-comparison",
                    })
                if effective_name not in _CALL_DOMAINS and effective_name != "hashlib.sha256":
                    continue
                if effective_name == "hashlib.sha256":
                    domain = "typed-implementation" if relative == "tools/evidence_digest.py" else "legacy-task-local"
                else:
                    domain = _CALL_DOMAINS[effective_name]
                digest_argument = (
                    _call_argument_for_parameter(node, wrapper[1], wrapper[2])
                    if wrapper is not None
                    else _primary_argument(node, {"path", "raw", "value"})
                )
                if (domain == "artifact-bytes" and effective_name not in {
                        "signed_payload_sha256", "schema_artifact_sha256_equal",
                    }
                        and relative != "tools/evidence_digest.py" and digest_argument is not None):
                    argument = _argument_hint(digest_argument, node, assignment_index)
                    if any(marker in argument for marker in PYTHON_TEXT_PATH_MARKERS):
                        domain = "invalid-artifact-on-text"
                entries.append({"path": relative, "line": node.lineno, "symbol": name, "classification": domain})
                if domain.startswith("legacy") or domain == "invalid-artifact-on-text":
                    issues.append({"code": "UNTYPED_DIGEST", "detail": f"{relative}:{node.lineno}:{name}"})
            for node in ast.walk(tree):
                if not isinstance(node, ast.Compare) or relative == "tools/evidence_digest.py":
                    continue
                if (any(isinstance(operator, (ast.Eq, ast.NotEq)) for operator in node.ops)
                        and _digest_field_accesses(node, assignment_index)):
                    entries.append({
                        "path": relative, "line": node.lineno,
                        "symbol": "bare-sha256-comparison", "classification": "legacy-task-local",
                    })
                    issues.append({
                        "code": "UNTYPED_DIGEST",
                        "detail": f"{relative}:{node.lineno}:bare-sha256-comparison",
                    })
    non_python_paths: list[Path] = []
    scripts = root / "scripts"
    if scripts.is_dir():
        non_python_paths.extend(
            path for path in scripts.rglob("*") if path.is_file() and path.suffix != ".py"
        )
    tools_root = root / "tools"
    if tools_root.is_dir():
        non_python_paths.extend(
            path for path in tools_root.rglob("*")
            if path.is_file() and path.suffix != ".py"
            and path.name != "evidence-digest-non-python.json"
            and not any(part in {"__pycache__", "build", "dist"} for part in path.parts)
        )
    workflows = root / ".github/workflows"
    if workflows.is_dir():
        non_python_paths.extend(path for path in workflows.rglob("*") if path.suffix in {".yml", ".yaml"})
    actions = root / ".github/actions"
    if actions.is_dir():
        non_python_paths.extend(
            path for path in actions.rglob("*")
            if path.is_file() and path.suffix != ".py"
            and not any(part in {"__pycache__", "build", "dist"} for part in path.parts)
        )
    for path in sorted(set(non_python_paths)):
        relative = path.relative_to(root).as_posix()
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except (OSError, UnicodeDecodeError) as error:
            issues.append({"code": "INVENTORY_PARSE", "detail": f"{relative}: {type(error).__name__}"})
            continue
        for index, line in enumerate(lines):
            if RAW_DIGEST_COMMAND.search(line) is None:
                continue
            logical_command = _logical_non_python_command(lines, index)
            context = "\n".join(lines[max(0, index - 4):index + 1]).lower()
            declared_domain = declared_non_python.get((relative, line.strip()))
            operand_source = logical_command
            obvious_text = (
                TEXT_COMMAND_OPERAND.search(operand_source) is not None
                or SHELL_VARIABLE_OPERAND.search(operand_source) is not None
            )
            if f"{DIGEST_DOMAIN_MARKER} {ARTIFACT_BYTE_DOMAIN}" in context:
                domain = "invalid-artifact-on-text" if obvious_text else "artifact-bytes"
            elif f"{DIGEST_DOMAIN_MARKER} {TEXT_EVIDENCE_DOMAIN}" in context:
                domain = "invalid-text-command"
            elif declared_domain == ARTIFACT_BYTE_DOMAIN:
                domain = "invalid-artifact-on-text" if obvious_text else "artifact-bytes"
            elif declared_domain == TEXT_EVIDENCE_DOMAIN:
                domain = "invalid-text-command"
            else:
                domain = "legacy-non-python"
            entries.append({
                "path": relative, "line": index + 1,
                "symbol": RAW_DIGEST_COMMAND.search(line).group(0), "classification": domain,
            })
            if domain.startswith("legacy") or domain in {
                "invalid-text-command", "invalid-artifact-on-text",
            }:
                issues.append({"code": "UNTYPED_DIGEST", "detail": f"{relative}:{index + 1}:raw-command"})
    entries.sort(key=lambda item: (item["path"], item["line"], item["symbol"]))
    domain_counts: dict[str, int] = {}
    for entry in entries:
        classification = entry["classification"]
        domain_counts[classification] = domain_counts.get(classification, 0) + 1
    return {
        "schema_version": 1,
        "kind": "p1-014-digest-inventory",
        "status": "PASS" if not issues else "FAIL",
        "scope": "repository-wide typed digest callsite inventory",
        "entry_count": len(entries),
        "domain_counts": dict(sorted(domain_counts.items())),
        "entries": entries,
        "issues": issues,
    }


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    sub = result.add_subparsers(dest="command", required=True)
    crlf = sub.add_parser("crlf-report")
    crlf.add_argument("--expected-platform")
    crlf.add_argument("--expected-revision")
    crlf.add_argument("--output", type=Path, required=True)
    inventory = sub.add_parser("inventory")
    inventory.add_argument("--output", type=Path, required=True)
    return result


def main(argv: Sequence[str] | None = None) -> int:
    args = parser().parse_args(argv)
    root = args.root.resolve()
    report = (
        crlf_report(args.expected_platform, root, args.expected_revision)
        if args.command == "crlf-report" else digest_inventory(root)
    )
    output = args.output if args.output.is_absolute() else root / args.output
    atomic_json(output, report)
    summary = {
        "kind": report["kind"],
        "status": report["status"],
        "issues": report.get("issues", [])[:20],
        "output": str(output),
    }
    if "entry_count" in report:
        summary["entry_count"] = report["entry_count"]
    print(json.dumps(summary, sort_keys=True))
    return 0 if report["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
