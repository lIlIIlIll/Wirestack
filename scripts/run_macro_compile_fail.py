#!/usr/bin/env python3
"""Compile-fail gate for the @JsonCodec macro rejection diagnostics.

Each fixture under tests/macro_compile_fail/ is a minimal Cangjie source file
that MUST fail to compile with a specific diagnostic from json_codec.cj.
The harness compiles every fixture with the daily cjc in single-file mode,
asserts a non-zero exit and the expected diagnostic fragment on stderr, and
reports the pass/fail count.

Run (from the repository root):

    python3 scripts/run_macro_compile_fail.py

The harness sources $CANGJIE_SDK/daily/cangjie/envsetup.sh (or honors
CANGJIE_HOME already being set) and relies on the root build artifacts at
target/release for `--import-path`, so run the core build first:

    cjpm build

Compiler output goes to an isolated /tmp directory; nothing is written under
target/ or the repository.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
FIXTURE_DIR = REPO / "tests" / "macro_compile_fail"
SDK_DAILY = Path(os.environ.get("CANGJIE_SDK", "~/cangjie_sdk")) / "daily" / "cangjie"
ENVSETUP = SDK_DAILY.expanduser() / "envsetup.sh"
IMPORT_PATH = REPO / "target" / "release"
TIMEOUT_SECONDS = 300


def env_with_cangjie() -> dict[str, str]:
    """Return an environment with CANGJIE_HOME/PATH/LD_LIBRARY_PATH set.

    Prefers an already-configured environment; otherwise sources envsetup.sh
    through bash and captures the exported variables.
    """
    if "CANGJIE_HOME" in os.environ and "cjc" in os.environ.get("PATH", ""):
        return dict(os.environ)
    if not ENVSETUP.is_file():
        raise SystemExit(f"cangjie envsetup not found: {ENVSETUP}")
    script = (
        f"source {ENVSETUP} && "
        "python3 -c 'import json,os; print(json.dumps("
        "{k: os.environ[k] for k in (\"CANGJIE_HOME\", \"PATH\", "
        "\"LD_LIBRARY_PATH\") if k in os.environ}))'"
    )
    completed = subprocess.run(
        ["bash", "-c", script], text=True, capture_output=True, check=False)
    if completed.returncode != 0:
        raise SystemExit(f"cannot source {ENVSETUP}: {completed.stderr}")
    env = dict(os.environ)
    env.update(json.loads(completed.stdout))
    return env


def expected_diagnostics(fixture: Path) -> list[str]:
    """Read the expected stderr fragments from a fixture's own comment block.

    Fixtures declare their expectation with a line of the form:

        // expect-diagnostic: duplicate JSON name

    One such line per expected fragment.
    """
    fragments: list[str] = []
    for line in fixture.read_text(encoding="utf-8").splitlines():
        match = re.fullmatch(r"\s*//\s*expect-diagnostic:\s*(.+?)\s*", line)
        if match:
            fragments.append(match.group(1))
    return fragments


def compile_fixture(fixture: Path, env: dict[str, str]) -> tuple[int, str]:
    with tempfile.TemporaryDirectory(prefix="yjson-macro-cf-") as scratch:
        output = Path(scratch) / "prog"
        command = [
            "cjc", "-Woff", "all",
            "--import-path", str(IMPORT_PATH),
            "-o", str(output),
            str(fixture),
        ]
        completed = subprocess.run(
            command, env=env, text=True, capture_output=True, timeout=TIMEOUT_SECONDS)
        return completed.returncode, completed.stderr


def main() -> int:
    if not FIXTURE_DIR.is_dir():
        print(f"error: fixture directory not found: {FIXTURE_DIR}", file=sys.stderr)
        return 2
    if not IMPORT_PATH.is_dir():
        print(
            f"error: build artifacts not found at {IMPORT_PATH}; run `cjpm build` first",
            file=sys.stderr,
        )
        return 2
    fixtures = sorted(FIXTURE_DIR.glob("*.cj"))
    if not fixtures:
        print(f"error: no .cj fixtures under {FIXTURE_DIR}", file=sys.stderr)
        return 2
    env = env_with_cangjie()
    passed = 0
    failures: list[tuple[Path, str]] = []
    for fixture in fixtures:
        expected = expected_diagnostics(fixture)
        if not expected:
            failures.append((fixture, "fixture declares no // expect-diagnostic line"))
            continue
        returncode, stderr = compile_fixture(fixture, env)
        missing = [fragment for fragment in expected if fragment not in stderr]
        if returncode == 0:
            failures.append((fixture, "compilation unexpectedly succeeded"))
        elif missing:
            failures.append(
                (fixture, f"missing diagnostics {missing}; stderr:\n{stderr[-4000:]}"))
        else:
            passed += 1
    for fixture, reason in failures:
        print(f"FAIL {fixture.name}: {reason}", file=sys.stderr)
    print(f"macro compile-fail: {passed}/{len(fixtures)} passed")
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
