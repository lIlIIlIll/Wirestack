#!/usr/bin/env python3
"""Generate and validate Wirestack's public documentation with cjdoc 0.7.2.

The project contains implementation packages whose declarations are public for
package use.  A normal whole-project cjdoc scan therefore includes internal
implementation and test sources and can hit the generator's bounded resource
fallback.  This gate builds a temporary, read-only source view containing only
the public package sources, runs one independent layer for each public package,
then generates the committed artifacts from the same public view.  A partial
Doc IR, warning, schema mismatch or coverage shortfall is never promoted to
PASS.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import platform
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any, Iterable, Mapping, Sequence

ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from tools.evidence_digest import text_evidence_digest

TASK_ID = "M7-033"
EXPECTED_CJDOC_VERSION = "0.7.2"
DOC_IR_SCHEMA = "cjdoc.doc-ir/8"
API_SCHEMA = "cjdoc.api-surface/1"
COVERAGE_SCHEMA = "cjdoc.documentation-coverage/1"
CAPTURE_BYTES = 16_384
DEFAULT_TIMEOUT_SECONDS = 1_800

PUBLIC_ROOT_FILES = (
    "byte_span.cj",
    "cancellation.cj",
    "common.cj",
    "deadline.cj",
    "hostname_verifier.cj",
    "http_body.cj",
    "http_contract.cj",
    "http_message.cj",
    "http_model.cj",
    "http_url.cj",
    "network_error.cj",
    "network_event.cj",
    "operation_context.cj",
    "package.cj",
    "private_key_contract.cj",
    "resolver.cj",
    "tls_contract.cj",
    "transport.cj",
    "trust.cj",
)
PUBLIC_PACKAGE_FILES = {
    "wirestack.http": (
        "cancellation.cj",
        "client.cj",
        "error.cj",
        "package.cj",
        "proxy.cj",
        "redirect.cj",
        "resolver.cj",
        "retry.cj",
        "server.cj",
        "tls.cj",
    ),
    "wirestack.tls": ("facade.cj", "identity.cj", "package.cj"),
}


class DocsError(ValueError):
    """Stable failure category used by the command and unit tests."""

    def __init__(self, code: str, detail: str):
        super().__init__(detail)
        self.code = code
        self.detail = detail


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def _bounded(value: bytes | str, limit: int = CAPTURE_BYTES) -> tuple[str, bool]:
    raw = value if isinstance(value, bytes) else value.encode("utf-8", errors="replace")
    truncated = len(raw) > limit
    return raw[:limit].decode("utf-8", errors="replace"), truncated


def _safe_path(root: Path, value: str) -> Path:
    if not isinstance(value, str) or not value or Path(value).is_absolute():
        raise DocsError("PATH_INVALID", "path must be repository-relative")
    candidate = (root / value).resolve(strict=False)
    try:
        candidate.relative_to(root.resolve())
    except ValueError as error:
        raise DocsError("PATH_ESCAPE", f"path escapes repository: {value}") from error
    return candidate


def atomic_json(path: Path, value: Mapping[str, Any]) -> None:
    """Replace a JSON report atomically and leave the old report on failure."""
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    try:
        temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
                             encoding="utf-8", newline="\n")
        os.replace(temporary, path)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def _text_digest(path: Path) -> str:
    """Digest generated JSON/Markdown as canonical UTF-8 text evidence."""
    return text_evidence_digest(path).sha256


def public_source_paths(root: Path = ROOT) -> list[Path]:
    source_root = root / "src"
    actual_root = tuple(sorted(
        path.name for path in source_root.glob("*.cj") if not path.name.endswith("_test.cj")
    ))
    if actual_root != tuple(sorted(PUBLIC_ROOT_FILES)):
        raise DocsError("SOURCE_INVENTORY", "public root source inventory changed; update the layer manifest")
    paths = [source_root / name for name in PUBLIC_ROOT_FILES]
    for directory, names in PUBLIC_PACKAGE_FILES.items():
        package_dir = directory.rsplit(".", 1)[-1]
        actual_package = tuple(sorted(
            path.name for path in (source_root / package_dir).glob("*.cj")
            if not path.name.endswith("_test.cj")
        ))
        if actual_package != tuple(sorted(names)):
            raise DocsError("SOURCE_INVENTORY", f"{directory} source inventory changed; update the layer manifest")
        paths.extend(source_root / package_dir / name for name in names)
    missing = [str(path.relative_to(root)) for path in paths if not path.is_file()]
    if missing:
        raise DocsError("SOURCE_MISSING", ", ".join(sorted(missing)))
    return paths


def _find_cjdoc() -> str | None:
    configured = os.environ.get("CJDOC_BIN") or os.environ.get("CJDOC")
    if configured:
        return configured
    return shutil.which("cjdoc")


def resolve_cjdoc(root: Path = ROOT) -> tuple[str, str]:
    executable = _find_cjdoc()
    if not executable:
        raise DocsError("CJDOC_MISSING", "cjdoc is not available; install the pinned 0.7.2 release")
    try:
        result = subprocess.run([executable, "--version"], cwd=root, capture_output=True,
                                timeout=15, check=False)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise DocsError("CJDOC_UNAVAILABLE", "cjdoc --version could not be executed") from error
    stdout, _ = _bounded(result.stdout)
    stderr, _ = _bounded(result.stderr)
    if result.returncode != 0:
        raise DocsError("CJDOC_VERSION", "cjdoc --version returned a non-zero status")
    version_text = (stdout + "\n" + stderr).strip()
    tokens = version_text.split()
    version = tokens[1] if len(tokens) >= 2 and tokens[0].lower() == "cjdoc" else ""
    if version != EXPECTED_CJDOC_VERSION:
        raise DocsError("CJDOC_VERSION", f"expected cjdoc {EXPECTED_CJDOC_VERSION}, got {version or 'unknown'}")
    return executable, version


def _copy_public_view(root: Path, destination: Path, files: Iterable[Path]) -> None:
    (destination / "src").mkdir(parents=True, exist_ok=True)
    shutil.copy2(root / "cjpm.toml", destination / "cjpm.toml")
    for path in files:
        relative = path.relative_to(root)
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, target)


def _run(argv: Sequence[str], root: Path, timeout: int) -> dict[str, Any]:
    try:
        result = subprocess.run(argv, cwd=root, capture_output=True, timeout=timeout, check=False)
    except subprocess.TimeoutExpired as error:
        stdout, stdout_truncated = _bounded(error.stdout or b"")
        stderr, stderr_truncated = _bounded(error.stderr or b"")
        return {"status": "TIMEOUT", "returncode": 124, "stdout": stdout,
                "stderr": stderr, "stdout_truncated": stdout_truncated,
                "stderr_truncated": stderr_truncated}
    except OSError:
        return {"status": "EXEC_ERROR", "returncode": 127, "stdout": "", "stderr": "",
                "stdout_truncated": False, "stderr_truncated": False}
    stdout, stdout_truncated = _bounded(result.stdout)
    stderr, stderr_truncated = _bounded(result.stderr)
    return {"status": "PASS" if result.returncode == 0 else "FAIL",
            "returncode": result.returncode, "stdout": stdout, "stderr": stderr,
            "stdout_truncated": stdout_truncated, "stderr_truncated": stderr_truncated}


def _read_json(path: Path, code: str) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise DocsError(code, f"invalid JSON artifact: {path}") from error
    if not isinstance(value, dict):
        raise DocsError(code, f"JSON artifact is not an object: {path}")
    return value


def validate_doc_ir(value: Mapping[str, Any]) -> int:
    if value.get("schemaVersion") != DOC_IR_SCHEMA:
        raise DocsError("DOC_IR_SCHEMA", "Doc IR schema is not cjdoc.doc-ir/8")
    generator = value.get("generator")
    if not isinstance(generator, dict) or generator.get("name") != "cjdoc" or generator.get("version") != EXPECTED_CJDOC_VERSION:
        raise DocsError("DOC_IR_GENERATOR", "Doc IR generator is not cjdoc 0.7.2")
    if value.get("status") != "complete":
        raise DocsError("DOC_IR_PARTIAL", "Doc IR status is not complete")
    diagnostics = value.get("diagnostics")
    if not isinstance(diagnostics, list) or diagnostics:
        raise DocsError("DOC_IR_DIAGNOSTICS", "Doc IR contains diagnostics")
    declarations = value.get("declarations")
    if not isinstance(declarations, list):
        raise DocsError("DOC_IR_DECLARATIONS", "Doc IR declarations is not an array")
    return len(declarations)


def validate_api_surface(value: Mapping[str, Any]) -> int:
    if value.get("schemaVersion") != API_SCHEMA:
        raise DocsError("API_SCHEMA", "API surface schema is not cjdoc.api-surface/1")
    if value.get("audience") != "external" or not isinstance(value.get("project"), str):
        raise DocsError("API_CONFIG", "API surface audience/project is invalid")
    declarations = value.get("declarations")
    exposures = value.get("exposures")
    if not isinstance(declarations, list) or not isinstance(exposures, list):
        raise DocsError("API_DECLARATIONS", "API surface arrays are invalid")
    return len(declarations) + len(exposures)


def validate_coverage(value: Mapping[str, Any]) -> dict[str, Any]:
    if value.get("schemaVersion") != COVERAGE_SCHEMA or value.get("audience") != "external":
        raise DocsError("COVERAGE_SCHEMA", "documentation coverage schema or audience is invalid")
    result: dict[str, Any] = {}
    for key in ("symbols", "parameters"):
        counts = value.get(key)
        if not isinstance(counts, dict) or set(counts) != {"total", "documented", "percent"}:
            raise DocsError("COVERAGE_SHAPE", f"coverage {key} object is invalid")
        if (not all(isinstance(counts[item], int) and not isinstance(counts[item], bool)
                    for item in ("total", "documented", "percent"))
                or counts["documented"] != counts["total"] or counts["percent"] != 100):
            raise DocsError("COVERAGE_INCOMPLETE", f"coverage {key} is below 100 percent")
        result[key] = counts
    return result


def _artifact_paths(output: Path) -> dict[str, Path]:
    return {
        "docs": output / "docs.json",
        "api": output / "api-surface" / "api-surface.json",
        "coverage": output / "coverage" / "coverage.json",
        "markdown": output / "markdown" / "index.md",
        "html": output / "html" / "index.html",
        "search": output / "html" / "search-index.js",
    }


def _validate_layer(output: Path, package: str) -> dict[str, Any]:
    paths = _artifact_paths(output)
    for key in ("docs", "api", "coverage", "markdown"):
        if not paths[key].is_file():
            raise DocsError("ARTIFACT_MISSING", f"missing {package} {key} artifact")
    docs = _read_json(paths["docs"], "DOC_IR_JSON")
    api = _read_json(paths["api"], "API_JSON")
    coverage = _read_json(paths["coverage"], "COVERAGE_JSON")
    declarations = validate_doc_ir(docs)
    api_entries = validate_api_surface(api)
    coverage_result = validate_coverage(coverage)
    return {"package": package, "status": "PASS", "declarations": declarations,
            "apiEntries": api_entries, "coverage": coverage_result,
            "docsSha256": _text_digest(paths["docs"]), "apiSha256": _text_digest(paths["api"]),
            "coverageSha256": _text_digest(paths["coverage"]),
            "markdownSha256": _text_digest(paths["markdown"])}


def _generate(cjdoc: str, project: Path, output: Path, include_html: bool,
              timeout: int) -> dict[str, Any]:
    formats = ["json", "api-surface", "coverage", "markdown"]
    if include_html:
        formats.append("html")
    argv = [cjdoc, "generate", "--project", str(project), "--audience", "external",
            "--lint-profile", "strict", "--jobs", "1", "--locale", "zh-CN"]
    for fmt in formats:
        argv.extend(["--format", fmt])
    argv.extend(["--output", str(output)])
    return _run(argv, project, timeout)


def _check(cjdoc: str, project: Path, timeout: int) -> dict[str, Any]:
    argv = [cjdoc, "check", "--project", str(project), "--deny-warnings",
            "--lint-profile", "strict", "--min-symbol-coverage", "100",
            "--min-parameter-coverage", "100"]
    return _run(argv, project, timeout)


def _source_inventory(root: Path, files: Iterable[Path]) -> dict[str, str]:
    return {str(path.relative_to(root)): _text_digest(path) for path in sorted(files)}


def build_report(root: Path = ROOT, *, include_html: bool = False,
                 timeout: int = DEFAULT_TIMEOUT_SECONDS) -> dict[str, Any]:
    report: dict[str, Any] = {
        "schemaVersion": 1,
        "taskId": TASK_ID,
        "status": "BLOCKED",
        "generatedAtUtc": utc_now(),
        "platform": {"system": platform.system(), "machine": platform.machine(),
                      "libc": platform.libc_ver()[0] or "unknown"},
        "expectedCjdoc": EXPECTED_CJDOC_VERSION,
        "layers": [],
        "commands": [],
        "sourceSha256": {},
        "artifacts": {},
        "issues": [],
    }
    try:
        cjdoc, version = resolve_cjdoc(root)
        report["cjdoc"] = {"path": cjdoc, "version": version}
        files = public_source_paths(root)
        report["sourceSha256"] = _source_inventory(root, files)
        with tempfile.TemporaryDirectory(prefix="wirestack-m7-033-") as directory:
            staging = Path(directory)
            for package in ("wirestack", *PUBLIC_PACKAGE_FILES):
                package_files = list(root / "src" / name for name in PUBLIC_ROOT_FILES)
                if package != "wirestack":
                    package_dir = package.rsplit(".", 1)[-1]
                    package_files.extend(root / "src" / package_dir / name
                                         for name in PUBLIC_PACKAGE_FILES[package])
                project = staging / package.replace(".", "-") / "project"
                output = staging / package.replace(".", "-") / "output"
                _copy_public_view(root, project, package_files)
                check_command = _check(cjdoc, project, timeout)
                report["commands"].append({"package": package, "kind": "check", **check_command})
                if check_command["status"] != "PASS":
                    raise DocsError("CJDOC_CHECK", f"{package} strict check returned {check_command['returncode']}")
                command = _generate(cjdoc, project, output, False, timeout)
                report["commands"].append({"package": package, "kind": "generate", **command})
                if command["status"] != "PASS":
                    raise DocsError("CJDOC_GENERATE", f"{package} generation returned {command['returncode']}")
                report["layers"].append(_validate_layer(output, package))

            combined_project = staging / "combined" / "project"
            combined_output = staging / "combined" / "output"
            _copy_public_view(root, combined_project, files)
            check_command = _check(cjdoc, combined_project, timeout)
            report["commands"].append({"package": "combined", "kind": "check", **check_command})
            if check_command["status"] != "PASS":
                raise DocsError("CJDOC_CHECK", "combined strict check returned a non-zero status")
            command = _generate(cjdoc, combined_project, combined_output, include_html, timeout)
            report["commands"].append({"package": "combined", "kind": "generate", **command})
            if command["status"] != "PASS":
                raise DocsError("CJDOC_GENERATE", "combined generation returned a non-zero status")
            combined = _validate_layer(combined_output, "combined")
            if include_html:
                paths = _artifact_paths(combined_output)
                for key in ("html", "search"):
                    if not paths[key].is_file():
                        raise DocsError("HTML_MISSING", f"missing HTML artifact: {key}")
                combined["htmlSha256"] = _text_digest(paths["html"])
                combined["searchSha256"] = _text_digest(paths["search"])
                combined["htmlPages"] = sorted(
                    str(path.relative_to(combined_output / "html"))
                    for path in (combined_output / "html").rglob("*.html")
                    if path.name != "index.html"
                )
            report["combined"] = combined

            generated = root / "docs/api/generated"
            generated.mkdir(parents=True, exist_ok=True)
            paths = _artifact_paths(combined_output)
            shutil.copy2(paths["docs"], generated / "docs.json")
            shutil.copy2(paths["api"], generated / "api-surface.json")
            shutil.copy2(paths["coverage"], generated / "coverage.json")
            markdown = generated / "markdown"
            if markdown.exists():
                shutil.rmtree(markdown)
            shutil.copytree(combined_output / "markdown", markdown)
            if include_html:
                html = root / "target/doc/html"
                if html.exists():
                    shutil.rmtree(html)
                html.parent.mkdir(parents=True, exist_ok=True)
                shutil.copytree(combined_output / "html", html)
                report["artifacts"]["html"] = str(html.relative_to(root))
            report["artifacts"].update({
                "docs": "docs/api/generated/docs.json",
                "api": "docs/api/generated/api-surface.json",
                "coverage": "docs/api/generated/coverage.json",
                "markdown": "docs/api/generated/markdown",
            })
        report["status"] = "PASS"
    except DocsError as error:
        report["status"] = "BLOCKED" if error.code in {"CJDOC_MISSING", "CJDOC_UNAVAILABLE", "CJDOC_VERSION"} else "FAIL"
        report["issues"].append({"code": error.code, "detail": error.detail})
    except (OSError, shutil.Error) as error:
        report["status"] = "FAIL"
        report["issues"].append({"code": "IO", "detail": "documentation artifact operation failed"})
    return report


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--html", action="store_true", help="also stage target/doc/html for Pages")
    args = parser.parse_args(argv)
    root = args.root.resolve()
    report = build_report(root, include_html=args.html)
    output = args.output or root / "docs/evidence/M7-033/docs-report.json"
    if not output.is_absolute():
        output = root / output
    output_allowed = True
    try:
        output.resolve(strict=False).relative_to(root)
    except ValueError:
        output_allowed = False
        report["status"] = "FAIL"
        report["issues"].append({"code": "PATH_ESCAPE", "detail": "report output must remain inside the repository"})
    if output_allowed:
        try:
            atomic_json(output, report)
        except OSError:
            report["status"] = "FAIL"
            report["issues"].append({"code": "REPORT_WRITE", "detail": "could not write docs report atomically"})
    if args.json:
        print(json.dumps(report, ensure_ascii=False, sort_keys=True))
    else:
        print(f"M7-033 docs: {report['status']}")
        for issue in report.get("issues", [])[:20]:
            print(f"- {issue['code']}: {issue['detail']}")
    return {"PASS": 0, "FAIL": 1, "BLOCKED": 3}.get(report["status"], 2)


if __name__ == "__main__":
    raise SystemExit(main())
