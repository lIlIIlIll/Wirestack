#!/usr/bin/env python3
"""Run the T9 matrix: yjson/cjjson on msgc+daily, json4cj on msgc, plus Jackson.

All measurements run sequentially on one Server over a fresh remote workdir:
22 t9_* cases per cell, single run, CPU-pinned.  yjson is re-prepared from the
Server-local source (an already-prepared candidate; every prepare step is
re-entrant).  json4cj is cloned fresh and pinned.  cjjson is copied from the
Server-local cangjieJSON checkout plus the T9 port from
benchmarks/t9-ports/cjjson.  Jackson runs via the json4cj clone's Java harness.

Failure policy: yjson/msgc/jackson/cjjson-msgc cells are fatal (remote workdir is
retained); cjjson-daily degrades to ABSENT; json4cj-daily is intentionally excluded
(user decision — json4cj needs yjson-flavored std fast-path APIs the daily std lacks).
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import shlex
import subprocess
import sys

SCRIPT_DIR = Path(__file__).resolve().parent

HELPER_SCRIPTS = (
    "run_t9_throughput.py",
    "run_t9_jackson.py",
    "run_t9_jmh.py",
    "prepare_t9_yjson_copy.py",
    "prepare_t9_json4cj_copy.py",
    "prepare_t9_cjjson_copy.py",
)

RSYNC_EXCLUDES = (
    "--exclude=.git --exclude=target --exclude=build-script-cache "
    "--exclude=__pycache__ --exclude='*.o' --exclude='*.a' --exclude='*.so'"
)

PORT_RELATIVE = Path("benchmarks/t9-ports/cjjson/src/test/T9BenchThroughput_test.cj")

CELLS = (
    ("yjson-daily",   "{wd}/yjson-daily/packages/benchmarks", "daily", ("--skip-script",)),
    ("yjson-msgc",    "{wd}/yjson-msgc/packages/benchmarks",  "msgc",  ("--cfg", "--skip-script")),
    ("json4cj-msgc",  "{wd}/json4cj-msgc/json4cj-databind",   "msgc",  ("--cfg", "--skip-script")),
    ("cjjson-daily",  "{wd}/cjjson-daily",                    "daily", ("--skip-script",)),
    ("cjjson-msgc",   "{wd}/cjjson-msgc",                     "msgc",  ("--cfg", "--skip-script")),
)


def run(command: list[str], *, cwd: Path | None = None, dry_run: bool = False) -> str:
    rendered = shlex.join(command)
    print(f"+ {rendered}", flush=True)
    if dry_run:
        return ""
    try:
        return subprocess.run(
            command, cwd=cwd, check=True, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        ).stdout.strip()
    except subprocess.CalledProcessError as error:
        if error.stdout:
            print(error.stdout, flush=True)
        raise


def ssh(server: str, command: str, *, dry_run: bool = False) -> str:
    return run(["ssh", server, command], dry_run=dry_run)


def ssh_step(server: str, command: str, *, description: str, dry_run: bool = False,
             fatal: bool = True) -> bool:
    try:
        ssh(server, command, dry_run=dry_run)
    except Exception as error:  # noqa: BLE001 - degradation contract below
        if fatal:
            print(
                f"FATAL: {description} failed; remote workdir retained for inspection",
                file=sys.stderr,
            )
            raise
        print(f"warning: {description} failed ({error}); cell will be ABSENT", flush=True)
        return False
    return True


def remote_env(sdk: str, *, stdx: str | None = None) -> str:
    q = shlex.quote(sdk)
    stdx = stdx or f"{sdk}/linux_x86_64_cjnative/dynamic/stdx"
    return (
        f"sdk={q}; . \"$sdk/envsetup.sh\"; export PATH=\"$sdk/tools/bin:$sdk/bin:$PATH\"; "
        f"export CANGJIE_STDX_PATH={shlex.quote(stdx)}; "
        'export CJ_SDK_LIBPATH="$CANGJIE_STDX_PATH:$sdk/runtime/lib/linux_x86_64_cjnative:$sdk/tools/lib"; '
        'export LD_LIBRARY_PATH="$CJ_SDK_LIBPATH:${LD_LIBRARY_PATH:-}"; '
        "export cjHeapSize=128MB"
    )


def msgc_env(sdk: str, cjpm_tools_bin: str) -> str:
    """Mirror the proven formal-run msgc env (msgc-env.sh of the T9 threeway run).

    The rebuilt msgc SDK ships no cjpm; cjpm comes from cjpm_tools_bin (the
    tools-SDK) and runs against its own SDK's runtime dirs, while cjc resolves
    to the msgc SDK's bin first.  LD_LIBRARY_PATH therefore lists both SDKs'
    runtime/stdx locations.
    """
    tools_root = str(Path(cjpm_tools_bin).parent.parent)
    stdx = f"{sdk}/linux_x86_64_cjnative/dynamic/stdx"
    ld = (
        f"{sdk}/runtime/lib/linux_x86_64_cjnative:{sdk}/lib/linux_x86_64_cjnative:{stdx}:"
        f"{tools_root}/linux_x86_64_cjnative:{tools_root}/linux_x86_64_cjnative/dynamic/stdx"
    )
    return (
        f"export CANGJIE_HOME={shlex.quote(sdk)}; "
        f"export CANGJIE_SDK_ROOT={shlex.quote(sdk)}; "
        f"export CANGJIE_STDX_PATH={shlex.quote(stdx)}; "
        f"export PATH={shlex.quote(f'{sdk}/bin:{cjpm_tools_bin}:/usr/bin:/bin')}; "
        "export cjHeapSize=128MB; "
        f"export CJ_SDK_LIBPATH={shlex.quote(ld)}; "
        f"export LD_LIBRARY_PATH={shlex.quote(ld)}"
    )


def remote_tree_digest(server: str, root: str) -> str | None:
    """sha256 over the sorted *.cj file digests of a Server-side tree."""
    command = (
        f"cd {shlex.quote(root)} && find . -name '*.cj' -type f -print0 "
        "| sort -z | xargs -0 sha256sum | sha256sum"
    )
    try:
        return ssh(server, command)
    except Exception:
        return None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--server", required=True,
                        help="SSH host running the T9 matrix cells")
    parser.add_argument(
        "--msgc-sdk", required=True,
        help="Server-local msgc comparison SDK root (linux_release_x86_64 layout)",
    )
    parser.add_argument(
        "--daily-sdk-local", type=Path, required=True,
        help="local daily SDK root containing cangjie/ and linux_x86_64_cjnative/; uploaded to --server",
    )
    parser.add_argument(
        "--yjson-source", required=True,
        help="Server-local prepared yjson copy to benchmark",
    )
    parser.add_argument("--json4cj-url", default="https://gitcode.com/L_lipo/json4cj")
    parser.add_argument(
        "--cjpm-tools-bin", required=True,
        help="Server-local tools-SDK bin directory providing cjpm for the msgc cells",
    )
    parser.add_argument("--json4cj-branch", default="main")
    parser.add_argument(
        "--json4cj-pin", default="df204648387cba7d2c7cb9d249557ee741318a99",
        help="verified json4cj commit carrying the T9 port",
    )
    parser.add_argument(
        "--cjjson-source", required=True,
        help="Server-local cangjieJSON checkout",
    )
    parser.add_argument("--jackson-version", default="2.17.2")
    parser.add_argument("--cpu", type=int, default=8)
    parser.add_argument("--remote-workdir", help="fresh Server directory; default uses mktemp")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error(f"output directory is not empty: {output}")
    if not args.dry_run:
        output.mkdir(parents=True)

    remote = args.remote_workdir
    if not remote:
        remote = "<remote-workdir>" if args.dry_run else ssh(
            args.server, "mktemp -d /tmp/yjson-t9-matrix-XXXXXXXX"
        )
    print(f"remote workdir: {remote}")
    wd = remote

    # ---- 1. Upload the daily SDK pair and helper scripts; stage the T9 port.
    run(["rsync", "-a", f"{args.daily_sdk_local.resolve()}/", f"{args.server}:{wd}/daily-sdk/"],
        dry_run=args.dry_run)
    for name in HELPER_SCRIPTS:
        run(["rsync", "-a", str(SCRIPT_DIR / name), f"{args.server}:{wd}/{name}"],
            dry_run=args.dry_run)
    run(["rsync", "-a", str(SCRIPT_DIR.parent / "packages/benchmarks/src/bench_t9_throughput.cj"),
         f"{args.server}:{wd}/yjson-bench_t9_throughput.cj"], dry_run=args.dry_run)
    for rel_remote in (
        (PORT_RELATIVE, "T9BenchThroughput_test.cj"),
        (Path("benchmarks/t9-ports/json4cj/src/test/macros_test/T9BenchThroughput_test.cj"), "json4cj-T9BenchThroughput_test.cj"),
        (Path("benchmarks/t9-ports/jackson/JacksonBench.java"), "JacksonBench.java"),
        (Path("benchmarks/t9-ports/jackson/JacksonBenchJMH.java"), "JacksonBenchJMH.java"),
    ):
        run(["rsync", "-a", str(SCRIPT_DIR.parent / rel_remote[0]),
             f"{args.server}:{wd}/{rel_remote[1]}"], dry_run=args.dry_run)

    # ---- 2. yjson: two Server-local copies, re-entrant prepare, native scanner, build.
    excludes = RSYNC_EXCLUDES
    ssh(args.server,
        f"set -e; rsync -a {excludes} {shlex.quote(args.yjson_source + '/')} "
        f"{shlex.quote(wd + '/yjson-msgc/')}; "
        f"rsync -a {excludes} {shlex.quote(args.yjson_source + '/')} "
        f"{shlex.quote(wd + '/yjson-daily/')}; "
        f"cp {shlex.quote(wd + '/yjson-bench_t9_throughput.cj')} "
        f"{shlex.quote(wd + '/yjson-msgc/packages/benchmarks/src/bench_t9_throughput.cj')}; "
        f"cp {shlex.quote(wd + '/yjson-bench_t9_throughput.cj')} "
        f"{shlex.quote(wd + '/yjson-daily/packages/benchmarks/src/bench_t9_throughput.cj')}",
        dry_run=args.dry_run)
    ssh(args.server,
        f"set -e; python3 {shlex.quote(wd + '/prepare_t9_yjson_copy.py')} "
        f"{shlex.quote(wd + '/yjson-msgc')} --msgc-sdk-workarounds --native-accel && "
        f"python3 {shlex.quote(wd + '/prepare_t9_yjson_copy.py')} "
        f"{shlex.quote(wd + '/yjson-daily')} --native-accel",
        dry_run=args.dry_run)

    env_msgc = msgc_env(args.msgc_sdk, args.cjpm_tools_bin)
    daily_env = remote_env(wd + "/daily-sdk/cangjie",
                           stdx=wd + "/daily-sdk/linux_x86_64_cjnative/dynamic/stdx")
    ssh(args.server,
        f"set -e; {env_msgc}; cd {shlex.quote(wd + '/yjson-msgc/packages/benchmarks')}; "
        "python3 ../../scripts/build_native_scanner.py --out-dir target/native; "
        "cjpm bench --cfg --skip-script --no-run --no-color --filter T9ThroughputBench",
        dry_run=args.dry_run)
    ssh(args.server,
        f"set -e; {daily_env}; cd {shlex.quote(wd + '/yjson-daily/packages/benchmarks')}; "
        "python3 ../../scripts/build_native_scanner.py --out-dir target/native; "
        "cjpm bench --skip-script --no-run --no-color --filter T9ThroughputBench",
        dry_run=args.dry_run)

    # ---- 3. json4cj: clone, pin, two copies, prepare, build.  Degradable.
    json4cj_ok = ssh_step(
        args.server,
        f"set -e; rm -rf {shlex.quote(wd + '/json4cj')}; "
        f"git clone --branch {shlex.quote(args.json4cj_branch)} --single-branch "
        f"{shlex.quote(args.json4cj_url)} {shlex.quote(wd + '/json4cj')} && "
        f"(git -C {shlex.quote(wd + '/json4cj')} checkout {shlex.quote(args.json4cj_pin)} "
        '|| echo "WARN: pin checkout failed; using branch HEAD")',
        description="json4cj clone+pin", dry_run=args.dry_run, fatal=False,
    )
    json4cj_sha: str | None = None
    if json4cj_ok:
        json4cj_sha = ssh(args.server,
                          f"git -C {shlex.quote(wd + '/json4cj')} rev-parse HEAD",
                          dry_run=args.dry_run)
        ssh(args.server,
            f"set -e; rm -rf {shlex.quote(wd + '/json4cj-msgc')}; "
            f"cp -a {shlex.quote(wd + '/json4cj')} {shlex.quote(wd + '/json4cj-msgc')}; "
            f"python3 {shlex.quote(wd + '/prepare_t9_json4cj_copy.py')} "
            f"{shlex.quote(wd + '/json4cj-msgc')}; "
            f"cp {shlex.quote(wd + '/json4cj-T9BenchThroughput_test.cj')} "
            f"{shlex.quote(wd + '/json4cj-msgc/json4cj-databind/src/test/macros_test/T9BenchThroughput_test.cj')}",
            dry_run=args.dry_run)
        ssh(args.server,
            f"set -e; {env_msgc}; cd {shlex.quote(wd + '/json4cj-msgc/json4cj-databind')}; "
            "cjpm bench --cfg --skip-script --no-run --no-color --filter T9ThroughputBench",
            dry_run=args.dry_run)

    # ---- 4. cjjson: two Server-local copies + T9 port, prepare, build.  msgc fatal.
    try:
        ssh(args.server,
            f"set -e; rsync -a {excludes} {shlex.quote(args.cjjson_source + '/')} "
            f"{shlex.quote(wd + '/cjjson-msgc/')}; "
            f"rsync -a {excludes} {shlex.quote(args.cjjson_source + '/')} "
            f"{shlex.quote(wd + '/cjjson-daily/')}; "
            f"cp {shlex.quote(wd + '/T9BenchThroughput_test.cj')} "
            f"{shlex.quote(wd + '/cjjson-msgc/src/test/')}; "
            f"cp {shlex.quote(wd + '/T9BenchThroughput_test.cj')} "
            f"{shlex.quote(wd + '/cjjson-daily/src/test/')}",
            dry_run=args.dry_run)
        ssh(args.server,
            f"set -e; python3 {shlex.quote(wd + '/prepare_t9_cjjson_copy.py')} "
            f"{shlex.quote(wd + '/cjjson-msgc')} --msgc-profile && "
            f"python3 {shlex.quote(wd + '/prepare_t9_cjjson_copy.py')} "
            f"{shlex.quote(wd + '/cjjson-daily')}",
            dry_run=args.dry_run)
        ssh(args.server,
            f"set -e; {env_msgc}; cd {shlex.quote(wd + '/cjjson-msgc')}; "
            "cjpm bench --cfg --skip-script --no-run --no-color --filter T9ThroughputBench",
            dry_run=args.dry_run)
    except Exception:
        print("FATAL: cjjson msgc cell failed; remote workdir retained", file=sys.stderr)
        raise
    cjjson_daily_ok = ssh_step(
        args.server,
        f"set -e; {daily_env}; cd {shlex.quote(wd + '/cjjson-daily')}; "
        "cjpm bench --skip-script --no-run --no-color --filter T9ThroughputBench",
        description="cjjson daily build", dry_run=args.dry_run, fatal=False,
    )

    # ---- 5. Measure the five Cangjie cells (skipping ABSENT ones).
    # json4cj-daily is intentionally excluded (user decision): json4cj at the pinned
    # commit requires yjson-flavored std fast-path APIs that the vanilla daily std
    # does not ship, and no fragment-carrying commit predates that dependency.
    present = {
        "yjson-daily": True, "yjson-msgc": True,
        "json4cj-msgc": json4cj_ok,
        "cjjson-daily": cjjson_daily_ok, "cjjson-msgc": True,
    }
    if not args.dry_run:
        for label, bench_template, sdk, extras in CELLS:
            if not present[label]:
                print(f"skip ABSENT cell: {label}", flush=True)
                continue
            env = env_msgc if sdk == "msgc" else daily_env
            ssh(args.server,
                f"set -e; {env}; rm -rf {shlex.quote(wd + '/results/' + label)}; "
                f"python3 {shlex.quote(wd + '/run_t9_throughput.py')} "
                f"{shlex.quote(wd + '/results/' + label)} "
                f"--cwd {shlex.quote(bench_template.format(wd=wd))} "
                f"--runs 1 --cpu {args.cpu} --label {label} --memory "
                + " ".join(extras),
                dry_run=args.dry_run)
            if label in ("yjson-msgc", "yjson-daily", "json4cj-msgc"):
                bytes_label = label + "-bytes"
                ssh(args.server,
                    f"set -e; {env}; rm -rf {shlex.quote(wd + '/results/' + bytes_label)}; "
                    f"python3 {shlex.quote(wd + '/run_t9_throughput.py')} "
                    f"{shlex.quote(wd + '/results/' + bytes_label)} "
                    f"--cwd {shlex.quote(bench_template.format(wd=wd))} "
                    f"--suite BytesBench "
                    f"--runs 1 --cpu {args.cpu} --label {bytes_label} --memory "
                    + " ".join(extras),
                    dry_run=args.dry_run)

    # ---- 6. Jackson (fatal): jars from Maven Central, Java harness in the json4cj clone.
    jackson_dir = wd + "/jackson-" + args.jackson_version
    jackson_base = "https://repo1.maven.org/maven2/com/fasterxml/jackson/core"
    ssh(args.server,
        f"set -e; mkdir -p {shlex.quote(jackson_dir)}; "
        f"curl -fsSL --retry 3 -o {shlex.quote(jackson_dir + '/jackson-core.jar')} "
        f"{shlex.quote(jackson_base + '/jackson-core/' + args.jackson_version + '/jackson-core-' + args.jackson_version + '.jar')}; "
        f"curl -fsSL --retry 3 -o {shlex.quote(jackson_dir + '/jackson-databind.jar')} "
        f"{shlex.quote(jackson_base + '/jackson-databind/' + args.jackson_version + '/jackson-databind-' + args.jackson_version + '.jar')}; "
        f"curl -fsSL --retry 3 -o {shlex.quote(jackson_dir + '/jackson-annotations.jar')} "
        f"{shlex.quote(jackson_base + '/jackson-annotations/' + args.jackson_version + '/jackson-annotations-' + args.jackson_version + '.jar')}",
        dry_run=args.dry_run)
    ssh(args.server,
        f"set -e; rm -rf {shlex.quote(wd + '/results/jackson')}; "
        f"cp {shlex.quote(wd + '/JacksonBench.java')} "
        f"{shlex.quote(wd + '/json4cj-msgc/docs/jackson-bench/JacksonBench.java')}; "
        f"python3 {shlex.quote(wd + '/run_t9_jackson.py')} "
        f"{shlex.quote(wd + '/results/jackson')} "
        f"--source {shlex.quote(wd + '/json4cj-msgc/docs/jackson-bench/JacksonBench.java')} "
        f"--jars-dir {shlex.quote(jackson_dir)} --version {shlex.quote(args.jackson_version)} "
        f"--cpu {args.cpu} --label jackson --include-bytes",
        dry_run=args.dry_run)

    # ---- 6b. Jackson JMH cell (P2): quantifies the hand-timer deviation.
    jmh_dir = wd + "/jmh-1.37"
    jmh_base = "https://repo1.maven.org/maven2"
    ssh(args.server,
        f"set -e; mkdir -p {shlex.quote(jmh_dir)}; "
        f"curl -fsSL --retry 3 -o {shlex.quote(jmh_dir + '/jmh-core-1.37.jar')} "
        f"{jmh_base}/org/openjdk/jmh/jmh-core/1.37/jmh-core-1.37.jar; "
        f"curl -fsSL --retry 3 -o {shlex.quote(jmh_dir + '/jmh-generator-annprocess-1.37.jar')} "
        f"{jmh_base}/org/openjdk/jmh/jmh-generator-annprocess/1.37/jmh-generator-annprocess-1.37.jar; "
        f"curl -fsSL --retry 3 -o {shlex.quote(jmh_dir + '/jopt-simple-5.0.4.jar')} "
        f"{jmh_base}/net/sf/jopt-simple/jopt-simple/5.0.4/jopt-simple-5.0.4.jar; "
        f"curl -fsSL --retry 3 -o {shlex.quote(jmh_dir + '/commons-math3-3.6.1.jar')} "
        f"{jmh_base}/org/apache/commons/commons-math3/3.6.1/commons-math3-3.6.1.jar",
        dry_run=args.dry_run)
    ssh(args.server,
        f"set -e; python3 {shlex.quote(wd + '/run_t9_jmh.py')} "
        f"{shlex.quote(wd + '/results/jackson-jmh')} "
        f"--source {shlex.quote(wd + '/JacksonBenchJMH.java')} "
        f"--jars-dir {shlex.quote(jackson_dir)} --jmh-jars-dir {shlex.quote(jmh_dir)} "
        f"--legacy-dir {shlex.quote(wd + '/results/jackson')} "
        f"--cpu {args.cpu} --label jackson-jmh",
        dry_run=args.dry_run)

    # ---- 7. Pull results and write provenance.
    run(["rsync", "-a", f"{args.server}:{wd}/results/", f"{output}/server/"], dry_run=args.dry_run)
    if not args.dry_run:
        build_provenance = None
        try:
            build_provenance = ssh(args.server,
                                   f"cat {shlex.quote(args.msgc_sdk + '/BUILD_PROVENANCE.txt')}")
        except Exception:
            pass
        msgc_cjc = None
        try:
            msgc_cjc = ssh(args.server,
                           f". {shlex.quote(args.msgc_sdk + '/envsetup.sh')} >/dev/null 2>&1; "
                           "cjc -v 2>/dev/null | head -3")
        except Exception:
            pass
        daily_cjc = None
        try:
            daily_cjc = ssh(args.server,
                            f". {shlex.quote(wd + '/daily-sdk/cangjie/envsetup.sh')} >/dev/null 2>&1; "
                            "cjc -v 2>/dev/null | head -3")
        except Exception:
            pass
        # SDK identity is recorded as version/digest, never as a personal
        # absolute path. The remote msgc SDK is only available on the run
        # host, so its digest is captured remotely; the daily SDK is uploaded
        # into the run workdir and hashed there.
        msgc_sdk_digest = None
        try:
            msgc_sdk_digest = ssh(
                args.server,
                f"cd {shlex.quote(args.msgc_sdk)} && "
                "sha256sum bin/cjc tools/bin/cjpm 2>/dev/null",
            )
        except Exception:
            pass
        daily_sdk_digest = None
        try:
            daily_sdk_digest = ssh(
                args.server,
                f"cd {shlex.quote(wd + '/daily-sdk')} && "
                "sha256sum cangjie/bin/cjc cangjie/tools/bin/cjpm 2>/dev/null",
            )
        except Exception:
            pass
        provenance = {
            "yjson_source": args.yjson_source,
            "yjson_source_cj_sha256": remote_tree_digest(args.server, args.yjson_source),
            "json4cj_url": args.json4cj_url,
            "json4cj_branch": args.json4cj_branch,
            "json4cj_pin": args.json4cj_pin,
            "json4cj_git_head": json4cj_sha,
            "cjjson_source": args.cjjson_source,
            "cjjson_source_cj_sha256": remote_tree_digest(args.server, args.cjjson_source),
            "msgc_cjc_version": msgc_cjc,
            "msgc_build_provenance": build_provenance,
            "msgc_cjc_path_digest": msgc_sdk_digest,
            "daily_cjc_version": daily_cjc,
            "daily_sdk_uploaded_digest": daily_sdk_digest,
            "jackson_version": args.jackson_version,
            "server": args.server,
            "json4cj_daily_excluded": (
                "user decision: json4cj at the pinned commit requires yjson-flavored "
                "std fast-path APIs absent from the vanilla daily std"
            ),
            "runs": 1,
            "cpu": args.cpu,
            "remote_workdir": wd,
            "absent_cells": [label for label, ok in present.items() if not ok],
        }
        (output / "provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")

        # ---- 8. Summarize the matrix.
        required_missing = [
            name for name in ("jackson", "yjson-msgc", "json4cj-msgc", "cjjson-msgc")
            if not (output / "server" / name / "COMPLETE").is_file()
        ]
        if required_missing:
            print(
                f"matrix incomplete; missing required cells: {', '.join(required_missing)}; "
                "results pulled but no comparison written",
                file=sys.stderr,
            )
            return 1
        command = [
            "python3", str(SCRIPT_DIR / "summarize_t9_matrix.py"),
            "--jackson", str(output / "server/jackson"),
            "--yjson-msgc", str(output / "server/yjson-msgc"),
            "--json4cj-msgc", str(output / "server/json4cj-msgc"),
            "--cjjson-msgc", str(output / "server/cjjson-msgc"),
            "--output", str(output / "comparison"),
        ]
        if (output / "server/jackson-jmh/COMPLETE").is_file():
            command += ["--jackson-jmh", str(output / "server/jackson-jmh")]
        for name in ("yjson-daily", "cjjson-daily", "yjson-msgc-bytes", "yjson-daily-bytes",
                     "json4cj-msgc-bytes", "json4cj-daily-bytes"):
            if (output / "server" / name / "COMPLETE").is_file():
                command += [f"--{name}", str(output / "server" / name)]
        run(command)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
