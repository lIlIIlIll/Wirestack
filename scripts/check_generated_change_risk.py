#!/usr/bin/env python3
"""Require runtime consumer coverage for macro and generated-SPI changes."""

from __future__ import annotations

import argparse
import pathlib
import re
import subprocess


ROOT = pathlib.Path(__file__).resolve().parents[1]
RISK_PREFIXES = ("packages/yjson_macros/",)
RISK_FILES = {
    "src/lib_json_generated_support_v1.cj",
    "src/lib_json_direct_codec.cj",
    "src/lib_json_direct_reader.cj",
    "src/lib_json_direct_writer.cj",
}
CONSUMER_TEST_PREFIX = "packages/codec_integration/src/"


def is_generated_risk(path: str) -> bool:
    return path in RISK_FILES or path.startswith(RISK_PREFIXES)


def is_external_runtime_test(path: str) -> bool:
    return (
        path.startswith(CONSUMER_TEST_PREFIX)
        and path.endswith("_test.cj")
    )


def validate_changed_paths(paths: list[str]) -> list[str]:
    risks = sorted(path for path in paths if is_generated_risk(path))
    if not risks:
        return []
    tests = sorted(path for path in paths if is_external_runtime_test(path))
    if tests:
        return []
    return [
        "generated-code risk changed without an external runtime test in "
        f"{CONSUMER_TEST_PREFIX}: " + ", ".join(risks)
    ]


def validate_behavioral_test_diff(paths: list[str], diff: str) -> list[str]:
    if not any(is_generated_risk(path) for path in paths):
        return []
    added = []
    current_path = ""
    for line in diff.splitlines():
        if line.startswith("+++ b/"):
            current_path = line[6:]
        elif (
            current_path
            and is_external_runtime_test(current_path)
            and line.startswith("+")
            and not line.startswith("+++")
        ):
            source = line[1:].strip()
            if source and not source.startswith("//"):
                added.append(source)
    joined = "\n".join(added)
    has_case = "@TestCase" in joined
    has_public_call = "YJson.toJson" in joined or "YJson.fromJson" in joined
    has_assertion = bool(re.search(r"@(Assert|Expect)\s*\(", joined))
    if has_case and has_public_call and has_assertion:
        return []
    return [
        "generated-code risk requires added external runtime behavior: "
        "the consumer test diff must add @TestCase, a public YJson call, and an assertion"
    ]


def validate_wiring(root: pathlib.Path) -> list[str]:
    errors: list[str] = []
    ci_job = (root / "scripts/ci_job.sh").read_text(encoding="utf-8")
    workflow = (root / ".github/workflows/ci.yml").read_text(encoding="utf-8")
    release = (root / "scripts/release_cangjie_checks.sh").read_text(
        encoding="utf-8"
    )
    if "macro-consumer)" not in ci_job or "cjpm test --no-color" not in ci_job:
        errors.append("macro-consumer CI gate must run the external cjpm test target")
    if "- macro-consumer" not in workflow:
        errors.append("hosted CI matrix omits the macro-consumer runtime gate")
    if "macro-consumer-tests" not in release or "cjpm test --no-color" not in release:
        errors.append("release checks omit the external macro consumer test target")
    return errors


def changed_paths(root: pathlib.Path, base: str, head: str) -> list[str]:
    result = subprocess.run(
        ["git", "diff", "--name-only", f"{base}...{head}"],
        cwd=root,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
    )
    return [line for line in result.stdout.splitlines() if line]


def changed_diff(root: pathlib.Path, base: str, head: str) -> str:
    return subprocess.run(
        ["git", "diff", "--unified=0", f"{base}...{head}", "--"],
        cwd=root,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
    ).stdout


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base")
    parser.add_argument("--head", default="HEAD")
    parser.add_argument("--root", type=pathlib.Path, default=ROOT)
    args = parser.parse_args()
    root = args.root.resolve()

    errors = validate_wiring(root)
    paths: list[str] = []
    if args.base:
        paths = changed_paths(root, args.base, args.head)
        errors.extend(validate_changed_paths(paths))
        errors.extend(validate_behavioral_test_diff(
            paths, changed_diff(root, args.base, args.head)
        ))
    if errors:
        for error in errors:
            print(f"generated change-risk error: {error}")
        return 1
    if args.base:
        risk_count = sum(1 for path in paths if is_generated_risk(path))
        print(
            "generated change-risk gate passed: "
            f"changed={len(paths)} risk={risk_count}"
        )
    else:
        print("generated change-risk wiring passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
