#!/usr/bin/env python3
"""Load and validate the single yjson release package graph."""

from __future__ import annotations

from dataclasses import dataclass
import pathlib
import re
import tomllib


ROOT = pathlib.Path(__file__).resolve().parents[1]
GRAPH_PATH = ROOT / "release" / "release-graph.toml"
SEMVER = re.compile(r"0\.[1-9][0-9]*\.[0-9]+")
PACKAGE_NAME = re.compile(r"yjson(?:_[a-z][a-z0-9_]*)?")


@dataclass(frozen=True)
class ReleasePackage:
    name: str
    role: str
    development_manifest: pathlib.Path
    release_manifest: pathlib.Path
    source_root: pathlib.Path
    stage_kind: str
    stability: str
    leaf_bundle: bool
    dependencies: tuple[str, ...]
    development_dependencies: tuple[str, ...]


@dataclass(frozen=True)
class ReleaseGraph:
    version: str
    status: str
    packages: tuple[ReleasePackage, ...]

    @property
    def names(self) -> tuple[str, ...]:
        return tuple(package.name for package in self.packages)

    def package(self, name: str) -> ReleasePackage:
        for package in self.packages:
            if package.name == name:
                return package
        raise KeyError(name)


def _relative_path(value: object, field: str) -> pathlib.Path:
    if not isinstance(value, str) or not value:
        raise ValueError(f"{field} must be a non-empty relative path")
    path = pathlib.PurePosixPath(value)
    if path.is_absolute() or ".." in path.parts:
        raise ValueError(f"{field} is unsafe: {value}")
    return pathlib.Path(*path.parts)


def load_release_graph(path: pathlib.Path = GRAPH_PATH) -> ReleaseGraph:
    data = tomllib.loads(path.read_text(encoding="utf-8"))
    if data.get("schema_version") != 1:
        raise ValueError("unsupported release graph schema_version")
    version = data.get("release_version")
    if not isinstance(version, str) or SEMVER.fullmatch(version) is None:
        raise ValueError("release_version must be a stable 0.x.y version")
    status = data.get("status")
    if status not in ("migration", "release-ready"):
        raise ValueError("release graph status must be migration or release-ready")

    packages: list[ReleasePackage] = []
    seen: set[str] = set()
    raw_packages = data.get("packages")
    if not isinstance(raw_packages, list) or not raw_packages:
        raise ValueError("release graph must contain packages")
    for index, raw in enumerate(raw_packages):
        if not isinstance(raw, dict):
            raise ValueError(f"packages[{index}] must be a table")
        name = raw.get("name")
        if not isinstance(name, str) or PACKAGE_NAME.fullmatch(name) is None:
            raise ValueError(f"packages[{index}].name is invalid")
        if name in seen:
            raise ValueError(f"duplicate release package: {name}")
        seen.add(name)
        dependencies = raw.get("dependencies")
        if not isinstance(dependencies, list) or not all(
            isinstance(item, str) for item in dependencies
        ):
            raise ValueError(f"{name}.dependencies must be an array of package names")
        if len(dependencies) != len(set(dependencies)) or name in dependencies:
            raise ValueError(f"{name}.dependencies contains a duplicate or self edge")
        development_dependencies = raw.get("development_dependencies", dependencies)
        if not isinstance(development_dependencies, list) or not all(
            isinstance(item, str) for item in development_dependencies
        ):
            raise ValueError(
                f"{name}.development_dependencies must be an array of package names")
        if (len(development_dependencies) != len(set(development_dependencies)) or
                name in development_dependencies):
            raise ValueError(
                f"{name}.development_dependencies contains a duplicate or self edge")
        role = raw.get("role")
        stage_kind = raw.get("stage_kind")
        stability = raw.get("stability")
        leaf_bundle = raw.get("leaf_bundle")
        if not all(isinstance(value, str) and value for value in (role, stage_kind, stability)):
            raise ValueError(f"{name} has incomplete role/stage/stability metadata")
        if not isinstance(leaf_bundle, bool):
            raise ValueError(f"{name}.leaf_bundle must be boolean")
        packages.append(ReleasePackage(
            name=name,
            role=role,
            development_manifest=_relative_path(
                raw.get("development_manifest"), f"{name}.development_manifest"),
            release_manifest=_relative_path(
                raw.get("release_manifest"), f"{name}.release_manifest"),
            source_root=_relative_path(raw.get("source_root"), f"{name}.source_root"),
            stage_kind=stage_kind,
            stability=stability,
            leaf_bundle=leaf_bundle,
            dependencies=tuple(dependencies),
            development_dependencies=tuple(development_dependencies),
        ))

    for package in packages:
        missing = sorted(
            (set(package.dependencies) | set(package.development_dependencies)) - seen)
        if missing:
            raise ValueError(f"{package.name} depends on unknown packages: {', '.join(missing)}")
    return ReleaseGraph(version=version, status=status, packages=tuple(packages))


def local_dependency_replacements(graph: ReleaseGraph) -> dict[str, str]:
    replacements: dict[str, str] = {}
    for package in graph.packages:
        for dependency in package.dependencies:
            release_value = f'{dependency} = "{graph.version}"'
            local_value = f'{dependency} = {{ path = "../{dependency}" }}'
            previous = replacements.setdefault(release_value, local_value)
            if previous != local_value:
                raise ValueError(f"conflicting local replacement for {dependency}")
    return replacements
