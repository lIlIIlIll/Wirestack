#!/usr/bin/env python3
"""Capture current Linux development acceptance; never confer release qualification."""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if __package__ in {None, ""}:
    sys.path.insert(0, str(ROOT))

from tools import evidence_digest as digest
from tools import m7_021_linux_release as release
from tools.repository import repository_tooling as repository

TASK = "P1-015"
PROFILE = "linux-current-development-v1"
DEFAULT_REPORT = "docs/evidence/P1-015/baseline.json"
STEPS = ("repository-check", "installed-consumer", "parser-fuzz", "resource-preflight")
RELEASE = {"qualification": "NOT_QUALIFIED", "independent_security_review": "NOT_RUN",
           "candidate_86400_second_soak": "NOT_RUN", "signing": "NOT_AUTHORIZED"}


def require(condition: bool, reason: str) -> None:
    if not condition:
        raise ValueError(reason)


def production_binding(root: Path, revision: str) -> dict:
    require(re.fullmatch(r"[0-9a-f]{40}", revision) is not None, "full source revision required")
    repository._resolve_candidate_commit(root, revision)
    paths = set(release.production_sources(root))
    paths.update(root / name for name in release.QUALIFICATION_INPUTS)
    result = {}
    for path in sorted(paths):
        relative = path.relative_to(root).as_posix()
        original = subprocess.run(["git", "cat-file", "blob", f"{revision}:{relative}"],
                                  cwd=root, capture_output=True, check=True).stdout
        actual = digest.text_evidence_digest(path)
        require(actual == digest.text_evidence_digest_bytes(original), f"source drift: {relative}")
        result[relative] = actual.to_json()
    return result


def execution_inputs(root: Path) -> dict:
    # Historical evidence and planning status are deliberately not executable inputs.
    # Include new/untracked source inputs as well as tracked files.
    paths = {root / name for name in release.QUALIFICATION_INPUTS}
    paths.update(root / name for name in ("docs/product/prd.md", "docs/api/README.md",
                                         "docs/references/m7-033-ci-toolchain.json"))
    for folder in ("src", "native", "tools", "scripts", "fuzz", "third_party", "examples", "docs/guides"):
        for path in (root / folder).rglob("*"):
            if path.is_file() and not any(part in {"__pycache__", "target", "build", "dist", ".cjpm", ".git"}
                                          for part in path.relative_to(root).parts) and path.suffix in (
                "", ".py", ".cj", ".c", ".h", ".json", ".toml", ".sh", ".hex", ".txt", ".md"
            ):
                paths.add(path)
    return {path.relative_to(root).as_posix(): digest.text_evidence_digest(path).to_json()
            for path in sorted(paths)}


def sdk_identity(root: Path, archive: Path) -> dict:
    pin = json.loads((root / "docs/references/m7-033-ci-toolchain.json").read_text())["sdk"]
    identity = digest.artifact_byte_digest(archive)
    require(digest.artifact_byte_sha256_equal(identity.to_json(),
            {"domain": digest.ARTIFACT_BYTE_DOMAIN, "sha256": pin["sha256"]}),
            "SDK archive differs from the qualified pin")
    sdk = Path(os.environ["CANGJIE_HOME"]).resolve()
    for name in ("cjc", "cjpm"):
        executable = shutil.which(name)
        require(executable is not None and Path(executable).resolve().is_relative_to(sdk),
                f"{name} must come from CANGJIE_HOME")
    checked = 0
    with tarfile.open(archive, "r:gz") as bundle:
        for member in bundle:
            parts = Path(member.name).parts
            require(parts and parts[0] == "cangjie" and ".." not in parts, "unexpected SDK archive layout")
            if not member.isfile():
                continue
            target = sdk.joinpath(*parts[1:])
            require(target.resolve().is_relative_to(sdk), "SDK member escapes the selected installation")
            require(target.is_file() and target.stat().st_size == member.size, "installed SDK differs from archive")
            source = bundle.extractfile(member)
            assert source is not None
            with source, target.open("rb") as installed:
                while chunk := source.read(1024 * 1024):
                    require(installed.read(len(chunk)) == chunk, "installed SDK differs from archive")
            checked += 1
    require(checked > 0, "empty SDK archive")
    return {"archive": identity.to_json(), "matched_archive_files": checked,
            "cjc": subprocess.check_output(["cjc", "--version"], text=True).strip(),
            "cjpm": subprocess.check_output(["cjpm", "--version"], text=True).strip()}


def redact(text: str, root: Path) -> str:
    replacements = [(str(root.resolve()), "<repo>"), (str(Path.home()), "$HOME")]
    if os.environ.get("CANGJIE_HOME"):
        replacements.insert(0, (str(Path(os.environ["CANGJIE_HOME"]).resolve()), "<sdk>"))
    for old, new in sorted(replacements, key=lambda pair: len(pair[0]), reverse=True):
        text = text.replace(old, new)
    return re.sub(r"/(?:var/tmp|tmp|home)/[^\s\"'<>]+", "<scratch>", text)


def retain(root: Path, report_dir: Path, name: str, raw: str) -> dict:
    path = report_dir / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(redact(raw, root), encoding="utf-8")
    return {"path": path.relative_to(root).as_posix(),
            "digest": digest.text_evidence_digest(path).to_json()}


def validate_results(report: dict) -> None:
    require(report.get("schema_version") == 1 and report.get("profile") == PROFILE,
            "not a current development baseline")
    require(report.get("source_task") == TASK and report.get("status") == "PASS", "baseline did not pass")
    require(report.get("release") == RELEASE, "development evidence cannot confer release qualification")
    commands = report.get("commands", [])
    require(tuple(item.get("id") for item in commands) == STEPS, "missing or reordered development gates")
    for item in commands:
        require(item.get("status") == "PASS" and item.get("exit_code") == 0
                and item.get("timed_out") is False, "development gate failed or was not run")
    outcomes = report.get("outcomes", {})
    require(outcomes.get("installed_consumer") == "PASS", "installed consumer missing")
    require(outcomes.get("fuzz") == "PASS" and outcomes.get("fuzz_target_count") == 10,
            "complete parser fuzz campaign missing")
    require(outcomes.get("resource_preflight") == "PASS"
            and outcomes.get("preflight_seconds") == 600, "600-second resource preflight missing")
    require(outcomes.get("formal_parameters_met") is False, "short preflight mislabeled as formal soak")


def verify(root: Path, report: dict, archive: Path) -> None:
    validate_results(report)
    require(production_binding(root, report["revision"]) == report["production_sources"], "production inventory drift")
    require(execution_inputs(root) == report["execution_inputs"], "development input inventory drift")
    expected_logs = {f"{step}.{stream}.log" for step in STEPS for stream in ("stdout", "stderr")}
    expected_logs.update(f"{name}.log" for name in ("installation", "fuzz", "preflight", "resource-samples"))
    require(len(report["logs"]) == len(expected_logs)
            and {Path(item["path"]).name for item in report["logs"]} == expected_logs,
            "required captured logs missing or duplicated")
    require(sdk_identity(root, archive) == report["sdk"], "SDK identity drift")
    artifact = repository.safe_path(root, report["artifact"]["path"], "artifact")
    require(digest.artifact_byte_digest(artifact).to_json() == report["artifact"]["digest"], "artifact drift")
    for record in report["logs"]:
        path = repository.safe_path(root, record["path"], "log")
        require(digest.text_evidence_digest(path).to_json() == record["digest"], "captured log drift")


def capture(root: Path, revision: str, archive: Path, output: Path) -> dict:
    output.parent.mkdir(parents=True, exist_ok=True)
    report = {"schema_version": 1, "source_task": TASK, "profile": PROFILE,
              "status": "IN_PROGRESS", "revision": revision, "release": RELEASE,
              "generated_at_utc": repository.utc_now(), "commands": [], "logs": []}
    repository.atomic_json(output, report)
    try:
        report["production_sources"] = production_binding(root, revision)
        report["execution_inputs"] = execution_inputs(root)
        report["sdk"] = sdk_identity(root, archive)
        report["platform"] = release.platform_identity()
        work = root / "build/current-development-baseline"
        work.mkdir(parents=True, exist_ok=True)
        artifact_dir = "dist/p1-015"
        artifact = f"{artifact_dir}/{release.ARTIFACT_NAME}"
        qualification = f"{artifact_dir}/qualification.json"
        fuzz = "build/current-development-baseline/fuzz.json"
        preflight = "build/current-development-baseline/preflight.json"
        raw_log = "build/current-development-baseline/preflight.log"
        soak_entry = ("from tools import m7_022_linux_release_soak as soak; "
                      "import sys; raise SystemExit(soak.main(sys.argv[1:], task_id='P1-015'))")
        steps = [
            (STEPS[0], ["scripts/check"], 3600),
            (STEPS[1], ["python3", "tools/m7_021_linux_release.py", "--root", ".",
                        "--output-dir", artifact_dir, "--offline"], 600),
            (STEPS[2], ["python3", "tools/gates/m7_023_linux_fuzz.py", "--output", fuzz,
                        "--crash-dir", "build/current-development-baseline/crashes"], 1200),
            (STEPS[3], ["python3", "-c", soak_entry, "--preflight", "--duration-seconds", "600",
                        "--application-sample-seconds", "60", "--resource-sample-seconds", "60",
                        "--artifact", artifact, "--qualification", qualification,
                        "--output", preflight, "--raw-log", raw_log], 1200),
        ]
        for name, argv, timeout in steps:
            result = repository.run_command(root, {"id": name, "argv": argv,
                                            "timeout_seconds": timeout}, work)
            for stream in ("stdout", "stderr"):
                raw = (root / result[f"{stream}_path"]).read_text(encoding="utf-8")
                report["logs"].append(retain(root, output.parent, f"commands/{name}.{stream}.log", raw))
            report["commands"].append({key: result[key] for key in (
                "id", "argv", "status", "exit_code", "timed_out", "duration_ms",
                "started_at_utc", "finished_at_utc")})
            require(result["status"] == "PASS", f"development gate failed: {name}")
        installed = json.loads((root / qualification).read_text())
        release.validate_report(installed, root)
        fuzz_report = json.loads((root / fuzz).read_text())
        soak_report = json.loads((root / preflight).read_text())
        report["outcomes"] = {
            "installed_consumer": installed["installation"]["https_client_server_smoke"],
            "fuzz": fuzz_report["decision"], "fuzz_target_count": fuzz_report["target_count"],
            "resource_preflight": soak_report["preflight_status"],
            "preflight_seconds": soak_report["parameters"]["duration_seconds"],
            "formal_parameters_met": soak_report["formal_parameters_met"],
        }
        report["artifact"] = {"path": artifact, "digest": digest.artifact_byte_digest(root / artifact).to_json(),
                              "payload_sha256": installed["artifact"]["payload_sha256"]}
        for name, path in (("installation", qualification), ("fuzz", fuzz), ("preflight", preflight),
                           ("resource-samples", raw_log)):
            report["logs"].append(retain(root, output.parent, f"commands/{name}.log", (root / path).read_text()))
        report["capture_policy"] = (
            "Paths normalized before retained text digests. Embedded producer digests in raw diagnostic "
            "logs describe original scratch inputs, not requalified historical reports. "
            "Production source is commit-bound; current runner/test inputs are separately content-bound."
        )
        report["status"] = "PASS"
        verify(root, report, archive)
    except Exception as error:
        report["status"] = "FAIL"
        report["error"] = redact(str(error), root)
        repository.atomic_json(output, report)
        raise
    repository.atomic_json(output, report)
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("capture", "verify"))
    parser.add_argument("--revision")
    parser.add_argument("--sdk-archive", type=Path, default=os.environ.get("WIRESTACK_BASELINE_SDK_ARCHIVE"))
    parser.add_argument("--report", type=Path, default=ROOT / DEFAULT_REPORT)
    args = parser.parse_args()
    try:
        require(args.sdk_archive is not None, "set WIRESTACK_BASELINE_SDK_ARCHIVE or --sdk-archive")
        output = args.report.resolve()
        require(output.is_relative_to(ROOT), "baseline report must be inside the repository")
        if args.action == "capture":
            require(args.revision is not None, "capture requires --revision")
            capture(ROOT, args.revision, args.sdk_archive, output)
        else:
            verify(ROOT, json.loads(output.read_text()), args.sdk_archive)
        print(f"{TASK} current development baseline: PASS; release NOT_QUALIFIED")
        return 0
    except (ValueError, OSError, KeyError, subprocess.SubprocessError, release.ReleaseError) as error:
        print(redact(f"{TASK} current development baseline: FAIL: {error}", ROOT), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
