#!/usr/bin/env python3
"""Run the one-shot json4cj/yjson/Jackson T9 comparison used by this repository.

The script keeps the repository untouched: it creates isolated local and
Server copies, builds the two libraries, runs the 22 primary T9.1-T9.4 cases,
retrieves raw evidence, and writes the three-way comparison.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import shlex
import subprocess


SCRIPT_DIR = Path(__file__).resolve().parent


def run(command: list[str], *, cwd: Path | None = None, dry_run: bool = False) -> str:
    rendered = shlex.join(command)
    print(f"+ {rendered}", flush=True)
    if dry_run:
        return ""
    try:
        return subprocess.run(
            command,
            cwd=cwd,
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        ).stdout.strip()
    except subprocess.CalledProcessError as error:
        if error.stdout:
            print(error.stdout, flush=True)
        raise


def ssh(server: str, command: str, *, dry_run: bool = False) -> str:
    return run(["ssh", server, command], dry_run=dry_run)


def source_digest(root: Path) -> str:
    digest = hashlib.sha256()
    for path in sorted(p for p in root.rglob("*") if p.is_file()):
        relative = path.relative_to(root)
        if any(part in {"target", ".git", "__pycache__"} for part in relative.parts):
            continue
        digest.update(str(relative).encode())
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def git_capture(root: Path, *args: str) -> str | None:
    try:
        return subprocess.run(
            ["git", "-C", str(root), *args],
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        ).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return None


def remote_env(sdk: str) -> str:
    q = shlex.quote(sdk)
    return (
        f"sdk={q}; . \"$sdk/envsetup.sh\"; export PATH=\"$sdk/tools/bin:$PATH\"; "
        'export CANGJIE_STDX_PATH="$sdk/linux_x86_64_cjnative/dynamic/stdx"; '
        'export CJ_SDK_LIBPATH="$CANGJIE_STDX_PATH:$sdk/runtime/lib/linux_x86_64_cjnative:$sdk/tools/lib"; '
        'export LD_LIBRARY_PATH="$CJ_SDK_LIBPATH:${LD_LIBRARY_PATH:-}"; '
        "export cjHeapSize=128MB"
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--yjson-root", type=Path, required=True,
                        help="local yjson checkout to benchmark")
    parser.add_argument("--server", required=True,
                        help="SSH host running the comparison cells")
    parser.add_argument(
        "--server-sdk", required=True,
        help="Server-local SDK root (linux_release_x86_64 layout)",
    )
    parser.add_argument("--json4cj-url", default="https://gitcode.com/L_lipo/json4cj")
    parser.add_argument("--json4cj-branch", default="main")
    parser.add_argument("--jackson-version", default="2.17.2")
    parser.add_argument("--daily-sdk-root", type=Path, required=True,
        help="local daily SDK root containing cangjie/ and linux_x86_64_cjnative/")
    parser.add_argument("--cpu", type=int, default=8)
    parser.add_argument("--runs", type=int, default=1)
    parser.add_argument("--remote-workdir", help="fresh Server directory; default uses mktemp")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    if args.runs != 1:
        parser.error("this comparison contract requires --runs 1")

    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error(f"output directory is not empty: {output}")
    if not args.dry_run:
        output.mkdir(parents=True)
    local_copy = output / "work" / "yjson"
    corpus = output / "work" / "corpus"
    if not args.dry_run:
        local_copy.parent.mkdir(parents=True)

    remote = args.remote_workdir
    if not remote:
        remote = "<remote-workdir>" if args.dry_run else ssh(
            args.server, "mktemp -d /tmp/yjson-t9-threeway-XXXXXXXX", dry_run=False
        )
    print(f"remote workdir: {remote}")

    excludes = [
        "--exclude=.git", "--exclude=target", "--exclude=build-script-cache",
        "--exclude=__pycache__",
        "--exclude=*.o", "--exclude=*.a", "--exclude=*.so",
    ]
    run(["rsync", "-a", *excludes, f"{args.yjson_root.resolve()}/", f"{local_copy}/"], dry_run=args.dry_run)
    run(["rsync", "-a", *excludes, f"{args.yjson_root.resolve()}/", f"{args.server}:{remote}/yjson-msgc/"], dry_run=args.dry_run)
    run(["rsync", "-a", *excludes, f"{args.yjson_root.resolve()}/", f"{args.server}:{remote}/yjson-daily/"], dry_run=args.dry_run)
    for name in ("run_t9_throughput.py", "run_t9_jackson.py",
                 "prepare_t9_yjson_copy.py", "prepare_t9_json4cj_copy.py"):
        run(["rsync", "-a", str(SCRIPT_DIR / name), f"{args.server}:{remote}/{name}"], dry_run=args.dry_run)

    if not args.dry_run:
        corpus.mkdir(parents=True)
        for name in ("records-64k.json", "records-1m.json"):
            (corpus / name).write_text("[]\n", encoding="utf-8")
    run(["rsync", "-a", f"{corpus}/", f"{args.server}:{remote}/corpus/"], dry_run=args.dry_run)
    run(["rsync", "-a", f"{args.daily_sdk_root.resolve()}/", f"{args.server}:{remote}/daily-sdk/"], dry_run=args.dry_run)

    ssh(args.server,
        f"python3 {shlex.quote(remote + '/prepare_t9_yjson_copy.py')} "
        f"{shlex.quote(remote + '/yjson-msgc')} --msgc-sdk-workarounds --native-accel && "
        f"python3 {shlex.quote(remote + '/prepare_t9_yjson_copy.py')} "
        f"{shlex.quote(remote + '/yjson-daily')} --native-accel",
        dry_run=args.dry_run)
    ssh(args.server,
        f"git clone --branch {shlex.quote(args.json4cj_branch)} --single-branch "
        f"{shlex.quote(args.json4cj_url)} {shlex.quote(remote + '/json4cj')} && "
        f"python3 {shlex.quote(remote + '/prepare_t9_json4cj_copy.py')} {shlex.quote(remote + '/json4cj')}",
        dry_run=args.dry_run)
    json4cj_sha = "<dry-run>" if args.dry_run else ssh(
        args.server,
        f"git -C {shlex.quote(remote + '/json4cj')} rev-parse HEAD",
    )
    jackson_dir = remote + "/jackson-" + args.jackson_version
    jackson_base = (
        "https://repo1.maven.org/maven2/com/fasterxml/jackson/core"
    )
    ssh(args.server,
        f"set -e; mkdir -p {shlex.quote(jackson_dir)}; "
        f"curl -fsSL --retry 3 -o {shlex.quote(jackson_dir + '/jackson-core.jar')} "
        f"{shlex.quote(jackson_base + '/jackson-core/' + args.jackson_version + '/jackson-core-' + args.jackson_version + '.jar')}; "
        f"curl -fsSL --retry 3 -o {shlex.quote(jackson_dir + '/jackson-databind.jar')} "
        f"{shlex.quote(jackson_base + '/jackson-databind/' + args.jackson_version + '/jackson-databind-' + args.jackson_version + '.jar')}; "
        f"curl -fsSL --retry 3 -o {shlex.quote(jackson_dir + '/jackson-annotations.jar')} "
        f"{shlex.quote(jackson_base + '/jackson-annotations/' + args.jackson_version + '/jackson-annotations-' + args.jackson_version + '.jar')}",
        dry_run=args.dry_run)

    env = remote_env(args.server_sdk)
    ssh(args.server,
        f"set -e; {env}; cd {shlex.quote(remote + '/yjson-msgc/packages/benchmarks')}; "
        "python3 ../../scripts/build_native_scanner.py --out-dir target/native; "
        "cjpm bench --cfg --skip-script --no-run --no-color --filter T9ThroughputBench",
        dry_run=args.dry_run)
    daily_root = remote + "/daily-sdk"
    daily_env = remote_env(daily_root + "/cangjie").replace(
        '$sdk/linux_x86_64_cjnative/dynamic/stdx',
        daily_root + '/linux_x86_64_cjnative/dynamic/stdx',
    )
    ssh(args.server,
        f"set -e; {daily_env}; export YJSON_CROSSLANG_CORPUS_DIR={shlex.quote(remote + '/corpus')}; "
        f"cd {shlex.quote(remote + '/yjson-daily/packages/benchmarks')}; "
        "python3 ../../scripts/build_native_scanner.py --out-dir target/native; "
        "cjpm bench --no-run --no-color --filter T9ThroughputBench",
        dry_run=args.dry_run)
    ssh(args.server,
        f"set -e; {env}; cd {shlex.quote(remote + '/json4cj/json4cj-databind')}; "
        "cjpm bench --cfg --no-run --no-color --filter T9ThroughputBench",
        dry_run=args.dry_run)

    for library, cwd, run_env, extra in (
        ("yjson-server-daily", remote + "/yjson-daily/packages/benchmarks", daily_env, ""),
        ("yjson-server-sdk", remote + "/yjson-msgc/packages/benchmarks", env, "--cfg --skip-script"),
        ("json4cj-server-sdk", remote + "/json4cj/json4cj-databind", env, "--cfg"),
    ):
        ssh(args.server,
            f"set -e; {run_env}; export YJSON_CROSSLANG_CORPUS_DIR={shlex.quote(remote + '/corpus')}; "
            f"python3 {shlex.quote(remote + '/run_t9_throughput.py')} "
            f"{shlex.quote(remote + '/results/' + library)} --cwd {shlex.quote(cwd)} "
            f"--runs 1 --cpu {args.cpu} --label {library} {extra}",
            dry_run=args.dry_run)
    ssh(args.server,
        f"python3 {shlex.quote(remote + '/run_t9_jackson.py')} "
        f"{shlex.quote(remote + '/results/jackson-server')} "
        f"--source {shlex.quote(remote + '/json4cj/docs/jackson-bench/JacksonBench.java')} "
        f"--jars-dir {shlex.quote(jackson_dir)} --version {shlex.quote(args.jackson_version)} "
        f"--cpu {args.cpu} --label jackson-server",
        dry_run=args.dry_run)

    run(["rsync", "-a", f"{args.server}:{remote}/results/", f"{output}/server/"], dry_run=args.dry_run)
    if not args.dry_run:
        # SDK identity is recorded as version/digest, never as a personal
        # absolute path. The daily SDK is uploaded into the run workdir and
        # hashed there; the server SDK is hashed on the run host.
        daily_sdk_digest = None
        try:
            daily_sdk_digest = ssh(
                args.server,
                f"cd {shlex.quote(remote + '/daily-sdk')} && "
                "sha256sum cangjie/bin/cjc cangjie/tools/bin/cjpm 2>/dev/null",
            )
        except Exception:
            pass
        server_sdk_digest = None
        try:
            server_sdk_digest = ssh(
                args.server,
                f"cd {shlex.quote(args.server_sdk)} && "
                "sha256sum bin/cjc tools/bin/cjpm 2>/dev/null",
            )
        except Exception:
            pass
        server_cjc = None
        try:
            server_cjc = ssh(args.server,
                             f". {shlex.quote(args.server_sdk + '/envsetup.sh')} >/dev/null 2>&1; "
                             "cjc -v 2>/dev/null | head -3")
        except Exception:
            pass
        provenance = {
            "yjson_source_sha256": source_digest(local_copy),
            "yjson_git_head": git_capture(args.yjson_root.resolve(), "rev-parse", "HEAD"),
            "yjson_git_status_porcelain": git_capture(
                args.yjson_root.resolve(), "status", "--porcelain=v1"
            ),
            "json4cj_url": args.json4cj_url,
            "json4cj_branch": args.json4cj_branch,
            "json4cj_git_head": json4cj_sha,
            "jackson_version": args.jackson_version,
            "server": args.server,
            "server_sdk_cjc_version": server_cjc,
            "server_sdk_digest": server_sdk_digest,
            "daily_sdk_uploaded_digest": daily_sdk_digest,
            "runs": 1,
            "cpu": args.cpu,
            "remote_workdir": remote,
        }
        (output / "provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
        run([
            "python3", str(SCRIPT_DIR / "summarize_t9_three_way.py"),
            "--json4cj-server", str(output / "server/json4cj-server-sdk"),
            "--yjson-server", str(output / "server/yjson-server-sdk"),
            "--yjson-server-daily", str(output / "server/yjson-server-daily"),
            "--jackson-server", str(output / "server/jackson-server"),
            "--output", str(output / "comparison"),
        ])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
