#!/usr/bin/env python3
"""Generate and validate cjdoc API documentation for every release package."""

from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import html
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import tomllib

from check_cjdoc_qualification import validate_qualification
from release_graph import ROOT, load_release_graph


DEFAULT_CONFIG = ROOT / "release" / "cjdoc-tool.toml"
DEFAULT_POLICY = ROOT / "release" / "cjdoc-policy.toml"
DEFAULT_OUTPUT = ROOT / "target" / "api-docs"
PUBLIC_API_SNAPSHOT = ROOT / "release" / "public-api-snapshot.txt"
PUBLIC_MACRO = re.compile(r"\|public macro ([A-Za-z_][A-Za-z0-9_]*)\(")


class ApiDocsError(ValueError):
    pass


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def validate_doc_ir(
    docs_path: pathlib.Path,
    *,
    package_name: str,
    generator_version: str,
    expected_unsupported: Counter[tuple[str, str]],
) -> dict[str, object]:
    try:
        document = json.loads(docs_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ApiDocsError(f"{package_name}: unreadable docs.json: {error}") from error
    if not isinstance(document, dict):
        raise ApiDocsError(f"{package_name}: docs.json root must be an object")
    if document.get("schemaVersion") != "cjdoc.doc-ir/7":
        raise ApiDocsError(f"{package_name}: cjdoc must emit Doc IR v7")
    generator = document.get("generator")
    if not isinstance(generator, dict) or generator.get("name") != "cjdoc":
        raise ApiDocsError(f"{package_name}: docs.json has an unexpected generator")
    if generator.get("version") != generator_version:
        raise ApiDocsError(f"{package_name}: docs.json generator version mismatch")
    project = document.get("project")
    if not isinstance(project, dict) or project.get("name") != package_name:
        raise ApiDocsError(f"{package_name}: docs.json project name mismatch")
    configuration = document.get("configuration")
    if not isinstance(configuration, dict) or configuration.get("audience") != "external":
        raise ApiDocsError(f"{package_name}: docs.json audience must be external")
    packages = document.get("packages")
    if not isinstance(packages, list):
        raise ApiDocsError(f"{package_name}: docs.json packages must be an array")
    documented_names = [
        entry.get("name") for entry in packages if isinstance(entry, dict)
    ]
    if documented_names != [package_name]:
        raise ApiDocsError(
            f"{package_name}: docs.json must contain exactly its release package"
        )
    declarations = document.get("declarations")
    if not isinstance(declarations, list):
        raise ApiDocsError(f"{package_name}: docs.json declarations must be an array")
    diagnostics = document.get("diagnostics")
    if not isinstance(diagnostics, list):
        raise ApiDocsError(f"{package_name}: docs.json diagnostics must be an array")
    errors = [
        item for item in diagnostics
        if isinstance(item, dict) and item.get("severity") == "error"
    ]
    if errors:
        codes = ", ".join(str(item.get("code", "unknown")) for item in errors)
        raise ApiDocsError(f"{package_name}: cjdoc reported errors: {codes}")
    public_declarations = sum(
        1 for declaration in declarations
        if isinstance(declaration, dict) and declaration.get("visibility") == "public"
    )
    unsupported = document.get("unsupportedDeclarations")
    if not isinstance(unsupported, list):
        raise ApiDocsError(
            f"{package_name}: docs.json unsupportedDeclarations must be an array"
        )
    if not all(
        isinstance(item, dict)
        and isinstance(item.get("kind"), str)
        and isinstance(item.get("name"), str)
        for item in unsupported
    ):
        raise ApiDocsError(f"{package_name}: malformed unsupported declaration")
    actual_unsupported = Counter(
        (str(item["kind"]), str(item["name"])) for item in unsupported
    )
    if actual_unsupported != expected_unsupported:
        raise ApiDocsError(
            f"{package_name}: unsupported declaration inventory does not match "
            f"cjdoc policy (expected {dict(expected_unsupported)}, "
            f"got {dict(actual_unsupported)})"
        )
    unsupported_macros = sorted(
        name for (kind, name), count in actual_unsupported.items()
        if kind == "macro" for _ in range(count)
    )
    if public_declarations == 0 and not unsupported_macros:
        raise ApiDocsError(f"{package_name}: docs.json has no public API entries")
    warning_codes = sorted({
        str(item.get("code", "unknown"))
        for item in diagnostics
        if isinstance(item, dict) and item.get("severity") == "warning"
    })
    return {
        "status": str(document.get("status", "unknown")),
        "declarations": len(declarations),
        "publicDeclarations": public_declarations,
        "unsupportedPublicMacros": sorted(unsupported_macros),
        "unsupported": [
            {"kind": kind, "name": name, "count": count}
            for (kind, name), count in sorted(actual_unsupported.items())
        ],
        "warnings": len([
            item for item in diagnostics
            if isinstance(item, dict) and item.get("severity") == "warning"
        ]),
        "warningCodes": warning_codes,
    }


def write_portal_index(
    path: pathlib.Path,
    *,
    release_version: str,
    packages: list[dict[str, object]],
) -> None:
    links = "\n".join(
        "        <li><a href=\"{0}/html/index.html\"><code>{0}</code></a>"
        " <span>{1} cjdoc declarations{2}</span></li>".format(
            html.escape(str(package["name"]), quote=True),
            int(package["publicDeclarations"]),
            (
                "; " + str(len(package["unsupportedPublicMacros"]))
                + " unsupported public macros"
                if package["unsupportedPublicMacros"] else ""
            ),
        )
        for package in packages
    )
    page = f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>yjson {html.escape(release_version)} API documentation</title>
  <style>
    :root {{ color-scheme: light dark; font-family: system-ui, sans-serif; }}
    body {{ margin: 0 auto; max-width: 72rem; padding: 3rem 1.5rem; }}
    h1 {{ margin-bottom: .5rem; }}
    p {{ color: #666; }}
    ul {{ display: grid; gap: .75rem; padding: 0; list-style: none; }}
    li {{ border: 1px solid #8885; border-radius: .5rem; padding: 1rem; }}
    li span {{ float: right; color: #666; }}
  </style>
</head>
<body>
  <main>
    <h1>yjson {html.escape(release_version)} API documentation</h1>
    <p>Generated by the source-qualified cjdoc tool for the release package graph.</p>
    <ul>
{links}
    </ul>
  </main>
</body>
</html>
"""
    path.write_text(page, encoding="utf-8")


def generate(
    *,
    cjdoc_binary: pathlib.Path,
    output: pathlib.Path,
    config_path: pathlib.Path = DEFAULT_CONFIG,
    policy_path: pathlib.Path = DEFAULT_POLICY,
) -> pathlib.Path:
    binary, binary_sha = validate_qualification(
        config_path, binary_override=cjdoc_binary)
    config = tomllib.loads(config_path.read_text(encoding="utf-8"))
    generator_version = str(config["version"])
    source_revision = str(config["source_revision"])
    graph = load_release_graph()
    policy = tomllib.loads(policy_path.read_text(encoding="utf-8"))
    if policy.get("schema_version") != 1:
        raise ApiDocsError("unsupported cjdoc API documentation policy schema")
    if policy.get("doc_ir_schema") != "cjdoc.doc-ir/7":
        raise ApiDocsError("cjdoc policy must require Doc IR v7")
    if policy.get("audience") != "external":
        raise ApiDocsError("cjdoc policy must require the external audience")
    expected_unsupported: dict[str, Counter[tuple[str, str]]] = {
        package.name: Counter() for package in graph.packages
    }
    limitations = policy.get("allowed_unsupported", [])
    if not isinstance(limitations, list):
        raise ApiDocsError("cjdoc policy allowed_unsupported must be an array")
    for index, limitation in enumerate(limitations):
        if not isinstance(limitation, dict):
            raise ApiDocsError(f"cjdoc policy entry {index} must be a table")
        package_name = limitation.get("package")
        kind = limitation.get("kind")
        name = limitation.get("name")
        count = limitation.get("count")
        rationale = limitation.get("rationale")
        if package_name not in expected_unsupported:
            raise ApiDocsError(f"cjdoc policy entry {index} has an unknown package")
        if kind not in ("macro", "macroInvocation"):
            raise ApiDocsError(f"cjdoc policy entry {index} has an unsupported kind")
        if not isinstance(name, str) or not name:
            raise ApiDocsError(f"cjdoc policy entry {index} has no name")
        if not isinstance(count, int) or isinstance(count, bool) or count <= 0:
            raise ApiDocsError(f"cjdoc policy entry {index} has an invalid count")
        if not isinstance(rationale, str) or not rationale:
            raise ApiDocsError(f"cjdoc policy entry {index} has no rationale")
        key = (kind, name)
        if expected_unsupported[package_name][key] != 0:
            raise ApiDocsError(f"duplicate cjdoc policy entry: {package_name} {kind} {name}")
        expected_unsupported[package_name][key] = count
    macro_inventory: dict[str, set[str]] = {
        package.name: set() for package in graph.packages
    }
    for line in PUBLIC_API_SNAPSHOT.read_text(encoding="utf-8").splitlines():
        package_name = line.split("|", 1)[0]
        match = PUBLIC_MACRO.search(line)
        if package_name in macro_inventory and match is not None:
            macro_inventory[package_name].add(match.group(1))
    for package_name, macros in macro_inventory.items():
        policy_macros = {
            name for (kind, name) in expected_unsupported[package_name]
            if kind == "macro"
        }
        if policy_macros != macros:
            raise ApiDocsError(
                f"{package_name}: cjdoc macro policy does not match public API snapshot"
            )

    output = output.resolve()
    if output.exists() or output.is_symlink():
        raise ApiDocsError(f"API documentation output already exists: {output}")
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = pathlib.Path(
        tempfile.mkdtemp(prefix=f".{output.name}-", dir=output.parent)
    )
    staging = temporary / "site"
    staging.mkdir()
    reports: list[dict[str, object]] = []
    try:
        for package in graph.packages:
            project = (ROOT / package.development_manifest).parent
            package_output = staging / package.name
            command = [
                str(binary),
                "generate",
                "--project", str(project),
                "--format", "json",
                "--format", "html",
                "--output", str(package_output),
                "--audience", "external",
                "--lint-profile", "off",
                "--jobs", "1",
                "--no-cache",
            ]
            result = subprocess.run(
                command,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                timeout=300,
                check=False,
            )
            if result.returncode != 0:
                raise ApiDocsError(
                    f"{package.name}: cjdoc failed with exit {result.returncode}: "
                    f"{result.stdout.strip()}"
                )
            docs_path = package_output / "docs.json"
            html_path = package_output / "html" / "index.html"
            ownership_path = package_output / ".cjdoc-output.json"
            for required in (docs_path, html_path, ownership_path):
                if required.is_symlink() or not required.is_file():
                    raise ApiDocsError(
                        f"{package.name}: cjdoc did not produce {required.name}"
                    )
            report = validate_doc_ir(
                docs_path,
                package_name=package.name,
                generator_version=generator_version,
                expected_unsupported=expected_unsupported[package.name],
            )
            report.update({
                "name": package.name,
                "role": package.role,
                "stability": package.stability,
                "docIr": f"{package.name}/docs.json",
                "html": f"{package.name}/html/index.html",
                "docIrSha256": sha256_file(docs_path),
            })
            reports.append(report)
            print(
                f"cjdoc package={package.name} "
                f"public={report['publicDeclarations']} "
                f"unsupported_macros={len(report['unsupportedPublicMacros'])} "
                f"warnings={report['warnings']}"
            )

        manifest = {
            "schemaVersion": "yjson.api-docs/1",
            "releaseVersion": graph.version,
            "generator": {
                "name": "cjdoc",
                "version": generator_version,
                "sourceRevision": source_revision,
                "binarySha256": binary_sha,
            },
            "packages": reports,
        }
        (staging / "api-docs.json").write_text(
            json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        write_portal_index(
            staging / "index.html",
            release_version=graph.version,
            packages=reports,
        )
        os.replace(staging, output)
        return output
    finally:
        shutil.rmtree(temporary, ignore_errors=True)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cjdoc", type=pathlib.Path)
    parser.add_argument("--config", type=pathlib.Path, default=DEFAULT_CONFIG)
    parser.add_argument("--policy", type=pathlib.Path, default=DEFAULT_POLICY)
    parser.add_argument("--output", type=pathlib.Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()
    cjdoc = args.cjdoc
    if cjdoc is None:
        environment_binary = os.environ.get("YJSON_CJDOC_BINARY", "").strip()
        if environment_binary:
            cjdoc = pathlib.Path(environment_binary)
    if cjdoc is None:
        print(
            "API docs error: --cjdoc or YJSON_CJDOC_BINARY is required",
            file=sys.stderr,
        )
        return 1
    try:
        output = generate(
            cjdoc_binary=cjdoc.resolve(),
            output=args.output,
            config_path=args.config.resolve(),
            policy_path=args.policy.resolve(),
        )
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print(f"API docs error: {error}", file=sys.stderr)
        return 1
    print(f"API documentation generated: {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
