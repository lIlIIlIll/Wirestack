#!/usr/bin/env python3
"""Build one pinned TLS provider and execute the M0-016 caller-driven PoC."""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
from pathlib import Path
from typing import Any, Mapping, Sequence

CAP_RE = re.compile(r"^CAP\s+([a-z0-9_]+)=(PASS|FAIL|BLOCKED|NOT_RUN)$", re.M)
METRIC_RE = re.compile(r"^METRIC\s+([a-z0-9_]+)=([0-9]+)$", re.M)
FORBIDDEN_DEP_RE = re.compile(
    r"(?:libssl|libcrypto|libmbedtls|libmbedx509|libtfpsacrypto|libmbedcrypto)"
    r"[^\s/\\]*\.(?:so(?:\.[0-9]+)*|dylib|dll)",
    re.I,
)


class PocError(RuntimeError):
    pass


def sha256_path(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def atomic_json(path: Path, value: Mapping[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as stream:
            json.dump(value, stream, ensure_ascii=False, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
    finally:
        try:
            os.unlink(name)
        except FileNotFoundError:
            pass


def run(command: Sequence[str], *, cwd: Path, log: Path,
        env: Mapping[str, str] | None = None,
        check: bool = True) -> subprocess.CompletedProcess[str]:
    rendered = " ".join(command)
    with log.open("a", encoding="utf-8") as stream:
        stream.write(f"\n$ {rendered}\n")
        stream.flush()
        completed = subprocess.run(
            list(command), cwd=cwd, env=dict(env) if env else None,
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, text=True, errors="replace", check=False,
        )
        stream.write(completed.stdout)
        stream.write(f"\n[exit {completed.returncode}]\n")
    if check and completed.returncode != 0:
        raise PocError(f"command failed ({completed.returncode}): {rendered}")
    return completed


def safe_extract(archive: Path, destination: Path) -> Path:
    destination.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive, "r:*") as tf:
        root = destination.resolve()
        for member in tf.getmembers():
            target = (destination / member.name).resolve()
            if target != root and root not in target.parents:
                raise PocError(f"unsafe archive path: {member.name}")
        tf.extractall(destination, filter="data")
    children = [path for path in destination.iterdir() if path.is_dir()]
    if len(children) != 1:
        raise PocError(f"expected one source directory, found {len(children)}")
    return children[0]


def download(url: str, destination: Path) -> None:
    request = urllib.request.Request(url, headers={"User-Agent": "Wirestack-M0-016/1"})
    with urllib.request.urlopen(request, timeout=120) as response, destination.open("wb") as out:
        shutil.copyfileobj(response, out)


def resolve_git_tag(url: str) -> str:
    headers = {"Accept": "application/vnd.github+json", "User-Agent": "Wirestack-M0-016/1"}
    request = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(request, timeout=30) as response:
        obj = json.load(response)["object"]
    for _ in range(4):
        if obj["type"] == "commit":
            return obj["sha"]
        if obj["type"] != "tag":
            break
        request = urllib.request.Request(obj["url"], headers=headers)
        with urllib.request.urlopen(request, timeout=30) as response:
            obj = json.load(response)["object"]
    raise PocError("unable to peel upstream tag to a commit")


def platform_id() -> str:
    machine = platform.machine().lower()
    if sys.platform.startswith("linux"):
        libc, _ = platform.libc_ver()
        libc = "musl" if "musl" in libc.lower() else "glibc"
        try:
            text = subprocess.run(
                ["ldd", "--version"], stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT, text=True, errors="replace",
                check=False,
            ).stdout.lower()
            libc = "musl" if "musl" in text else "glibc"
        except OSError:
            pass
        arch = "x86_64" if machine in {"amd64", "x86_64"} else machine
        return f"linux-{libc}-{arch}"
    if sys.platform == "darwin":
        return f"macos-{'arm64' if machine in {'arm64', 'aarch64'} else machine}"
    if os.name == "nt":
        return f"windows-{'x86_64' if machine in {'amd64', 'x86_64'} else machine}"
    return f"{sys.platform}-{machine}"


def find_one(root: Path, names: Sequence[str]) -> Path:
    for name in names:
        hits = list(root.rglob(name))
        if hits:
            return hits[0]
    raise PocError(f"missing required file: {names}")


def is_windows() -> bool:
    return os.name == "nt"


def provider_archive_names(provider: str, windows: bool) -> list[list[str]]:
    if provider == "aws-lc":
        return (["ssl.lib", "libssl.lib"], ["crypto.lib", "libcrypto.lib"]) if windows else (
            ["libssl.a"], ["libcrypto.a"])
    if provider == "mbedtls":
        return (["mbedtls.lib"], ["mbedx509.lib"], ["tfpsacrypto.lib", "mbedcrypto.lib"]) if windows else (
            ["libmbedtls.a"], ["libmbedx509.a"], ["libtfpsacrypto.a", "libmbedcrypto.a"])
    return (["libssl.lib", "ssl.lib"], ["libcrypto.lib", "crypto.lib"]) if windows else (
        ["libssl.a"], ["libcrypto.a"])


def find_provider_archives(prefix: Path, provider: str, windows: bool) -> list[Path]:
    return [find_one(prefix, names) for names in provider_archive_names(provider, windows)]


def cmake_runtime_args(windows: bool) -> list[str]:
    return ["-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded"] if windows else []


def source_provider(spec: Mapping[str, Any], work: Path, log: Path) -> tuple[Path, dict[str, Any]]:
    source_root = work / "source"
    source_root.mkdir(parents=True, exist_ok=True)
    if spec["source_kind"] == "git":
        src = source_root / spec["id"]
        git_env = os.environ.copy()
        # Source acquisition must not inherit developer-specific URL rewrites,
        # credentials or aliases. The pinned public HTTPS URL is the evidence
        # boundary and must remain the transport used by this runner.
        git_env["GIT_CONFIG_GLOBAL"] = os.devnull
        run(["git", "init", str(src)], cwd=work, log=log, env=git_env)
        run(["git", "-C", str(src), "remote", "add", "origin", spec["url"]],
            cwd=work, log=log, env=git_env)
        # AWS-LC release commits may require one parent object for Git's shallow
        # traversal. Depth two remains a bounded exact-SHA acquisition while
        # avoiding GitHub's "did not send all necessary objects" depth-one failure.
        run(["git", "-C", str(src), "fetch", "--depth", "2", "origin", spec["commit"]],
            cwd=work, log=log, env=git_env)
        run(["git", "-C", str(src), "checkout", "--detach", "FETCH_HEAD"],
            cwd=work, log=log, env=git_env)
        commit = run(["git", "-C", str(src), "rev-parse", "HEAD"],
                     cwd=work, log=log, env=git_env).stdout.strip()
        if commit != spec["commit"]:
            raise PocError(f"commit mismatch: {commit}")
        tree = run(["git", "-C", str(src), "rev-parse", "HEAD^{tree}"],
                   cwd=work, log=log, env=git_env).stdout.strip()
        digest = hashlib.sha256((commit + "\n" + tree + "\n").encode()).hexdigest()
        return src, {"commit": commit, "tree": tree, "content_sha256": digest, "kind": "git"}

    archive = source_root / Path(spec["url"]).name
    download(spec["url"], archive)
    digest = sha256_path(archive)
    if digest != spec["sha256"]:
        raise PocError(f"archive digest mismatch: {digest}")
    src = safe_extract(archive, source_root / "unpacked")
    commit = spec.get("commit") or resolve_git_tag(spec["commit_resolution_url"])
    return src, {"commit": commit, "content_sha256": digest, "archive": archive.name, "kind": "archive"}


def build_provider(spec: Mapping[str, Any], src: Path, work: Path,
                   log: Path) -> tuple[Path, list[Path]]:
    build = work / "build"
    prefix = work / "prefix"
    jobs = str(max(2, min(os.cpu_count() or 2, 4)))
    pid = spec["id"]
    if pid == "aws-lc":
        run([
            "cmake", "-S", str(src), "-B", str(build), "-GNinja",
            "-DCMAKE_BUILD_TYPE=Release", "-DBUILD_SHARED_LIBS=OFF",
            "-DBUILD_TESTING=OFF", "-DDISABLE_GO=ON",
            *cmake_runtime_args(is_windows()),
            f"-DCMAKE_INSTALL_PREFIX={prefix}",
        ], cwd=work, log=log)
        run(["cmake", "--build", str(build), "--target", "install", "--parallel", jobs], cwd=work, log=log)
        archives = find_provider_archives(prefix, pid, is_windows())
    elif pid == "mbedtls":
        run([
            "cmake", "-S", str(src), "-B", str(build), "-GNinja",
            "-DCMAKE_BUILD_TYPE=Release", "-DENABLE_TESTING=OFF",
            "-DENABLE_PROGRAMS=OFF", "-DUSE_SHARED_MBEDTLS_LIBRARY=OFF",
            *cmake_runtime_args(is_windows()),
            f"-DCMAKE_INSTALL_PREFIX={prefix}",
        ], cwd=work, log=log)
        run(["cmake", "--build", str(build), "--parallel", jobs], cwd=work, log=log)
        run(["cmake", "--install", str(build)], cwd=work, log=log)
        archives = find_provider_archives(prefix, pid, is_windows())
    else:
        env = os.environ.copy()
        configure = [
            "perl", str(src / "Configure")
        ] if is_windows() else [str(src / "Configure")]
        if is_windows():
            configure.append("VC-WIN64A")
        else:
            env["CFLAGS"] = "-O2 -fPIC"
        configure += [
            "no-shared", "no-module", "no-tests", "no-zlib", "no-zstd",
            f"--prefix={prefix}", "--libdir=lib",
        ]
        run(configure, cwd=src, log=log, env=env)
        if is_windows():
            run(["nmake"], cwd=src, log=log, env=env)
            run(["nmake", "install_sw"], cwd=src, log=log, env=env)
        else:
            run(["make", f"-j{jobs}"], cwd=src, log=log, env=env)
            run(["make", "install_sw"], cwd=src, log=log, env=env)
        archives = find_provider_archives(prefix, pid, is_windows())
    return prefix, archives


def generate_fixtures(work: Path, log: Path) -> Path:
    out = work / "fixtures"
    out.mkdir(parents=True, exist_ok=True)
    run([
        "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "2",
        "-sha256", "-subj", "/CN=Wirestack Test CA", "-keyout", str(out / "ca.key"),
        "-out", str(out / "ca.pem"),
    ], cwd=work, log=log)
    (out / "server.ext").write_text(
        "subjectAltName=DNS:localhost\nextendedKeyUsage=serverAuth\n"
        "basicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\n"
    )
    run([
        "openssl", "req", "-newkey", "rsa:2048", "-nodes", "-sha256",
        "-subj", "/CN=localhost", "-keyout", str(out / "server.key"),
        "-out", str(out / "server.csr"),
    ], cwd=work, log=log)
    run([
        "openssl", "x509", "-req", "-in", str(out / "server.csr"), "-CA", str(out / "ca.pem"),
        "-CAkey", str(out / "ca.key"), "-CAcreateserial", "-days", "2", "-sha256",
        "-extfile", str(out / "server.ext"), "-out", str(out / "server.pem"),
    ], cwd=work, log=log)
    (out / "client.ext").write_text(
        "extendedKeyUsage=clientAuth\nbasicConstraints=CA:FALSE\n"
        "keyUsage=digitalSignature,keyEncipherment\n"
    )
    run([
        "openssl", "req", "-newkey", "rsa:2048", "-nodes", "-sha256",
        "-subj", "/CN=wirestack-client", "-keyout", str(out / "client.key"),
        "-out", str(out / "client.csr"),
    ], cwd=work, log=log)
    run([
        "openssl", "x509", "-req", "-in", str(out / "client.csr"), "-CA", str(out / "ca.pem"),
        "-CAkey", str(out / "ca.key"), "-CAcreateserial", "-days", "2", "-sha256",
        "-extfile", str(out / "client.ext"), "-out", str(out / "client.pem"),
    ], cwd=work, log=log)
    return out


def compile_poc(spec: Mapping[str, Any], repo: Path, prefix: Path,
                archives: Sequence[Path], work: Path, log: Path,
                extra_cflags: Sequence[str] = ()) -> Path:
    output = work / ("provider-poc.exe" if is_windows() else "provider-poc")
    include = prefix / "include"
    source = repo / "tools/tls_provider_poc" / (
        "openssl_memory_poc.c" if spec["poc_family"] == "openssl-compatible"
        else "mbedtls_memory_poc.c"
    )
    if is_windows():
        run([
            os.environ.get("CC", "cl"), "/nologo", "/std:c11", "/O2", "/W3", "/WX",
            "/MT", "/D_CRT_SECURE_NO_WARNINGS", f"/I{include}", *extra_cflags,
            str(source), *[str(archive) for archive in archives],
            "bcrypt.lib", "crypt32.lib", "advapi32.lib", "user32.lib", "ws2_32.lib",
            f"/Fe:{output}",
        ], cwd=work, log=log)
        return output
    if spec["poc_family"] == "openssl-compatible":
        obj = work / "poc.o"
        run([
            os.environ.get("CC", "cc"), "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
            f"-I{include}", *extra_cflags, "-c", str(source), "-o", str(obj),
        ], cwd=work, log=log)
        command = [os.environ.get("CXX", "c++"), str(obj), *[str(a) for a in archives], "-pthread", "-lm"]
        if sys.platform.startswith("linux"):
            command.append("-ldl")
        command += ["-o", str(output)]
        run(command, cwd=work, log=log)
    else:
        run([
            os.environ.get("CC", "cc"), "-std=c99", "-O2", "-Wall", "-Wextra", "-Werror",
            f"-I{include}", str(source), *[str(a) for a in archives], "-pthread", "-lm",
            "-o", str(output),
        ], cwd=work, log=log)
    return output


def inspect_binary(binary: Path, archives: Sequence[Path], work: Path, log: Path) -> dict[str, Any]:
    dependencies: list[str] = []
    if is_windows():
        completed = run(["dumpbin", "/dependents", str(binary)], cwd=work, log=log, check=False)
        if completed.returncode != 0:
            raise PocError("dumpbin dependency inspection failed")
        dependencies = sorted(set(FORBIDDEN_DEP_RE.findall(completed.stdout)))
    elif sys.platform.startswith("linux"):
        completed = run(["ldd", str(binary)], cwd=work, log=log, check=False)
        dependencies = sorted(set(FORBIDDEN_DEP_RE.findall(completed.stdout)))
    elif sys.platform == "darwin":
        completed = run(["otool", "-L", str(binary)], cwd=work, log=log, check=False)
        if completed.returncode != 0:
            raise PocError("otool dependency inspection failed")
        dependencies = sorted(set(FORBIDDEN_DEP_RE.findall(completed.stdout)))
    data = binary.read_bytes()
    forbidden_strings = sorted(set(FORBIDDEN_DEP_RE.findall(data.decode("latin-1", errors="ignore"))))
    return {
        "binary_bytes": binary.stat().st_size,
        "binary_sha256": sha256_path(binary),
        "static_archives": [
            {"name": archive.name, "bytes": archive.stat().st_size, "sha256": sha256_path(archive)}
            for archive in archives
        ],
        "system_tls_dependencies": dependencies,
        "runtime_loader_library_strings": forbidden_strings,
    }


def parse_caps(stdout: str, required: Sequence[str]) -> dict[str, str]:
    caps = dict(CAP_RE.findall(stdout))
    missing = set(required) - set(caps)
    extra = set(caps) - set(required)
    if missing or extra:
        raise PocError(f"capability output mismatch missing={sorted(missing)} extra={sorted(extra)}")
    return caps


def parse_metrics(stdout: str, provider: str, caps: Mapping[str, str]) -> dict[str, int]:
    metrics = {name: int(value) for name, value in METRIC_RE.findall(stdout)}
    if metrics.get("repeated_cleanup_cycles") != 10000:
        raise PocError("PoC did not execute exactly 10,000 repeated cleanup cycles")
    if provider == "aws-lc" and caps.get("external_signer") == "PASS":
        if metrics.get("external_signer_calls", 0) < 2:
            raise PocError("AWS-LC external signer did not serve both TLS versions")
    return metrics


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    repo_default = Path(__file__).resolve().parents[2]
    parser.add_argument("--repo", type=Path, default=repo_default)
    parser.add_argument("--provider", required=True, choices=["aws-lc", "mbedtls", "openssl"])
    parser.add_argument("--work-dir", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args(argv)

    repo = args.repo.resolve()
    spec_all = json.loads((repo / "tools/tls_provider_poc/providers.json").read_text())
    spec = next(provider for provider in spec_all["providers"] if provider["id"] == args.provider)
    work = (args.work_dir or repo / "build/tls-provider-poc" / args.provider).resolve()
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True)
    output = (args.output or work / "result.json").resolve()
    log = work / "build.log"
    started = dt.datetime.now(dt.timezone.utc)
    result: dict[str, Any] = {
        "schema_version": 2,
        "task_id": "M0-016",
        "provider": args.provider,
        "platform": platform_id(),
        "status": "FAIL",
        "started_at": started.isoformat(),
        "execution": {
            "repository_revision": os.environ.get("GITHUB_SHA", ""),
            "runner_os": os.environ.get("RUNNER_OS", platform.system()),
            "runner_arch": os.environ.get("RUNNER_ARCH", platform.machine()),
            "image_os": os.environ.get("ImageOS", ""),
            "image_version": os.environ.get("ImageVersion", ""),
            "python": platform.python_version(),
        },
        "source": {},
        "capabilities": {name: "NOT_RUN" for name in spec_all["required_capabilities"]},
        "build": {"static_archives": [], "system_tls_dependencies": []},
        "notes": [
            "System openssl CLI is used only to generate ephemeral test certificates; "
            "the PoC executable is linked against vendored static provider archives."
        ],
    }
    try:
        src, source_info = source_provider(spec, work, log)
        result["source"] = source_info
        prefix, archives = build_provider(spec, src, work, log)
        fixtures = generate_fixtures(work, log)
        binary = compile_poc(spec, repo, prefix, archives, work, log)
        result["build"] = inspect_binary(binary, archives, work, log)
        completed = run([
            str(binary), str(fixtures / "server.pem"), str(fixtures / "server.key"),
            str(fixtures / "ca.pem"), str(fixtures / "client.pem"), str(fixtures / "client.key"),
        ], cwd=work, log=log, check=False)
        result["poc_exit_code"] = completed.returncode
        result["capabilities"] = parse_caps(completed.stdout, spec_all["required_capabilities"])
        result["metrics"] = parse_metrics(
            completed.stdout, args.provider, result["capabilities"])
        failed = [name for name, status in result["capabilities"].items() if status == "FAIL"]
        blocked = [name for name, status in result["capabilities"].items() if status == "BLOCKED"]
        forbidden = result["build"]["system_tls_dependencies"] or result["build"]["runtime_loader_library_strings"]
        if completed.returncode != 0 or failed or forbidden:
            result["status"] = "FAIL"
        elif blocked:
            result["status"] = "PARTIAL"
        else:
            result["status"] = "PASS"
    except Exception as error:
        result["error"] = f"{type(error).__name__}: {error}"
        result["status"] = "FAIL"
    result["finished_at"] = dt.datetime.now(dt.timezone.utc).isoformat()
    result["build_log_sha256"] = sha256_path(log) if log.exists() else None
    atomic_json(output, result)
    print("WIRESTACK_M0_016 " + json.dumps({
        "provider": result["provider"],
        "platform": result["platform"],
        "status": result["status"],
        "capabilities": result["capabilities"],
        "result_sha256": sha256_path(output),
    }, sort_keys=True))
    return 0 if result["status"] in {"PASS", "PARTIAL"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
