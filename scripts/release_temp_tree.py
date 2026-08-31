#!/usr/bin/env python3
"""Create a source-only release candidate tree from the checked manifest."""

import argparse
import ast
import hashlib
import json
import pathlib
import re
import shutil
import subprocess
import sys
from urllib.parse import unquote, urlsplit

sys.dont_write_bytecode = True

from stage_source_tree import assert_source_only


ROOT = pathlib.Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "release" / "release-files.txt"
PROVENANCE = pathlib.Path("release/candidate-provenance.json")


SCRIPT_PATH_COMPONENT = r"[A-Za-z0-9_-](?:[A-Za-z0-9_.-]*[A-Za-z0-9_-])?"
SCRIPT_PATH_PATTERN = re.compile(
    rf"scripts/{SCRIPT_PATH_COMPONENT}(?:/{SCRIPT_PATH_COMPONENT})*"
)
MARKDOWN_LINK_PATTERN = re.compile(r"!?\[[^\]]+\]\(([^)]+)\)")
MARKDOWN_REFERENCE_PATTERN = re.compile(r"^\s*\[[^\]]+\]:\s*(\S+)", re.MULTILINE)
HTML_LINK_PATTERN = re.compile(
    r"\b(?:href|src)\s*=\s*[\"']([^\"']+)[\"']",
    re.IGNORECASE,
)


def manifest_paths(manifest: pathlib.Path = MANIFEST) -> list[pathlib.Path]:
    paths: list[pathlib.Path] = []
    for line in manifest.read_text(encoding="utf-8").splitlines():
        value = line.strip()
        if not value or value.startswith("#"):
            continue
        path = pathlib.PurePosixPath(value)
        if path.is_absolute() or ".." in path.parts:
            raise ValueError(f"unsafe release manifest path: {value}")
        paths.append(pathlib.Path(*path.parts))
    if len(paths) != len(set(paths)):
        raise ValueError("release manifest contains duplicate paths")
    return paths


def file_digest(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def payload_digest(root: pathlib.Path, paths: list[pathlib.Path]) -> str:
    digest = hashlib.sha256()
    for relative in sorted(paths):
        source = root / relative
        if not source.is_file():
            raise ValueError(f"release manifest contains missing file: {relative.as_posix()}")
        digest.update(relative.as_posix().encode("utf-8"))
        digest.update(b"\0")
        digest.update(f"{source.stat().st_mode & 0o777:o}".encode("ascii"))
        digest.update(b"\0")
        digest.update(bytes.fromhex(file_digest(source)))
        digest.update(b"\0")
    return digest.hexdigest()


def git_output(root: pathlib.Path, arguments: list[str]) -> str:
    result = subprocess.run(
        ["git", "-C", str(root), *arguments],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.returncode != 0:
        message = result.stderr.strip() or result.stdout.strip()
        raise ValueError(f"cannot establish release Git identity: {message}")
    return result.stdout.strip()


def release_identity(
    root: pathlib.Path,
    paths: list[pathlib.Path],
    enforce_clean: bool,
) -> dict[str, object]:
    identity: dict[str, object] = {
        "manifest_sha256": file_digest(root / "release" / "release-files.txt"),
        "payload_sha256": payload_digest(root, paths),
        "file_count": len(paths),
        "clean_enforced": enforce_clean,
    }
    if not enforce_clean:
        return identity

    repository_root = pathlib.Path(
        git_output(root, ["rev-parse", "--show-toplevel"])).resolve()
    if repository_root != root.resolve():
        raise ValueError(f"release root is not the Git worktree root: {root}")
    tracked = set(filter(None, git_output(root, ["ls-files"]).splitlines()))
    untracked = sorted(path.as_posix() for path in paths if path.as_posix() not in tracked)
    if untracked:
        raise ValueError(
            "release manifest contains paths not tracked by Git:\n  "
            + "\n  ".join(untracked)
        )
    status = git_output(root, ["status", "--porcelain=v1", "--untracked-files=all"])
    if status:
        raise ValueError("formal release candidate requires a clean Git worktree")
    identity["commit"] = git_output(root, ["rev-parse", "HEAD"])
    identity["tree"] = git_output(root, ["rev-parse", "HEAD^{tree}"])
    return identity


def write_provenance(destination: pathlib.Path, identity: dict[str, object]) -> None:
    target = destination / PROVENANCE
    target.parent.mkdir(parents=True, exist_ok=True)
    document = {"schema_version": 1, **identity}
    target.write_text(
        json.dumps(document, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def ensure_identity_unchanged(
    before: dict[str, object],
    after: dict[str, object],
) -> None:
    if before != after:
        raise ValueError("release source identity changed while staging candidate")


def script_dependencies(root: pathlib.Path, relative: pathlib.Path) -> set[pathlib.Path]:
    source = root / relative
    if not source.is_file():
        return set()
    text = source.read_text(encoding="utf-8")
    dependencies = {pathlib.Path(match) for match in SCRIPT_PATH_PATTERN.findall(text)}
    if relative.suffix != ".py":
        return dependencies
    try:
        tree = ast.parse(text, filename=relative.as_posix())
    except SyntaxError:
        return dependencies

    def add_module(module: str) -> None:
        name = module.split('.')[0]
        candidates = (
            source.parent / f"{name}.py",
            root / "scripts" / f"{name}.py",
        )
        for candidate in candidates:
            if candidate.is_file():
                dependencies.add(candidate.relative_to(root))
                return

    for node in ast.walk(tree):
        if isinstance(node, ast.ImportFrom) and node.level == 0:
            if node.module:
                add_module(node.module)
        elif isinstance(node, ast.Import):
            for alias in node.names:
                add_module(alias.name)
    return dependencies


def referenced_scripts(root: pathlib.Path, relative: pathlib.Path) -> set[pathlib.Path]:
    source = root / relative
    if not source.is_file():
        return set()
    try:
        text = source.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        return set()
    return {
        pathlib.Path(match.rstrip(".,;:"))
        for match in SCRIPT_PATH_PATTERN.findall(text)
    }


def markdown_dependencies(
    root: pathlib.Path,
    relative: pathlib.Path,
) -> tuple[set[pathlib.Path], list[str]]:
    if relative.suffix.lower() != ".md":
        return set(), []
    source = root / relative
    if not source.is_file():
        return set(), []
    text = source.read_text(encoding="utf-8")
    dependencies: set[pathlib.Path] = set()
    invalid: list[str] = []
    raw_targets = MARKDOWN_LINK_PATTERN.findall(text)
    raw_targets += MARKDOWN_REFERENCE_PATTERN.findall(text)
    raw_targets += HTML_LINK_PATTERN.findall(text)
    for raw_target in raw_targets:
        target = raw_target.strip().strip("<>")
        parsed = urlsplit(target)
        if parsed.scheme or parsed.netloc or not parsed.path:
            continue
        decoded = unquote(parsed.path)
        if decoded.startswith("/"):
            invalid.append(f"{relative.as_posix()}: {raw_target}")
            continue
        resolved = (source.parent / decoded).resolve()
        try:
            dependency = resolved.relative_to(root.resolve())
        except ValueError:
            invalid.append(f"{relative.as_posix()}: {raw_target}")
            continue
        dependencies.add(dependency)
    return dependencies, invalid


def validate_manifest_closure(root: pathlib.Path, paths: list[pathlib.Path]) -> None:
    included = set(paths)
    project_roots = {pathlib.Path()}
    project_roots.update(
        path.parent for path in included
        if path.name == "cjpm.toml" and path.parent != pathlib.Path()
    )
    discovered_sources: set[pathlib.Path] = set()
    for project_root in project_roots:
        source_root = root / project_root / "src"
        if source_root.is_dir():
            discovered_sources.update(
            path.relative_to(root) for path in source_root.rglob("*.cj")
            if path.is_file()
            )
        for metadata_name in ("cjpm.lock", "build.cj"):
            metadata = root / project_root / metadata_name
            if metadata.is_file():
                discovered_sources.add(metadata.relative_to(root))
    missing_sources = sorted(discovered_sources - included)

    missing_scripts: set[pathlib.Path] = set()
    missing_links: set[pathlib.Path] = set()
    broken_links: list[str] = []
    for relative in sorted(included):
        dependencies = referenced_scripts(root, relative)
        if relative.suffix in (".py", ".sh"):
            dependencies.update(script_dependencies(root, relative))
        for dependency in dependencies:
            if (root / dependency).is_file() and dependency not in included:
                missing_scripts.add(dependency)

        link_dependencies, invalid_links = markdown_dependencies(root, relative)
        broken_links.extend(invalid_links)
        for dependency in link_dependencies:
            target = root / dependency
            if not target.exists():
                broken_links.append(f"{relative.as_posix()}: {dependency.as_posix()}")
            elif target.is_file() and dependency not in included:
                missing_links.add(dependency)
            elif target.is_dir() and not any(
                dependency == path or dependency in path.parents for path in included
            ):
                missing_links.add(dependency)

    if missing_sources or missing_scripts or missing_links or broken_links:
        details = [
            f"package source not in manifest: {path.as_posix()}"
            for path in missing_sources
        ]
        details += [f"script dependency not in manifest: {path.as_posix()}" for path in sorted(missing_scripts)]
        details += [f"Markdown link target not in manifest: {path.as_posix()}" for path in sorted(missing_links)]
        details += [f"invalid or broken Markdown link: {link}" for link in sorted(broken_links)]
        raise ValueError("release manifest is not dependency-closed:\n  " + "\n  ".join(details))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("destination", type=pathlib.Path)
    parser.add_argument("--enforce-clean", action="store_true")
    args = parser.parse_args()
    destination = args.destination.resolve()
    if destination == ROOT.resolve() or ROOT.resolve() in destination.parents:
        raise SystemExit("destination must be outside the release source tree")
    if destination.exists() and any(destination.iterdir()):
        raise SystemExit(f"destination is not empty: {destination}")
    destination.mkdir(parents=True, exist_ok=True)

    paths = manifest_paths()
    try:
        validate_manifest_closure(ROOT, paths)
        before = release_identity(ROOT, paths, args.enforce_clean)
    except ValueError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    missing: list[str] = []
    copied = 0
    for relative in paths:
        source = ROOT / relative
        if not source.is_file():
            missing.append(relative.as_posix())
            continue
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
        copied += 1
    if missing:
        print("release manifest contains missing files:", file=sys.stderr)
        for path in missing:
            print(f"  {path}", file=sys.stderr)
        return 1

    try:
        after = release_identity(ROOT, paths, args.enforce_clean)
        ensure_identity_unchanged(before, after)
        if payload_digest(destination, paths) != before["payload_sha256"]:
            raise ValueError("staged candidate payload does not match release source identity")
        write_provenance(destination, before)
    except ValueError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    try:
        assert_source_only(destination)
    except ValueError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    print(f"release tree copied files={copied} destination={destination}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
