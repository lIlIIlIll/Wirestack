#!/usr/bin/env python3
"""Run deterministic upload publication controls around an intercepted fsync phase."""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

DEFAULT_REPO = Path.cwd()
TEST_FILTER = "FileHandlerTest.uploadCommitChecksContextAfterDurabilityBeforePublication"
SCENARIOS = ("live", "cancel", "deadline", "cancel-existing")


def run(command: list[str], *, cwd: Path, env: dict[str, str] | None = None,
        timeout: int = 120) -> subprocess.CompletedProcess[str]:
    completed = subprocess.run(
        command,
        cwd=cwd,
        env=env,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        errors="replace",
        timeout=timeout,
        check=False,
    )
    print(f"$ {' '.join(command)}")
    print(completed.stdout, end="" if completed.stdout.endswith("\n") else "\n")
    if completed.returncode != 0:
        raise RuntimeError(f"command exited with {completed.returncode}")
    return completed


def compiler() -> str:
    configured = os.environ.get("CC")
    candidates = ([configured] if configured else []) + [
        "clang", "cc"
    ]
    for candidate in candidates:
        if not candidate:
            continue
        resolved = candidate if Path(candidate).is_absolute() else shutil.which(candidate)
        if resolved and Path(resolved).is_file():
            return str(Path(resolved).resolve())
    raise RuntimeError("no C compiler is available for the fsync preload shim")


def compile_shim(probe_dir: Path, work: Path) -> Path:
    output = work / "libwirestack_fsync_gate.so"
    run(
        [
            compiler(), "-std=c11", "-O2", "-fPIC", "-shared",
            "-Wall", "-Wextra", "-Werror",
            str(probe_dir / "fsync_gate.c"), "-ldl", "-pthread", "-o", str(output),
        ],
        cwd=work,
        timeout=30,
    )
    return output


def assert_filesystem_result(root: Path, scenario: str) -> None:
    unexpected = sorted(path.name for path in root.iterdir()
                        if path.name != "commit-boundary.bin")
    if unexpected:
        raise RuntimeError(f"{scenario}: unexpected files remained: {unexpected}")
    destination = root / "commit-boundary.bin"
    if scenario == "live":
        if not destination.is_file() or destination.read_bytes() != b"replacement":
            raise RuntimeError("live: committed destination did not contain the complete payload")
    elif scenario == "cancel-existing":
        if not destination.is_file() or destination.read_bytes() != b"original":
            raise RuntimeError("cancel-existing: the existing destination was not preserved")
    elif destination.exists():
        raise RuntimeError(f"{scenario}: destination was published after the context stopped")

def print_filesystem_observation(root: Path, scenario: str) -> None:
    entries = sorted(path.name for path in root.iterdir())
    destination = root / "commit-boundary.bin"
    payload = destination.read_bytes() if destination.is_file() else None
    print(f"OBSERVED {scenario}: entries={entries!r} destination={payload!r}")


def run_scenario(repo: Path, shim: Path, work: Path, scenario: str,
                 *, skip_build: bool) -> None:
    scenario_dir = work / scenario
    root = scenario_dir / "upload-root"
    root.mkdir(parents=True)
    entered = scenario_dir / "fsync-entered"
    release = scenario_dir / "fsync-release"
    environment = dict(os.environ)
    preload = str(shim)
    if environment.get("LD_PRELOAD"):
        preload += ":" + environment["LD_PRELOAD"]
    environment.update({
        "DISABLE_ZOXIDE": "1",
        "LD_PRELOAD": preload,
        "WIRESTACK_HTTP_FILES_COMMIT_SCENARIO": scenario,
        "WIRESTACK_HTTP_FILES_COMMIT_ROOT": str(root),
        "WIRESTACK_HTTP_FILES_COMMIT_ENTERED": str(entered),
        "WIRESTACK_HTTP_FILES_COMMIT_RELEASE": str(release),
    })
    command = [
        "cjpm", "test", "src/http",
    ]
    if skip_build:
        command.append("--skip-build")
    command.extend([
        "-j", "1", "--parallel", "1", "--exclude-tags=Performance", "--filter", TEST_FILTER,
        "--show-all-output", "--no-progress", "--no-color",
    ])
    command_error: RuntimeError | None = None
    try:
        run(command, cwd=repo, env=environment)
    except RuntimeError as error:
        command_error = error
    print_filesystem_observation(root, scenario)
    if not entered.is_file():
        raise RuntimeError(f"{scenario}: preload shim did not intercept the upload fsync")
    if not release.is_file():
        raise RuntimeError(f"{scenario}: test did not release the intercepted upload fsync")
    try:
        assert_filesystem_result(root, scenario)
    except RuntimeError as behavior_error:
        raise behavior_error from command_error
    if command_error is not None:
        raise command_error
    print(f"SCENARIO {scenario}: PASS")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=DEFAULT_REPO)
    args = parser.parse_args()
    repo = args.repo.resolve()
    probe_dir = Path(__file__).resolve().parent / "tests" / "fixtures" / "http_files"
    if not (repo / "src/http/file_handler_test.cj").is_file():
        raise RuntimeError(f"not a Wirestack publication checkout: {repo}")
    if shutil.which("cjpm") is None:
        raise RuntimeError("cjpm is unavailable; activate the qualified Cangjie SDK")

    with tempfile.TemporaryDirectory(prefix="wirestack-upload-commit-boundary-") as directory:
        work = Path(directory)
        shim = compile_shim(probe_dir, work)
        failures = []
        for index, scenario in enumerate(SCENARIOS):
            try:
                run_scenario(repo, shim, work, scenario, skip_build=index != 0)
            except (RuntimeError, subprocess.TimeoutExpired) as error:
                failures.append(f"{scenario}: {error}")
                print(f"SCENARIO {scenario}: FAIL: {error}")
        if failures:
            raise RuntimeError("; ".join(failures))
    print("UPLOAD COMMIT BOUNDARY: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
