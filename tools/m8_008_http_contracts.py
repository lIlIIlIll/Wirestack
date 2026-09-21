#!/usr/bin/env python3
"""Build and qualify the M8-008 Linux HTTP consumer-contract closure."""

from __future__ import annotations

if __package__ in {None, ""}:
    import sys
    from pathlib import Path

    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import argparse
import datetime as dt
import filecmp
import json
import os
import re
import secrets
import shutil
import signal
import stat
import subprocess
import sys
import tomllib
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Mapping, Sequence

from tools import build_linux_tls_provider as tls_builder
from tools import evidence_digest
from tools import m7_021_linux_release as release
from tools import m7_027_linux_examples as examples


TASK_ID = "M8-008"
PROFILE = "linux-x86_64-glibc"
GENERATED_ROOT_NAMES = {".git", ".local", "build", "dist", "target"}
REPRODUCIBLE_ARTIFACTS = (
    "provider_archive",
    "resolver_archive",
    "release_archive",
)
MAX_COMMAND_SECONDS = 7_200


class PipelineError(RuntimeError):
    """Fail-closed M8-008 pipeline error with a stable category."""

    def __init__(self, code: str, detail: str) -> None:
        super().__init__(detail)
        self.code = code
        self.detail = detail


@dataclass(frozen=True)
class CommandSpec:
    name: str
    argv: tuple[str, ...]
    cwd: Path
    timeout: int = MAX_COMMAND_SECONDS


@dataclass(frozen=True)
class CommandResult:
    name: str
    argv: tuple[str, ...]
    cwd: Path
    returncode: int
    stdout: str
    stderr: str
    log: Path


class CommandRunner:
    """Execute commands sequentially and retain an untruncated log for each one."""

    def __init__(self, run_root: Path) -> None:
        self.run_root = run_root.resolve()
        self.log_root = confined_path(self.run_root, self.run_root / "logs")
        self.log_root.mkdir(parents=True, exist_ok=True)
        self.records: list[dict[str, Any]] = []
        self._sequence = 0

    def run(self, spec: CommandSpec, environment: Mapping[str, str]) -> CommandResult:
        self._sequence += 1
        slug = re.sub(r"[^a-zA-Z0-9_.-]+", "-", spec.name).strip("-") or "command"
        log_path = confined_path(
            self.run_root, self.log_root / f"{self._sequence:02d}-{slug}.log"
        )
        argv = tuple(str(value) for value in spec.argv)
        cwd = spec.cwd.resolve()
        try:
            process = subprocess.Popen(
                list(argv),
                cwd=cwd,
                env=dict(environment),
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                errors="replace",
                start_new_session=True,
            )
            stdout, stderr = process.communicate(timeout=spec.timeout)
            returncode = process.returncode
        except subprocess.TimeoutExpired as error:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            stdout, stderr = process.communicate()
            returncode = -1
            self._write_log(log_path, argv, cwd, returncode, stdout, stderr, spec.timeout)
            self._record(spec.name, argv, cwd, returncode, log_path)
            raise PipelineError(
                "COMMAND_TIMEOUT",
                f"{spec.name} exceeded {spec.timeout} seconds; log={log_path}",
            ) from error
        except OSError as error:
            stdout = ""
            stderr = str(error)
            returncode = -1
            self._write_log(log_path, argv, cwd, returncode, stdout, stderr, spec.timeout)
            self._record(spec.name, argv, cwd, returncode, log_path)
            raise PipelineError(
                "COMMAND_START_FAILED", f"cannot start {spec.name}: {error}; log={log_path}"
            ) from error
        self._write_log(log_path, argv, cwd, returncode, stdout, stderr, spec.timeout)
        self._record(spec.name, argv, cwd, returncode, log_path)
        if returncode != 0:
            raise PipelineError(
                "COMMAND_FAILED",
                f"{spec.name} exited {returncode}; log={log_path}",
            )
        return CommandResult(spec.name, argv, cwd, returncode, stdout, stderr, log_path)

    def run_chain(
        self, specs: Sequence[CommandSpec], environment: Mapping[str, str]
    ) -> list[CommandResult]:
        results: list[CommandResult] = []
        for spec in specs:
            results.append(self.run(spec, environment))
        return results

    def _record(
        self, name: str, argv: tuple[str, ...], cwd: Path, returncode: int, log: Path
    ) -> None:
        self.records.append(
            {
                "name": name,
                "argv": list(argv),
                "cwd": str(cwd),
                "returncode": returncode,
                "bytes": log.stat().st_size,
                "sha256": evidence_digest.text_evidence_sha256(log),
                "log": str(log),
            }
        )

    @staticmethod
    def _write_log(
        path: Path,
        argv: tuple[str, ...],
        cwd: Path,
        returncode: int,
        stdout: str,
        stderr: str,
        timeout: int,
    ) -> None:
        path.write_text(
            "argv=" + json.dumps(list(argv), ensure_ascii=False) + "\n"
            f"cwd={cwd}\n"
            f"timeout_seconds={timeout}\n"
            f"returncode={returncode}\n"
            "--- stdout ---\n"
            + stdout
            + ("" if stdout.endswith("\n") or not stdout else "\n")
            + "--- stderr ---\n"
            + stderr
            + ("" if stderr.endswith("\n") or not stderr else "\n"),
            encoding="utf-8",
        )


def canonical_json(value: Any) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def confined_path(root: Path, candidate: Path) -> Path:
    base = root.resolve()
    resolved = candidate.resolve(strict=False)
    if resolved != base and base not in resolved.parents:
        raise PipelineError("OUTPUT_ESCAPE", f"output escapes unique run root: {resolved}")
    return resolved


def create_run_root(repository: Path) -> Path:
    base = (repository.resolve() / "build" / "m8-008").resolve()
    base.mkdir(parents=True, exist_ok=True)
    timestamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
    for _ in range(16):
        candidate = base / f"{timestamp}-{os.getpid()}-{secrets.token_hex(4)}"
        try:
            candidate.mkdir()
            return candidate.resolve()
        except FileExistsError:
            continue
    raise PipelineError("RUN_ROOT_COLLISION", "cannot allocate a unique M8-008 run root")


def _excluded_snapshot_path(relative: Path) -> bool:
    return bool(relative.parts) and relative.parts[0] in GENERATED_ROOT_NAMES


def freeze_repository(
    repository: Path, destination: Path, runner: CommandRunner
) -> dict[str, Any]:
    repository = repository.resolve()
    destination = confined_path(runner.run_root, destination)
    if destination.exists():
        raise PipelineError("SNAPSHOT_EXISTS", f"snapshot destination already exists: {destination}")
    destination.mkdir(parents=True)
    inventory = runner.run(
        CommandSpec(
            "snapshot-file-inventory",
            (
                _required_executable("git", (), ("git",)),
                "-C",
                str(repository),
                "ls-files",
                "-z",
                "--cached",
                "--others",
                "--exclude-standard",
            ),
            repository,
            60,
        ),
        os.environ,
    )
    names = sorted({name for name in inventory.stdout.split("\0") if name})
    files: list[dict[str, Any]] = []
    deleted: list[str] = []
    for name in names:
        relative = Path(name)
        if relative.is_absolute() or ".." in relative.parts or relative.as_posix() != name:
            raise PipelineError("SNAPSHOT_PATH", f"invalid Git inventory path: {name!r}")
        if _excluded_snapshot_path(relative):
            continue
        source = repository / relative
        target = destination / relative
        if not source.exists() and not source.is_symlink():
            deleted.append(name)
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        metadata = source.lstat()
        mode = stat.S_IMODE(metadata.st_mode)
        if source.is_symlink():
            link = os.readlink(source)
            os.symlink(link, target)
            raw = link.encode("utf-8")
            kind = "symlink"
        elif source.is_file():
            raw = source.read_bytes()
            target.write_bytes(raw)
            target.chmod(mode)
            kind = "file"
        else:
            raise PipelineError("SNAPSHOT_TYPE", f"unsupported repository entry: {name}")
        files.append(
            {
                "path": name,
                "kind": kind,
                "mode": f"{mode:04o}",
                "bytes": len(raw),
                "sha256": evidence_digest.artifact_bytes_sha256(raw),
            }
        )
    if not files:
        raise PipelineError("SNAPSHOT_EMPTY", "Git working-file inventory is empty")
    digest = evidence_digest.text_evidence_bytes_sha256(
        canonical_json({"files": files, "deleted_tracked": deleted})
    )
    return {
        "method": "git tracked plus nonignored untracked working-file bytes",
        "excluded_roots": sorted(GENERATED_ROOT_NAMES),
        "file_count": len(files),
        "deleted_tracked": deleted,
        "files": files,
        "input_sha256": digest,
    }

def verify_snapshot_copy(repository: Path, snapshot: Mapping[str, Any]) -> str:
    entries: list[dict[str, Any]] = []
    raw_entries = snapshot.get("files")
    if not isinstance(raw_entries, list) or not raw_entries:
        raise PipelineError("SNAPSHOT_MANIFEST", "snapshot file manifest is absent")
    for raw_entry in raw_entries:
        if not isinstance(raw_entry, dict) or not isinstance(raw_entry.get("path"), str):
            raise PipelineError("SNAPSHOT_MANIFEST", "snapshot file entry is invalid")
        relative = Path(raw_entry["path"])
        path = repository / relative
        if raw_entry.get("kind") == "symlink" and path.is_symlink():
            payload = os.readlink(path).encode("utf-8")
        elif raw_entry.get("kind") == "file" and path.is_file():
            payload = path.read_bytes()
        else:
            raise PipelineError(
                "SNAPSHOT_COPY_MISMATCH", f"snapshot copy omitted {relative.as_posix()}"
            )
        mode = f"{stat.S_IMODE(path.lstat().st_mode):04o}"
        entry = {
            "path": relative.as_posix(),
            "kind": raw_entry["kind"],
            "mode": mode,
            "bytes": len(payload),
            "sha256": evidence_digest.artifact_bytes_sha256(payload),
        }
        if entry != raw_entry:
            raise PipelineError(
                "SNAPSHOT_COPY_MISMATCH", f"snapshot copy changed {relative.as_posix()}"
            )
        entries.append(entry)
    digest = evidence_digest.text_evidence_bytes_sha256(
        canonical_json(
            {
                "files": entries,
                "deleted_tracked": snapshot.get("deleted_tracked", []),
            }
        )
    )
    if not evidence_digest.schema_text_sha256_equal(
        digest, snapshot.get("input_sha256")
    ):
        raise PipelineError("SNAPSHOT_COPY_MISMATCH", "snapshot copy digest changed")
    return digest



def _required_executable(
    label: str, environment_names: Sequence[str], candidates: Sequence[str]
) -> str:
    configured = next((os.environ.get(name) for name in environment_names if os.environ.get(name)), None)
    choices = (configured,) if configured is not None else tuple(candidates)
    for choice in choices:
        if choice is None:
            continue
        resolved = shutil.which(choice) if os.sep not in choice else choice
        if resolved is not None and Path(resolved).is_file() and os.access(resolved, os.X_OK):
            return str(Path(resolved).absolute())
    requested = configured or ", ".join(candidates)
    raise PipelineError("TOOL_MISSING", f"required tool is unavailable: {label} ({requested})")


def resolve_tools() -> dict[str, str]:
    try:
        native = {
            "cc": tls_builder.resolve_tool(None, "/usr/lib/llvm15/bin/clang", "clang"),
            "cxx": tls_builder.resolve_tool(None, "/usr/lib/llvm15/bin/clang++", "clang++"),
            "cmake": tls_builder.resolve_tool(None, "/usr/bin/cmake", "cmake"),
            "ar": tls_builder.resolve_tool(None, "/usr/lib/llvm15/bin/llvm-ar", "llvm-ar"),
            "ranlib": tls_builder.resolve_tool(
                None, "/usr/lib/llvm15/bin/llvm-ranlib", "llvm-ranlib"
            ),
        }
    except tls_builder.BuildError as error:
        raise PipelineError("TOOL_MISSING", str(error)) from error
    return {
        "python": str(Path(sys.executable).absolute()),
        "git": _required_executable("git", (), ("git",)),
        "cjc": _required_executable("cjc", ("CJC",), ("cjc",)),
        "cjpm": _required_executable("cjpm", ("CJPM",), ("cjpm",)),
        "cjdoc": _required_executable("cjdoc", ("CJDOC_BIN", "CJDOC"), ("cjdoc",)),
        "cc": native["cc"],
        "cxx": native["cxx"],
        "cmake": native["cmake"],
        "ninja": _required_executable("ninja", ("NINJA",), ("ninja",)),
        "ar": native["ar"],
        "ranlib": native["ranlib"],
        "readelf": _required_executable("readelf", ("READELF",), ("readelf",)),
        "ldd": _required_executable("ldd", ("LDD",), ("/usr/bin/ldd", "ldd")),
        "getconf": _required_executable("getconf", (), ("getconf",)),
        "uname": _required_executable("uname", (), ("uname",)),
    }


def _runtime_inventory(cjc: str) -> dict[str, Any]:
    roots: list[Path] = []
    configured = os.environ.get("CANGJIE_HOME")
    if configured:
        roots.append(Path(configured))
    cjc_path = Path(cjc).resolve()
    roots.extend(parent for parent in list(cjc_path.parents)[:3])
    directories: set[Path] = set()
    for root in roots:
        directories.add(root / "runtime/lib/linux_x86_64_cjnative")
        directories.add(root / "lib/linux_x86_64_cjnative")
    for value in os.environ.get("LD_LIBRARY_PATH", "").split(os.pathsep):
        if value:
            directories.add(Path(value))
    libraries: list[str] = []
    selected_directories: list[str] = []
    for directory in sorted(directories, key=lambda item: str(item)):
        if not directory.is_dir():
            continue
        matches = sorted(directory.glob("libcangjie-runtime.so*"))
        if matches:
            selected_directories.append(str(directory.resolve()))
            libraries.extend(str(path.resolve()) for path in matches if path.is_file())
    libraries = sorted(set(libraries))
    if not libraries:
        raise PipelineError(
            "CANGJIE_RUNTIME_MISSING", "cannot locate libcangjie-runtime.so for selected cjc"
        )
    return {
        "cangjie_home": str(Path(configured).resolve()) if configured else None,
        "library_directories": selected_directories,
        "libraries": libraries,
    }


def _require_cjdoc_version(output: str) -> None:
    if re.search(r"(?<![0-9.])0\.7\.2(?![0-9.])", output) is None:
        raise PipelineError(
            "CJDOC_VERSION", f"required cjdoc 0.7.2, got {output.strip() or 'no output'}"
        )


def collect_tool_metadata(
    repository: Path, runner: CommandRunner, tools: Mapping[str, str], environment: Mapping[str, str]
) -> dict[str, Any]:
    version_arguments = {
        "python": ("--version",),
        "git": ("--version",),
        "cjc": ("-v",),
        "cjpm": ("--version",),
        "cjdoc": ("--version",),
        "cc": ("--version",),
        "cxx": ("--version",),
        "cmake": ("--version",),
        "ninja": ("--version",),
        "ar": ("--version",),
        "ranlib": ("--version",),
        "readelf": ("--version",),
        "ldd": ("--version",),
    }
    identities: dict[str, Any] = {}
    for name, arguments in version_arguments.items():
        result = runner.run(
            CommandSpec(f"tool-{name}", (tools[name], *arguments), repository, 30), environment
        )
        output = (result.stdout + result.stderr).strip()
        if not output:
            raise PipelineError("TOOL_VERSION_EMPTY", f"{name} returned no version metadata")
        identities[name] = {
            "path": tools[name],
            "version_output": output.splitlines(),
            "log": str(result.log),
        }
    _require_cjdoc_version(
        "\n".join(identities["cjdoc"]["version_output"])
    )
    isolated_home = confined_path(runner.run_root, runner.run_root / "preflight-cjdoc-home")
    isolated_home.mkdir()
    isolated_environment = dict(environment)
    isolated_environment["HOME"] = str(isolated_home)
    isolated_environment["XDG_CACHE_HOME"] = str(isolated_home / "cache")
    isolated_cjdoc = runner.run(
        CommandSpec(
            "tool-cjdoc-isolated-home",
            (tools["cjdoc"], "--version"),
            repository,
            30,
        ),
        isolated_environment,
    )
    isolated_output = (isolated_cjdoc.stdout + isolated_cjdoc.stderr).strip()
    _require_cjdoc_version(isolated_output)
    identities["cjdoc"]["isolated_home_version_output"] = isolated_output.splitlines()
    identities["cjdoc"]["isolated_home_log"] = str(isolated_cjdoc.log)
    uname = runner.run(
        CommandSpec("platform-uname", (tools["uname"], "-srm"), repository, 30), environment
    )
    libc = runner.run(
        CommandSpec(
            "platform-glibc", (tools["getconf"], "GNU_LIBC_VERSION"), repository, 30
        ),
        environment,
    )
    target = release.platform_identity()
    if target != {
        "os": "linux",
        "architecture": "x86_64",
        "libc": "glibc",
        "libc_version": target["libc_version"],
    }:
        raise PipelineError("PLATFORM_UNSUPPORTED", f"expected {PROFILE}, got {target}")
    return {
        "profile": PROFILE,
        "platform": target,
        "uname": uname.stdout.strip(),
        "getconf": libc.stdout.strip(),
        "tools": identities,
        "runtime": _runtime_inventory(tools["cjc"]),
    }


def select_and_verify_source(repository: Path, override: Path | None) -> tuple[Path, dict[str, str]]:
    manifest = tls_builder.load_provider_manifest(
        repository / "native/tls/aws_lc/provider.json"
    )
    configured = override
    if configured is None:
        value = os.environ.get("WIRESTACK_AWS_LC_SOURCE")
        configured = Path(value) if value else None
    source = (
        configured.resolve()
        if configured is not None
        else (repository / ".local/tls-provider/source/aws-lc-5.5.0").resolve()
    )
    if not source.is_dir():
        raise PipelineError(
            "PINNED_SOURCE_MISSING",
            f"verified AWS-LC 5.5.0 source is unavailable at {source}",
        )
    try:
        identity = tls_builder.verify_source(source, manifest)
    except tls_builder.BuildError as error:
        raise PipelineError("PINNED_SOURCE_INVALID", str(error)) from error
    expected = {
        "commit": tls_builder.REQUIRED_COMMIT,
        "tree": tls_builder.REQUIRED_TREE,
        "content_sha256": tls_builder.REQUIRED_CONTENT_SHA256,
    }
    if identity != expected:
        raise PipelineError("PINNED_SOURCE_INVALID", "AWS-LC source identity is not exact")
    return source, identity


def isolated_environment(
    base: Mapping[str, str],
    leg_root: Path,
    source: Path,
    tools: Mapping[str, str],
    *,
    native_tools: bool = True,
) -> dict[str, str]:
    environment = dict(base)
    home = confined_path(leg_root, leg_root / "home")
    path_tool_names = ["cjc", "cjpm", "cjdoc", "readelf", "ldd"]
    if native_tools:
        path_tool_names.extend(("cc", "cxx", "cmake", "ninja", "ar", "ranlib"))
    selected_path = os.pathsep.join(
        dict.fromkeys(
            [
                *(str(Path(tools[name]).parent) for name in path_tool_names),
                *(value for value in base.get("PATH", "").split(os.pathsep) if value),
            ]
        )
    )
    cache = confined_path(leg_root, leg_root / "cache")
    temporary = confined_path(leg_root, leg_root / "tmp")
    for directory in (home, cache, temporary, cache / "xdg", cache / "cjpm"):
        directory.mkdir(parents=True, exist_ok=True)
    environment.update(
        {
            "HOME": str(home),
            "XDG_CACHE_HOME": str(cache / "xdg"),
            "PATH": selected_path,
            "CJPM_HOME": str(cache / "cjpm"),
            "TMPDIR": str(temporary),
            "CJDOC_BIN": tools["cjdoc"],
            "CJDOC": tools["cjdoc"],
            "WIRESTACK_AWS_LC_SOURCE": str(source),
            "WIRESTACK_TARGET_PLATFORM": PROFILE,
            "WIRESTACK_TLS_PROVIDER": "aws-lc",
            "SOURCE_DATE_EPOCH": "0",
            "PYTHONHASHSEED": "0",
            "LDD": tools["ldd"],
        }
    )
    native_environment = {
        "CC": tools["cc"],
        "CXX": tools["cxx"],
        "CMAKE": tools["cmake"],
        "NINJA": tools["ninja"],
        "AR": tools["ar"],
        "RANLIB": tools["ranlib"],
        "READELF": tools["readelf"],
    }
    if native_tools:
        environment.update(native_environment)
    else:
        for name in native_environment:
            environment.pop(name, None)
    return environment


def _load_object(path: Path, label: str) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise PipelineError("REPORT_INVALID", f"cannot read {label}: {path}: {error}") from error
    if not isinstance(value, dict):
        raise PipelineError("REPORT_INVALID", f"{label} is not a JSON object: {path}")
    return value


def initialize_isolated_repository(
    repository: Path,
    environment: Mapping[str, str],
    tools: Mapping[str, str],
    runner: CommandRunner,
    label: str,
) -> dict[str, str]:
    isolated = dict(environment)
    isolated.update(
        {
            "GIT_CEILING_DIRECTORIES": str(repository.parent),
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_SYSTEM": os.devnull,
            "GIT_CONFIG_NOSYSTEM": "1",
        }
    )
    results = runner.run_chain(
        (
            CommandSpec(
                f"{label}-snapshot-git-init",
                (tools["git"], "init", "--quiet", str(repository)),
                repository,
                60,
            ),
            CommandSpec(
                f"{label}-snapshot-git-index",
                (
                    tools["git"],
                    "-c",
                    f"core.excludesFile={os.devnull}",
                    "add",
                    "-f",
                    "--all",
                    "--",
                    ".",
                ),
                repository,
                120,
            ),
            CommandSpec(
                f"{label}-snapshot-git-boundary",
                (tools["git"], "rev-parse", "--show-toplevel"),
                repository,
                30,
            ),
        ),
        isolated,
    )
    discovered = results[-1].stdout.strip()
    if Path(discovered).resolve() != repository.resolve():
        raise PipelineError(
            "SNAPSHOT_GIT_ESCAPE",
            f"isolated repository discovered an outer Git root: {discovered}",
        )
    return isolated


def build_leg(
    name: str,
    frozen: Path,
    snapshot: Mapping[str, Any],
    run_root: Path,
    source: Path,
    tools: Mapping[str, str],
    base_environment: Mapping[str, str],
    runner: CommandRunner,
) -> dict[str, Any]:
    leg_root = confined_path(run_root, run_root / "legs" / name)
    repository = confined_path(run_root, leg_root / "repo")
    if leg_root.exists():
        raise PipelineError("LEG_EXISTS", f"leg already exists: {leg_root}")
    leg_root.mkdir(parents=True)
    shutil.copytree(frozen, repository, symlinks=True)
    input_digest = verify_snapshot_copy(repository, snapshot)
    environment = initialize_isolated_repository(
        repository,
        isolated_environment(base_environment, leg_root, source, tools),
        tools,
        runner,
        name,
    )
    native_root = repository / "target/native"
    release_root = confined_path(run_root, leg_root / "release")
    commands = (
        CommandSpec(
            f"{name}-provider-build",
            (
                tools["python"],
                str(repository / "tools/build_linux_tls_provider.py"),
                "--repo",
                str(repository),
                "--source-dir",
                str(source),
                "--offline",
                "--out-dir",
                str(native_root),
                "--cache-dir",
                str(leg_root / "cache/provider"),
                "--print-manifest",
                "--cc",
                tools["cc"],
                "--cxx",
                tools["cxx"],
                "--cmake",
                tools["cmake"],
                "--ar",
                tools["ar"],
                "--ranlib",
                tools["ranlib"],
            ),
            repository,
            3_600,
        ),
        CommandSpec(
            f"{name}-resolver-build",
            (
                tools["python"],
                str(repository / "tools/build_linux_resolver.py"),
                "--root",
                str(repository),
                "--output-root",
                str(native_root / "resolver"),
            ),
            repository,
            300,
        ),
        CommandSpec(
            f"{name}-release-qualification",
            (
                tools["python"],
                str(repository / "tools/m7_021_linux_release.py"),
                "--root",
                str(repository),
                "--output-dir",
                str(release_root),
                "--offline",
            ),
            repository,
            2_400,
        ),
    )
    runner.run_chain(commands, environment)
    paths = {
        "provider_archive": native_root / "current/lib/libwirestack_tls_provider.a",
        "resolver_archive": native_root / "resolver/current/lib/libwirestack_resolver.a",
        "release_archive": release_root / release.ARTIFACT_NAME,
    }
    for label, path in paths.items():
        paths[label] = confined_path(run_root, path)
    missing = [label for label, path in paths.items() if not path.is_file()]
    if missing:
        raise PipelineError("ARTIFACT_MISSING", f"{name} omitted artifacts: {missing}")
    provider_manifest = _load_object(
        native_root / "current/provider-manifest.json", f"{name} provider manifest"
    )
    resolver_manifest = _load_object(
        native_root / "resolver/current/resolver-manifest.json", f"{name} resolver manifest"
    )
    qualification = _load_object(
        release_root / "qualification.json", f"{name} qualification"
    )
    try:
        release.validate_report(qualification, repository)
    except release.ReleaseError as error:
        raise PipelineError("QUALIFICATION_INVALID", f"{name}: {error}") from error
    if provider_manifest.get("abiVersion") != 1:
        raise PipelineError("NATIVE_ABI_INVALID", f"{name} provider ABI is not 1")
    if provider_manifest.get("externalOpenSslDependency") is not False:
        raise PipelineError("OPENSSL_DEPENDENCY", f"{name} provider permits external OpenSSL")
    expected_digests = {
        "provider_archive": provider_manifest.get("archive", {}).get("sha256"),
        "resolver_archive": resolver_manifest.get("archive", {}).get("sha256"),
        "release_archive": qualification.get("artifact", {}).get("sha256"),
    }
    for label, expected in expected_digests.items():
        actual = evidence_digest.artifact_byte_sha256(paths[label])
        if not evidence_digest.schema_artifact_sha256_equal(expected, actual):
            raise PipelineError(
                "ARTIFACT_MANIFEST_MISMATCH",
                f"{name} {label} bytes do not match their manifest",
            )
    return {
        "name": name,
        "root": str(leg_root),
        "repository": str(repository),
        "environment_roots": {
            key: environment[key] for key in ("HOME", "XDG_CACHE_HOME", "CJPM_HOME", "TMPDIR")
        },
        "checks": {
            "provider_native_smoke": "PASS",
            "resolver_native_smoke": "PASS",
            "release_qualification": "PASS",
        },
        "input_sha256": input_digest,
        "artifacts": {label: str(path) for label, path in paths.items()},
        "provider_manifest": provider_manifest,
        "resolver_manifest": resolver_manifest,
        "qualification": qualification,
    }


def compare_artifacts(pairs: Mapping[str, tuple[Path, Path]]) -> dict[str, Any]:
    if set(pairs) != set(REPRODUCIBLE_ARTIFACTS):
        raise PipelineError("ARTIFACT_INVENTORY", "reproducibility artifact inventory is incomplete")
    result: dict[str, Any] = {}
    for name in REPRODUCIBLE_ARTIFACTS:
        left, right = pairs[name]
        if not left.is_file() or not right.is_file():
            raise PipelineError("ARTIFACT_MISSING", f"cannot compare {name}")
        left_digest = evidence_digest.artifact_byte_sha256(left)
        right_digest = evidence_digest.artifact_byte_sha256(right)
        byte_identical = left.stat().st_size == right.stat().st_size and filecmp.cmp(
            left, right, shallow=False
        )
        if (
            not evidence_digest.schema_artifact_sha256_equal(
                left_digest, right_digest
            )
            or not byte_identical
        ):
            raise PipelineError(
                "ARTIFACT_MISMATCH",
                f"independent A/B builds differ for {name}: {left_digest} != {right_digest}",
            )
        result[name] = {
            "bytes": left.stat().st_size,
            "sha256": left_digest,
            "a": str(left.resolve()),
            "b": str(right.resolve()),
            "byte_identical": True,
        }
    return result


def _installed_example_manifest(installed: Path) -> str:
    template = examples.consumer_manifest()
    original = json.dumps(str(examples.ROOT))
    replacement = json.dumps(str(installed.resolve()))
    if template.count(original) != 1:
        raise PipelineError("CONSUMER_MANIFEST", "M7-027 consumer layout changed unexpectedly")
    return template.replace(original, replacement, 1)


def _scan_consumer_binary(
    binary: Path,
    consumer: Path,
    environment: Mapping[str, str],
    tools: Mapping[str, str],
    runner: CommandRunner,
) -> dict[str, Any]:
    readelf_result = runner.run(
        CommandSpec(
            "consumer-readelf", (tools["readelf"], "-d", str(binary)), consumer, 60
        ),
        environment,
    )
    ldd_result = runner.run(
        CommandSpec("consumer-ldd", (tools["ldd"], str(binary)), consumer, 60),
        environment,
    )
    needed = release.parse_needed(readelf_result.stdout)
    resolved = release.parse_ldd(ldd_result.stdout)
    if not needed:
        raise PipelineError("ELF_NEEDED_EMPTY", "consumer ELF NEEDED inventory is empty")
    if not resolved:
        raise PipelineError("ELF_RESOLVED_EMPTY", "consumer ldd inventory is empty")
    try:
        release.reject_openssl_dependencies(needed)
        release.reject_openssl_dependencies(item["name"] for item in resolved)
    except release.ReleaseError as error:
        raise PipelineError("OPENSSL_DEPENDENCY", str(error)) from error
    missing = [item["name"] for item in resolved if item["resolved"] == "not found"]
    if missing:
        raise PipelineError("ELF_LIBRARY_MISSING", f"consumer libraries not found: {missing}")
    loader_strings = [
        value.decode()
        for value in release.FORBIDDEN_LOADER_BYTES
        if value in binary.read_bytes().lower()
    ]
    if loader_strings:
        raise PipelineError(
            "OPENSSL_LOADER_STRING", f"consumer contains loader strings: {loader_strings}"
        )
    return {
        "binary": str(binary.resolve()),
        "elf_sha256": evidence_digest.artifact_byte_sha256(binary),
        "needed": needed,
        "resolved": resolved,
        "readelf_log": str(readelf_result.log),
        "ldd_log": str(ldd_result.log),
        "forbidden_dependencies": [],
        "runtime_loader_library_strings": [],
    }


def run_installed_examples(
    frozen: Path,
    release_archive: Path,
    run_root: Path,
    source: Path,
    tools: Mapping[str, str],
    base_environment: Mapping[str, str],
    runner: CommandRunner,
) -> dict[str, Any]:
    work = confined_path(run_root, run_root / "installed-consumer")
    work.mkdir(parents=True)
    installed = confined_path(
        run_root, release.extract_archive(release_archive, work / "install")
    )
    consumer = work / "consumer"
    source_root = consumer / "src"
    source_root.mkdir(parents=True)
    sources = examples.load_and_validate_sources(frozen / "examples/linux/m7_027")
    (consumer / "cjpm.toml").write_text(
        _installed_example_manifest(installed), encoding="utf-8"
    )
    for name in examples.SOURCE_NAMES:
        (source_root / name).write_text(sources[name], encoding="utf-8")
    environment = isolated_environment(base_environment, work, source, tools)
    build = runner.run(
        CommandSpec(
            "installed-examples-build", (tools["cjpm"], "build"), consumer, 600
        ),
        environment,
    )
    binary = consumer / "target/release/bin/main"
    binary = confined_path(run_root, binary)
    if not binary.is_file():
        raise PipelineError(
            "CONSUMER_BINARY_MISSING", "installed example build produced no executable"
        )
    execution = runner.run(
        CommandSpec("installed-examples-run", (str(binary),), consumer, 120), environment
    )
    try:
        examples.validate_markers(execution.stdout)
    except examples.ExampleGateError as error:
        raise PipelineError(error.code, str(error)) from error
    dependency_scan = _scan_consumer_binary(
        binary, consumer, environment, tools, runner
    )
    return {
        "installed_root": str(installed.resolve()),
        "consumer_root": str(consumer.resolve()),
        "manifest_dependency": str(installed.resolve()),
        "sources": list(examples.SOURCE_NAMES),
        "build_log": str(build.log),
        "run_log": str(execution.log),
        "markers": list(examples.EXPECTED_MARKERS),
        "skipped_as_pass": False,
        "dependency_scan": dependency_scan,
    }




def _native_link_contract(installed_root: Path) -> list[str]:
    manifest_path = installed_root / "cjpm.toml"
    try:
        manifest = tomllib.loads(manifest_path.read_text(encoding="utf-8"))
        options = manifest["target"]["x86_64-unknown-linux-gnu"]["link-option"]
    except (OSError, tomllib.TOMLDecodeError, KeyError, TypeError) as error:
        raise PipelineError(
            "NATIVE_LINK_CONTRACT", f"cannot read installed Linux link contract: {error}"
        ) from error
    expected = "-lstdc++ -lpthread -ldl -lm"
    if options != expected:
        raise PipelineError(
            "NATIVE_LINK_CONTRACT", f"unexpected installed Linux link options: {options!r}"
        )
    return expected.split()


def _runtime_contract(leg: Mapping[str, Any]) -> dict[str, Any]:
    qualification = leg["qualification"]
    installation = qualification.get("installation", {})
    output = installation.get("smoke_output", [])
    if not isinstance(output, list) or not all(isinstance(line, str) for line in output):
        raise PipelineError("RUNTIME_OUTPUT_INVALID", "release smoke output is absent")
    try:
        release.validate_smoke_output("\n".join(output))
    except release.ReleaseError as error:
        raise PipelineError("RUNTIME_OUTPUT_INVALID", str(error)) from error
    fingerprint = next(
        (line.split("=", 1)[1] for line in output if line.startswith("buildFingerprint=")), ""
    )
    if not fingerprint:
        raise PipelineError("RUNTIME_FINGERPRINT_EMPTY", "TlsRuntime fingerprint is empty")
    provider = leg["provider_manifest"]
    if (
        provider.get("providerId") != "aws-lc"
        or provider.get("providerVersion") != "5.5.0"
        or provider.get("externalOpenSslDependency") is not False
    ):
        raise PipelineError("RUNTIME_PROVIDER_INVALID", "runtime provider contract is not exact")
    return {
        "provider": "aws-lc",
        "provider_version": "5.5.0",
        "build_fingerprint": fingerprint,
        "external_openssl_dependency": False,
        "smoke_output": output,
    }


def execute(repository: Path, source_override: Path | None = None) -> tuple[Path, dict[str, Any]]:
    repository = repository.resolve()
    if not (repository / "tools/m7_021_linux_release.py").is_file():
        raise PipelineError("REPOSITORY_INVALID", f"not a Wirestack checkout: {repository}")
    base_environment = dict(os.environ)
    run_root = create_run_root(repository)
    runner = CommandRunner(run_root)
    report_path = confined_path(run_root, run_root / "native-contracts.json")
    started = dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")
    report: dict[str, Any] = {
        "schema_version": 1,
        "task_id": TASK_ID,
        "source_task": TASK_ID,
        "status": "FAIL",
        "decision": "FAIL",
        "run_root": str(run_root),
        "started_at_utc": started,
        "steps": {},
        "commands": runner.records,
    }
    source: Path | None = None
    source_identity: dict[str, str] | None = None
    try:
        tools = resolve_tools()
        metadata = collect_tool_metadata(repository, runner, tools, base_environment)
        source, source_identity = select_and_verify_source(repository, source_override)
        revision_result = runner.run(
            CommandSpec(
                "repository-revision",
                (tools["git"], "-C", str(repository), "rev-parse", "HEAD"),
                repository,
                30,
            ),
            base_environment,
        )
        revision = revision_result.stdout.strip()
        if not re.fullmatch(r"[0-9a-f]{40}", revision):
            raise PipelineError("REVISION_INVALID", "repository HEAD is not a full Git object id")
        base_environment["GITHUB_SHA"] = revision
        report["steps"]["1_toolchain_and_pinned_source"] = {
            "decision": "PASS",
            "toolchain": metadata,
            "source": {"path": str(source), **source_identity, "access": "read-only input"},
        }

        frozen = confined_path(run_root, run_root / "frozen-working-files")
        snapshot = freeze_repository(repository, frozen, runner)
        snapshot["revision"] = revision
        report["steps"]["2_working_file_snapshot"] = {
            "decision": "PASS",
            **snapshot,
            "root": str(frozen),
        }

        leg_a = build_leg(
            "A", frozen, snapshot, run_root, source, tools, base_environment, runner
        )
        leg_b = build_leg(
            "B", frozen, snapshot, run_root, source, tools, base_environment, runner
        )
        report["steps"]["3_independent_native_and_release_builds"] = {
            "decision": "PASS",
            "input_sha256": snapshot["input_sha256"],
            "legs": {"A": leg_a, "B": leg_b},
        }

        pairs = {
            name: (
                Path(leg_a["artifacts"][name]),
                Path(leg_b["artifacts"][name]),
            )
            for name in REPRODUCIBLE_ARTIFACTS
        }
        reproducibility = compare_artifacts(pairs)
        toolchain_digest = evidence_digest.text_evidence_bytes_sha256(
            canonical_json(metadata)
        )
        report["steps"]["4_raw_artifact_reproducibility"] = {
            "decision": "PASS",
            "input_sha256": snapshot["input_sha256"],
            "toolchain_sha256": toolchain_digest,
            "artifacts": reproducibility,
            "native_abi": {
                "provider": leg_a["provider_manifest"].get("abiVersion"),
                "resolver_private_runtime_abi": leg_a["resolver_manifest"].get(
                    "private_runtime_abi"
                ),
            },
        }

        consumer = run_installed_examples(
            frozen,
            Path(leg_a["artifacts"]["release_archive"]),
            run_root,
            source,
            tools,
            base_environment,
            runner,
        )
        report["steps"]["5_installed_public_examples"] = {
            "decision": "PASS",
            **consumer,
        }
        runtime = _runtime_contract(leg_a)
        report["steps"]["6_elf_and_runtime_closure"] = {
            "decision": "PASS",
            "dependency_scan": consumer["dependency_scan"],
            "runtime": runtime,
            "native_link_contract": _native_link_contract(
                Path(consumer["installed_root"])
            ),
        }

        leg_a_root = Path(leg_a["root"])
        check_repository = Path(leg_a["repository"])
        check_environment = isolated_environment(
            base_environment,
            leg_a_root,
            source,
            tools,
            native_tools=False,
        )
        check_environment.update(
            {
                "GIT_CEILING_DIRECTORIES": str(check_repository.parent),
                "GIT_CONFIG_GLOBAL": os.devnull,
                "GIT_CONFIG_SYSTEM": os.devnull,
                "GIT_CONFIG_NOSYSTEM": "1",
            }
        )
        check = runner.run(
            CommandSpec(
                "snapshot-canonical-check",
                (str(check_repository / "scripts/check"),),
                check_repository,
                MAX_COMMAND_SECONDS,
            ),
            check_environment,
        )
        report["steps"]["7_snapshot_canonical_check"] = {
            "decision": "PASS",
            "repository": str(check_repository),
            "log": str(check.log),
            "original_working_tree_executed": False,
            "compiler_environment_overrides": False,
            "git_boundary": str(check_repository),
        }

        post_source, post_identity = select_and_verify_source(repository, source)
        if post_source != source or post_identity != source_identity:
            raise PipelineError("PINNED_SOURCE_MUTATED", "AWS-LC source identity changed")
        report["source_post_verification"] = {
            "path": str(post_source), **post_identity, "clean": True
        }
        report["decision"] = "PASS"
        report["status"] = "PASS"
        report["completed_at_utc"] = dt.datetime.now(dt.timezone.utc).isoformat().replace(
            "+00:00", "Z"
        )
        report["commands"] = runner.records
        evidence_digest.atomic_json(report_path, report)
        return report_path, report
    except Exception as error:
        if isinstance(error, PipelineError):
            failure = error
        elif isinstance(error, (tls_builder.BuildError, release.ReleaseError)):
            failure = PipelineError("HELPER_FAILED", str(error))
        else:
            failure = PipelineError(type(error).__name__.upper(), str(error))
        if source is not None and source_identity is not None:
            try:
                failed_source, failed_identity = select_and_verify_source(repository, source)
                if failed_source != source or failed_identity != source_identity:
                    raise PipelineError(
                        "PINNED_SOURCE_MUTATED", "AWS-LC source identity changed"
                    )
                report["source_post_verification"] = {
                    "path": str(failed_source), **failed_identity, "clean": True
                }
            except Exception as source_error:
                failure = PipelineError(
                    "PINNED_SOURCE_MUTATED",
                    f"AWS-LC source failed post-run verification: {source_error}",
                )
        report["failure"] = {"code": failure.code, "detail": failure.detail}
        report["completed_at_utc"] = dt.datetime.now(dt.timezone.utc).isoformat().replace(
            "+00:00", "Z"
        )
        report["commands"] = runner.records
        evidence_digest.atomic_json(report_path, report)
        raise PipelineError(
            failure.code, f"{failure.detail}; report={report_path}"
        ) from error


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--source-dir", type=Path)
    parser.add_argument("--json", action="store_true")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        report_path, report = execute(args.root, args.source_dir)
    except PipelineError as error:
        payload = {
            "task_id": TASK_ID,
            "source_task": TASK_ID,
            "decision": "FAIL",
            "status": "FAIL",
            "code": error.code,
            "error": error.detail,
        }
        print(json.dumps(payload, sort_keys=True) if args.json else f"{TASK_ID} FAIL: {error}")
        return 1
    payload = {
        "task_id": TASK_ID,
        "decision": "PASS",
        "source_task": TASK_ID,
        "status": "PASS",
        "run_root": report["run_root"],
        "report": str(report_path),
    }
    print(json.dumps(payload, sort_keys=True) if args.json else f"{TASK_ID} PASS: {report_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
