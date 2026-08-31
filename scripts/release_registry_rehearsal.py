#!/usr/bin/env python3
"""Create and exercise isolated registry-style release artifacts.

cjpm 1.1.3 has no local-registry or publish dry-run command. Leaf packages are
bundled with cjpm itself. Packages whose exact release dependencies are not yet in
the central repository are archived in the same source layout, then extracted
and resolved to sibling artifact directories only for the release consumer rehearsal.
The original artifact manifests remain central-version-only.
"""

import argparse
import copy
import gzip
import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tarfile
import tempfile
import re
from urllib.parse import unquote, urlsplit

sys.dont_write_bytecode = True

from release_graph import load_release_graph, local_dependency_replacements
from release_temp_tree import (
    PROVENANCE,
    file_digest,
    manifest_paths,
    payload_digest,
    validate_manifest_closure,
)


ROOT = pathlib.Path(__file__).resolve().parents[1]
SUPPORTED_COMPILE_OVERRIDES = ("-O0", "-O1")
REPOSITORY_URL = "https://github.com/lIlIIlIll/yjson"
MARKDOWN_LINK_PATTERN = re.compile(r"(?<!!)\[([^\]]+)\]\(([^)]+)\)")


def run(command: list[str], cwd: pathlib.Path, env: dict[str, str]) -> None:
    result = subprocess.run(
        command, cwd=cwd, env=env, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    )
    if result.returncode != 0:
        print(result.stdout[-16000:], file=sys.stderr)
        raise subprocess.CalledProcessError(result.returncode, command)


def deterministic_tar(output: pathlib.Path, entries) -> None:
    with output.open("wb") as raw:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode="w", format=tarfile.PAX_FORMAT) as archive:
                for info, stream in entries:
                    info.uid = info.gid = 0
                    info.uname = info.gname = ""
                    info.mtime = 0
                    info.pax_headers = {}
                    archive.addfile(info, stream)


def deterministic_archive(module: pathlib.Path, output: pathlib.Path, version: str) -> None:
    prefix = f"{module.name}-{version}"
    entries = []
    streams = []
    try:
        for source in sorted(module.rglob("*")):
            relative = source.relative_to(module)
            if any(part in ("target", "build-script-cache") for part in relative.parts):
                continue
            if not source.is_file():
                continue
            metadata = source.stat()
            info = tarfile.TarInfo(f"{prefix}/{relative.as_posix()}")
            info.size = metadata.st_size
            info.mode = metadata.st_mode & 0o777
            info.type = tarfile.REGTYPE
            stream = source.open("rb")
            streams.append(stream)
            entries.append((info, stream))
        deterministic_tar(output, entries)
    finally:
        for stream in streams:
            stream.close()


def bundle_output_path(module: pathlib.Path, version: str) -> pathlib.Path:
    return module / "target" / f"{module.name}-{version}.cjp"


def module_source_digest(module: pathlib.Path) -> str:
    digest = hashlib.sha256()
    for source in sorted(module.rglob("*")):
        relative = source.relative_to(module)
        if any(part in ("target", "build-script-cache") for part in relative.parts):
            continue
        if source.is_symlink():
            raise RuntimeError(f"package source contains symlink: {relative.as_posix()}")
        if not source.is_file():
            continue
        digest.update(relative.as_posix().encode("utf-8"))
        digest.update(b"\0")
        digest.update(f"{source.stat().st_mode & 0o777:o}".encode("ascii"))
        digest.update(b"\0")
        digest.update(bytes.fromhex(file_digest(source)))
        digest.update(b"\0")
    return digest.hexdigest()


def ensure_module_unchanged(module: pathlib.Path, before: str) -> None:
    if module_source_digest(module) != before:
        raise RuntimeError(f"package source changed while building artifact: {module.name}")


def normalize_archive(source: pathlib.Path, output: pathlib.Path) -> None:
    entries = []
    streams = []
    with tarfile.open(source, "r:gz") as archive:
        try:
            for member in sorted(archive.getmembers(), key=lambda item: item.name):
                if not member.isfile():
                    continue
                path = pathlib.PurePosixPath(member.name)
                if path.is_absolute() or ".." in path.parts:
                    raise RuntimeError(f"unsafe archive member: {member.name}")
                stream = archive.extractfile(member)
                if stream is None:
                    raise RuntimeError(f"cannot read archive member: {member.name}")
                streams.append(stream)
                entries.append((copy.copy(member), stream))
            deterministic_tar(output, entries)
        finally:
            for stream in streams:
                stream.close()


def bundle_leaf(
    module: pathlib.Path,
    output: pathlib.Path,
    env: dict[str, str],
    compile_override: str,
    version: str,
) -> None:
    manifest = module / "cjpm.toml"
    original_manifest = manifest.read_text(encoding="utf-8")
    lock = module / "cjpm.lock"
    original_lock = lock.read_bytes() if lock.is_file() else None
    original_lock_mode = lock.stat().st_mode & 0o777 if lock.is_file() else None
    use_override = bool(compile_override and module.name == "yjson")
    if use_override:
        marker = 'compile-option = "-O2"'
        if original_manifest.count(marker) != 1:
            raise RuntimeError(f"unexpected cjpm manifest: {manifest}")
        manifest.write_text(
            original_manifest.replace(
                marker,
                f'compile-option = "{compile_override}"',
            ),
            encoding="utf-8",
        )
    try:
        run(["cjpm", "bundle", "--skip-test", "--skip-lint"], module, env)
    finally:
        if use_override:
            manifest.write_text(original_manifest, encoding="utf-8")
        if original_lock is None:
            if lock.exists():
                lock.unlink()
        elif not lock.is_file() or lock.read_bytes() != original_lock:
            lock.write_bytes(original_lock)
            if original_lock_mode is not None:
                lock.chmod(original_lock_mode)

    if use_override:
        # The override is a hosted-compiler workaround, not release metadata.
        # Archive the restored staging tree so consumers still inspect the O2
        # release manifest. Build output is excluded by deterministic_archive.
        deterministic_archive(module, output, version)
    else:
        normalize_archive(bundle_output_path(module, version), output)


def reproduce_artifact(
    module: pathlib.Path,
    output: pathlib.Path,
    env: dict[str, str],
    compile_override: str,
    version: str,
    leaf_bundle: bool,
) -> None:
    if not leaf_bundle:
        deterministic_archive(module, output, version)
        return
    with tempfile.TemporaryDirectory(prefix="yjson-artifact-rebuild-") as temporary:
        pristine = pathlib.Path(temporary) / module.name
        shutil.copytree(
            module,
            pristine,
            ignore=shutil.ignore_patterns("target", "build-script-cache"),
        )
        bundle_leaf(pristine, output, env, compile_override, version)


def candidate_commit(candidate: pathlib.Path) -> str:
    provenance_path = candidate / PROVENANCE
    if not provenance_path.is_file():
        raise RuntimeError("registry artifacts require candidate provenance")
    provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
    commit = provenance.get("commit")
    if (not isinstance(commit, str) or
            re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", commit) is None):
        raise RuntimeError("registry artifacts require an exact candidate commit")
    return commit


def rewrite_readme_links(
    text: str,
    source: pathlib.Path,
    module: pathlib.Path,
    candidate: pathlib.Path,
    commit: str,
) -> str:
    def replace(match: re.Match[str]) -> str:
        label, raw_target = match.groups()
        target = raw_target.strip().strip("<>")
        parsed = urlsplit(target)
        if parsed.scheme or parsed.netloc or not parsed.path:
            return match.group(0)
        decoded = unquote(parsed.path)
        local_target = (module / decoded).resolve()
        try:
            local_target.relative_to(module.resolve())
            local_in_module = local_target.exists()
        except ValueError:
            local_in_module = False
        if local_in_module:
            return match.group(0)
        repository_target = (source.parent / decoded).resolve()
        try:
            relative = repository_target.relative_to(candidate.resolve())
        except ValueError as error:
            raise RuntimeError(f"README link escapes candidate: {raw_target}") from error
        if not repository_target.exists():
            raise RuntimeError(f"README link target is missing: {relative.as_posix()}")
        kind = "tree" if repository_target.is_dir() else "blob"
        remote = f"{REPOSITORY_URL}/{kind}/{commit}/{relative.as_posix()}"
        if parsed.fragment:
            remote += f"#{parsed.fragment}"
        return f"[{label}]({remote})"

    return MARKDOWN_LINK_PATTERN.sub(replace, text)


def rewrite_staged_readmes(staged: pathlib.Path, graph, commit: str) -> None:
    for package in graph.packages:
        module = staged / package.name
        readme = module / "README.md"
        if not readme.is_file():
            continue
        source = ROOT / package.source_root.parent / "README.md"
        readme.write_text(
            rewrite_readme_links(
                readme.read_text(encoding="utf-8"),
                source,
                module,
                ROOT,
                commit,
            ),
            encoding="utf-8",
        )


def inspect_readme_links(
    archive_path: pathlib.Path,
    prefix: str,
    members: list[str],
    archive: tarfile.TarFile,
) -> None:
    readme_name = f"{prefix}/README.md"
    if readme_name not in members:
        return
    readme = archive.extractfile(readme_name)
    if readme is None:
        raise RuntimeError(f"cannot read README in {archive_path}")
    text = readme.read().decode("utf-8")
    member_set = set(members)
    for _, raw_target in MARKDOWN_LINK_PATTERN.findall(text):
        target = raw_target.strip().strip("<>")
        parsed = urlsplit(target)
        if parsed.scheme or parsed.netloc or not parsed.path:
            continue
        resolved = pathlib.PurePosixPath(prefix) / unquote(parsed.path)
        normalized = pathlib.PurePosixPath(*resolved.parts)
        if ".." in normalized.parts:
            raise RuntimeError(f"artifact README link escapes package: {raw_target}")
        value = normalized.as_posix()
        if value not in member_set and not any(item.startswith(value + "/") for item in members):
            raise RuntimeError(f"artifact README link is broken: {raw_target}")


def inspect_artifact(name: str, archive_path: pathlib.Path, version: str) -> None:
    with tarfile.open(archive_path, "r:gz") as archive:
        members = [member.name for member in archive.getmembers() if member.isfile()]
        prefix = f"{name}-{version}"
        manifest_name = f"{prefix}/cjpm.toml"
        manifest = archive.extractfile(manifest_name)
        if manifest is None:
            raise RuntimeError(f"missing manifest in {archive_path}")
        text = manifest.read().decode("utf-8")
        if "path =" in text or "../" in text:
            raise RuntimeError(f"release artifact contains path dependency: {name}")
        inspect_readme_links(archive_path, prefix, members, archive)
        forbidden = ("/target/", ".o", ".a", ".so")
        if any(any(token in member for token in forbidden) for member in members):
            raise RuntimeError(f"release artifact contains build output: {name}")
        if name == "yjson" and any("/native/" in member or "yyjson" in member for member in members):
            raise RuntimeError("core artifact contains native or yyjson input")
        if name == "yjson_native_primitives":
            required = ("native/yjson_scanner.c", "native/yjson_compact.c",
                        "scripts/build_native_scanner.py", "build.cj")
            if not all(any(member.endswith(item) for member in members) for item in required):
                raise RuntimeError("Native primitives artifact is incomplete")
        if name == "yjson_native":
            required = ("src/native_compact.cj", "src/document_backend.cj",
                        "src/stream_backend.cj", "README.md")
            if not all(any(member.endswith(item) for member in members) for item in required):
                raise RuntimeError("Custom Native backend artifact is incomplete")
        if name == "yjson_native_accel":
            required = ("src/native_accel.cj", "README.md")
            if not all(any(member.endswith(item) for member in members) for item in required):
                raise RuntimeError("Native acceleration artifact is incomplete")
        if name == "yjson_backends":
            if not any(member.endswith("src/backends.cj") for member in members):
                raise RuntimeError("Advanced backends artifact is incomplete")
        if name == "yjson_algorithms":
            required = ("src/work_limits.cj", "src/lib_json_schema.cj",
                        "src/lib_json_path.cj", "src/lib_json_patch.cj")
            if not all(any(member.endswith(item) for member in members) for item in required):
                raise RuntimeError("Algorithms artifact is incomplete")
        if name == "yjson_schema_formats":
            required = ("native/schema_formats.c", "build.cj")
            if not all(any(member.endswith(item) for member in members) for item in required):
                raise RuntimeError("Schema formats artifact is incomplete")
        if name == "yjson_yyjson":
            required = ("native/yjson_yyjson.c", "native/vendor/yyjson/yyjson.c",
                        "native/vendor/yyjson/yyjson.h", "native/vendor/yyjson/LICENSE",
                        "THIRD_PARTY_NOTICES.md", "scripts/build_native_scanner.py", "build.cj")
            if not all(any(member.endswith(item) for member in members) for item in required):
                raise RuntimeError("yyjson artifact is incomplete")


def rewrite_for_local_resolution(modules: pathlib.Path, graph) -> None:
    replacements = local_dependency_replacements(graph)
    for module in modules.iterdir():
        manifest = module / "cjpm.toml"
        text = manifest.read_text(encoding="utf-8")
        for release_value, local_value in replacements.items():
            text = text.replace(release_value, local_value)
        manifest.write_text(text, encoding="utf-8")


def validate_candidate_tree(candidate: pathlib.Path, require_clean: bool = False) -> None:
    candidate = candidate.resolve()
    if (candidate / ".git").exists():
        raise RuntimeError(f"release rehearsal refuses a Git checkout: {candidate}")
    manifest = candidate / "release" / "release-files.txt"
    if not manifest.is_file():
        raise RuntimeError(f"candidate release manifest is missing: {manifest}")
    paths = manifest_paths(manifest)
    missing = [path for path in paths if not (candidate / path).is_file()]
    if missing:
        raise RuntimeError(
            "candidate tree is incomplete:\n  "
            + "\n  ".join(path.as_posix() for path in missing)
        )
    expected = set(paths)
    provenance_path = candidate / PROVENANCE
    if provenance_path.is_file():
        expected.add(PROVENANCE)
    actual: set[pathlib.Path] = set()
    symlinks: list[pathlib.Path] = []
    for path in candidate.rglob("*"):
        relative = path.relative_to(candidate)
        if path.is_symlink():
            symlinks.append(relative)
        elif path.is_file():
            actual.add(relative)
    extras = sorted(actual - expected)
    if extras or symlinks:
        details = [f"unexpected candidate file: {path.as_posix()}" for path in extras]
        details += [f"candidate symlink is forbidden: {path.as_posix()}" for path in symlinks]
        raise RuntimeError("candidate file inventory differs from release manifest:\n  "
                           + "\n  ".join(details))
    try:
        from stage_source_tree import assert_source_only
        assert_source_only(candidate)
    except ValueError as error:
        raise RuntimeError(str(error)) from error
    validate_manifest_closure(candidate, paths)
    if not provenance_path.is_file():
        if require_clean:
            raise RuntimeError("candidate clean provenance is missing")
        return
    provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
    if provenance.get("schema_version") != 1:
        raise RuntimeError("candidate provenance schema is unsupported")
    expected = {
        "manifest_sha256": file_digest(manifest),
        "payload_sha256": payload_digest(candidate, paths),
        "file_count": len(paths),
    }
    for field, value in expected.items():
        if provenance.get(field) != value:
            raise RuntimeError(f"candidate provenance mismatch: {field}")
    if require_clean:
        if provenance.get("clean_enforced") is not True:
            raise RuntimeError("candidate provenance is not clean-enforced")
        for field in ("commit", "tree"):
            value = provenance.get(field)
            if (not isinstance(value, str) or
                    re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", value) is None):
                raise RuntimeError(f"candidate provenance has invalid {field}")


def delegate_to_candidate(
    candidate: pathlib.Path,
    destination: pathlib.Path,
    forwarded: list[str],
    require_clean: bool = False,
) -> int:
    candidate = candidate.resolve()
    destination = destination.resolve()
    validate_candidate_tree(candidate, require_clean=require_clean)
    try:
        destination.relative_to(candidate)
    except ValueError:
        pass
    else:
        raise RuntimeError("registry rehearsal destination must be outside the candidate tree")
    runner = candidate / "scripts" / "release_registry_rehearsal.py"
    command = [
        sys.executable,
        str(runner),
        str(destination),
        "--candidate-root",
        str(candidate),
        "--candidate-execution",
        *forwarded,
    ]
    return subprocess.run(command, cwd=candidate).returncode


def rehearse(args: argparse.Namespace) -> int:
    graph = load_release_graph()
    version = graph.version
    modules = graph.names
    leaf_bundles = tuple(
        package.name for package in graph.packages if package.leaf_bundle)
    destination = args.destination.resolve()
    if destination.exists() and any(destination.iterdir()):
        raise SystemExit(f"destination is not empty: {destination}")
    staged = destination / "staged"
    artifacts = destination / "artifacts"
    resolved = destination / "resolved"
    artifacts.mkdir(parents=True)
    env = os.environ.copy()
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    # CJPM_CONFIG is deprecated in cjpm 1.1.3. All rehearsal dependencies are
    # resolved from the staged sibling modules, so the central-repository cache
    # does not participate in this check.
    env.pop("CJPM_CONFIG", None)

    run([sys.executable, str(ROOT / "scripts/release_package_stage.py"), str(staged)], ROOT, env)
    rewrite_staged_readmes(staged, graph, candidate_commit(ROOT))
    for name in modules:
        module = staged / name
        source_before = module_source_digest(module)
        pristine_root = pathlib.Path(tempfile.mkdtemp(prefix=f"yjson-{name}-source-"))
        pristine = pristine_root / name
        shutil.copytree(
            module,
            pristine,
            ignore=shutil.ignore_patterns("target", "build-script-cache"),
        )
        manifest = (staged / name / "cjpm.toml").read_text(encoding="utf-8")
        if "path =" in manifest or "../" in manifest:
            raise RuntimeError(f"staged release manifest contains path dependency: {name}")

        output = artifacts / f"{name}-{version}.cjp"
        if name in leaf_bundles:
            bundle_leaf(
                module,
                output,
                env,
                args.bundle_override_compile_option,
                version,
            )
        else:
            deterministic_archive(module, output, version)
        ensure_module_unchanged(module, source_before)
        inspect_artifact(name, output, version)
        verification = artifacts / f".{name}-{version}.verify.cjp"
        try:
            reproduce_artifact(
                pristine,
                verification,
                env,
                args.bundle_override_compile_option,
                version,
                name in leaf_bundles,
            )
            ensure_module_unchanged(pristine, source_before)
            if output.read_bytes() != verification.read_bytes():
                raise RuntimeError(f"release artifact is not byte-deterministic: {name}")
        finally:
            if verification.exists():
                verification.unlink()
            shutil.rmtree(pristine_root)

        with tarfile.open(output, "r:gz") as archive:
            archive.extractall(destination / "unpacked", filter="data")
        shutil.copytree(destination / "unpacked" / f"{name}-{version}", resolved / name)

    rewrite_for_local_resolution(resolved, graph)
    if not args.skip_consumers:
        command = [sys.executable, str(ROOT / "scripts/release_consumer_checks.py"),
                   "--modules-root", str(resolved)]
        if args.consumer_override_compile_option:
            command.append(
                f"--override-compile-option={args.consumer_override_compile_option}")
        run(command, ROOT, env)
    validate_candidate_tree(
        ROOT,
        require_clean=args.require_clean_candidate,
    )
    print(f"registry-style rehearsal passed modules={len(modules)} destination={destination}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("destination", type=pathlib.Path)
    parser.add_argument("--skip-consumers", action="store_true")
    parser.add_argument("--consumer-override-compile-option", default="")
    parser.add_argument("--bundle-override-compile-option", default="")
    parser.add_argument("--candidate-root", type=pathlib.Path)
    parser.add_argument("--require-clean-candidate", action="store_true")
    parser.add_argument("--candidate-execution", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    for override in (
        args.consumer_override_compile_option,
        args.bundle_override_compile_option,
    ):
        if override and override not in SUPPORTED_COMPILE_OVERRIDES:
            raise SystemExit(f"unsupported dependency override: {override}")

    if not args.candidate_execution:
        candidate = args.candidate_root or (
            args.destination.resolve().parent / "release-candidate")
        forwarded: list[str] = []
        if args.skip_consumers:
            forwarded.append("--skip-consumers")
        if args.consumer_override_compile_option:
            forwarded.append(
                f"--consumer-override-compile-option={args.consumer_override_compile_option}")
        if args.bundle_override_compile_option:
            forwarded.append(
                f"--bundle-override-compile-option={args.bundle_override_compile_option}")
        if args.require_clean_candidate:
            forwarded.append("--require-clean-candidate")
        return delegate_to_candidate(
            candidate,
            args.destination,
            forwarded,
            require_clean=args.require_clean_candidate,
        )

    if args.candidate_root is None or args.candidate_root.resolve() != ROOT.resolve():
        raise SystemExit("candidate execution root does not match the executing script tree")
    validate_candidate_tree(ROOT, require_clean=args.require_clean_candidate)
    return rehearse(args)


if __name__ == "__main__":
    raise SystemExit(main())
