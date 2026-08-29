#!/usr/bin/env python3
"""Fail-closed checks for Wirestack's maintained documentation."""

from __future__ import annotations

import argparse
import json
import os
import re
import tempfile
from pathlib import Path
from typing import Any, Callable, Iterable

ROOT = Path(__file__).resolve().parents[1]
MAX_ISSUES = 100
MAX_DETAIL = 500
LINK = re.compile(r"(?<!!)\[[^]]+\]\(([^)]+)\)")
HEADING = re.compile(r"^#{1,6}\s+(.+?)\s*$")
FENCE = re.compile(r"^\s*(```|~~~)")

MAINTAINED = (
    "README.md",
    "CONTRIBUTING.md",
    "SECURITY.md",
    "CHANGELOG.md",
    "docs/README.md",
    "docs/getting-started.md",
    "docs/api/README.md",
    "docs/architecture/README.md",
    "docs/architecture/architecture-guard.md",
    "docs/architecture/current-network-stack-inventory.md",
    "docs/architecture/linux-tls-provider-build.md",
    "docs/architecture/tls-provider-candidate-matrix.md",
    "docs/architecture/tls-provider-poc-contract.md",
    "docs/gates/README.md",
    "docs/gates/framework.md",
    "docs/guides/http1-linux.md",
    "docs/guides/migrate-to-wirestack-linux.md",
    "docs/performance/README.md",
    "docs/performance/http1-benchmark.md",
    "docs/performance/http2-benchmark.md",
    "docs/planning/README.md",
    "docs/references/README.md",
    "docs/references/environment.md",
    "docs/security/README.md",
)


def slug(value: str) -> str:
    value = re.sub(r"<[^>]+>", "", value).strip().lower()
    value = re.sub(r"[`*_~]", "", value)
    value = re.sub(r"[^\w\-\u4e00-\u9fff ]", "", value)
    return re.sub(r"[\s-]+", "-", value).strip("-")


def anchors(text: str) -> set[str]:
    result: set[str] = set()
    seen: dict[str, int] = {}
    for line in text.splitlines():
        match = HEADING.match(line)
        if not match:
            continue
        base = slug(match.group(1))
        count = seen.get(base, 0)
        seen[base] = count + 1
        result.add(base if count == 0 else f"{base}-{count}")
    return result


def issue(code: str, path: str, detail: str) -> dict[str, str]:
    return {"code": code, "path": path, "detail": detail[:MAX_DETAIL]}


def _safe_target(root: Path, source: Path, raw: str) -> tuple[Path | None, str]:
    target = raw.strip()
    if target.startswith("<") and target.endswith(">"):
        target = target[1:-1]
    if target.startswith(("http://", "https://", "mailto:")):
        return None, ""
    path_text, _, anchor = target.partition("#")
    candidate = source if not path_text else source.parent / path_text
    try:
        resolved = candidate.resolve()
        resolved.relative_to(root.resolve())
    except (OSError, ValueError):
        raise ValueError("PATH_ESCAPE")
    return resolved, anchor


def validate(
    root: Path = ROOT,
    maintained: Iterable[str] = MAINTAINED,
    *,
    enforce_repository_facts: bool = True,
) -> dict[str, Any]:
    problems: list[dict[str, str]] = []
    checked_links = 0
    checked_files = 0
    for relative in maintained:
        path = root / relative
        if not path.is_file():
            problems.append(issue("MISSING_DOCUMENT", relative, "required maintained document is absent"))
            continue
        checked_files += 1
        text = path.read_text(encoding="utf-8")
        active: str | None = None
        for line_number, line in enumerate(text.splitlines(), 1):
            marker = FENCE.match(line)
            if marker:
                token = marker.group(1)
                active = None if active == token else token if active is None else active
        if active is not None:
            problems.append(issue("UNCLOSED_FENCE", relative, "Markdown code fence is not closed"))
        for match in LINK.finditer(text):
            checked_links += 1
            raw = match.group(1)
            try:
                target, anchor = _safe_target(root, path, raw)
            except ValueError:
                problems.append(issue("PATH_ESCAPE", relative, raw))
                continue
            if target is None:
                continue
            if not target.exists():
                problems.append(issue("MISSING_LINK_TARGET", relative, raw))
                continue
            if anchor and target.is_file() and target.suffix.lower() == ".md":
                if anchor not in anchors(target.read_text(encoding="utf-8")):
                    problems.append(issue("MISSING_ANCHOR", relative, raw))
        if len(problems) >= MAX_ISSUES:
            break

    if enforce_repository_facts:
        root_readme = (root / "README.md").read_text(encoding="utf-8") if (root / "README.md").is_file() else ""
        required_root = ("Linux x86_64 glibc", "M7-022", "docs/README.md", "scripts/check-fast", "scripts/check-long")
        for token in required_root:
            if token not in root_readme:
                problems.append(issue("STALE_ROOT_FACT", "README.md", f"missing required token: {token}"))
        if "M1-024" in root_readme or "M1-025" in root_readme:
            problems.append(issue("STALE_CURRENT_TASK", "README.md", "completed M1 task is presented as current"))

        docs_index = (root / "docs/README.md").read_text(encoding="utf-8") if (root / "docs/README.md").is_file() else ""
        for token in ("Getting started", "API", "Architecture", "Security", "Performance", "Evidence"):
            if token not in docs_index:
                problems.append(issue("INCOMPLETE_DOCS_INDEX", "docs/README.md", f"missing route: {token}"))

        contributor = (root / "CONTRIBUTING.md").read_text(encoding="utf-8") if (root / "CONTRIBUTING.md").is_file() else ""
        if "scripts/check-long" not in contributor or "scripts/check-fast" not in contributor:
            problems.append(issue("VALIDATION_LAYER_MISSING", "CONTRIBUTING.md", "validation layers are incomplete"))
        if re.search(r"scripts/check(?:-fast|-full)?[^\n]*24", contributor):
            problems.append(issue("LONG_GATE_DEFAULT", "CONTRIBUTING.md", "long gate appears in a default validation path"))

    status = "PASS" if not problems else "FAIL"
    return {
        "schema_version": 1,
        "task_id": "P1-013",
        "status": status,
        "acceptance_status": status,
        "platform": "linux-x86_64-glibc",
        "counts": {"files": checked_files, "links": checked_links, "issues": len(problems)},
        "issues": problems[:MAX_ISSUES],
    }


def atomic_json(path: Path, report: dict[str, Any], replace: Callable[..., None] = os.replace) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary: Path | None = None
    try:
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=path.parent, delete=False) as stream:
            temporary = Path(stream.name)
            json.dump(report, stream, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        replace(temporary, path)
        temporary = None
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    report = validate(args.root.resolve())
    if args.output:
        output = args.output if args.output.is_absolute() else args.root / args.output
        atomic_json(output, report)
    if args.json:
        print(json.dumps(report, sort_keys=True))
    else:
        print(f"P1-013 {report['status']}: {report['counts']['files']} files, "
              f"{report['counts']['links']} links, {report['counts']['issues']} issues")
        for item in report["issues"][:20]:
            print(f"{item['code']} {item['path']}: {item['detail']}")
    return 0 if report["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
