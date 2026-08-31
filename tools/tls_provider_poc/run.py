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
    r"(?:"
    r"(?:lib)?(?:mbedtls|mbedx509|tfpsacrypto|mbedcrypto)[^\s/\\]*"
    r"\.(?:so(?:\.[0-9]+)*|dylib|dll)"
    r"|lib(?:ssl|crypto)[^\s/\\]*\.(?:so(?:\.[0-9]+)*|dylib|dll)"
    r"|(?:ssl|crypto)[^\s/\\]*\.dll"
    r")",
    re.I,
)
MAX_EXPORTED_SYMBOLS = 16384
MAX_EXPORTED_SYMBOL_LENGTH = 256
MAX_LICENSE_FILES = 512
MAX_LICENSE_FILE_BYTES = 512 * 1024
MAX_LICENSE_TOTAL_BYTES = 8 * 1024 * 1024
MEMORY_PROFILE_BOUND_BYTES = 512 * 1024 * 1024
PROVIDER_ALLOCATION_PROFILE_BOUND_BYTES = 64 * 1024 * 1024 * 1024
PROVIDER_ALLOCATION_CALL_BOUND = 100_000_000
CANCELLATION_WAKE_BOUND_US = 250_000
RESULT_SCHEMA_VERSION = 6
MAX_TOOL_VERSION_BYTES = 16 * 1024


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
    return [
        "-DCMAKE_POLICY_DEFAULT_CMP0091=NEW",
        "-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded",
    ] if windows else []


def mbedtls_runtime_args(windows: bool) -> list[str]:
    return ["-DMSVC_STATIC_RUNTIME=ON"] if windows else []


def mbedtls_profile_config(repo: Path) -> Path:
    return repo / "tools/tls_provider_poc/mbedtls_provider_profile_config.h"


def target_triple(current_platform: str) -> str:
    triples = {
        "linux-glibc-x86_64": "x86_64-unknown-linux-gnu",
        "linux-musl-x86_64": "x86_64-unknown-linux-musl",
        "windows-x86_64": "x86_64-pc-windows-msvc",
        "macos-arm64": "arm64-apple-darwin",
    }
    try:
        return triples[current_platform]
    except KeyError as error:
        raise PocError(f"unsupported native provider target: {current_platform}") from error


def normalized_argv(command: Sequence[str], replacements: Mapping[Path, str]) -> list[str]:
    normalized: list[str] = []
    ordered = sorted(
        ((str(path.resolve()), marker) for path, marker in replacements.items()),
        key=lambda item: len(item[0]), reverse=True,
    )
    for argument in command:
        value = str(argument)
        for raw_path, marker in ordered:
            value = value.replace(raw_path, marker)
            value = value.replace(raw_path.replace("\\", "/"), marker)
        normalized.append(value)
    return normalized


def tool_identity(command: Sequence[str], *, cwd: Path, log: Path) -> dict[str, Any]:
    completed = run(command, cwd=cwd, log=log, check=False)
    output = completed.stdout.strip()
    encoded = output.encode("utf-8")
    if not output or len(encoded) > MAX_TOOL_VERSION_BYTES:
        raise PocError(f"tool identity output is missing or exceeds its bound: {command[0]}")
    return {
        "argv": list(command),
        "exit_code": completed.returncode,
        "output": output,
        "output_sha256": hashlib.sha256(encoded).hexdigest(),
    }


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


def is_license_file(path: Path) -> bool:
    name = path.name.lower()
    return name.startswith(("license", "copying", "notice", "copyright"))


def create_license_bundle(src: Path, output_dir: Path, provider: str,
                          source_info: Mapping[str, Any]) -> dict[str, Any]:
    bundle = output_dir / "license-bundle"
    shutil.rmtree(bundle, ignore_errors=True)
    files_root = bundle / "files"
    entries: list[dict[str, Any]] = []
    total_bytes = 0
    candidates = sorted(
        path for path in src.rglob("*")
        if path.is_file() and not path.is_symlink()
        and ".git" not in path.relative_to(src).parts
        and is_license_file(path)
    )
    if not candidates:
        raise PocError("provider source contains no license files")
    if len(candidates) > MAX_LICENSE_FILES:
        raise PocError("provider license bundle exceeds its file-count bound")
    for path in candidates:
        relative = path.relative_to(src)
        size = path.stat().st_size
        if size > MAX_LICENSE_FILE_BYTES:
            raise PocError("provider license file exceeds its size bound")
        total_bytes += size
        if total_bytes > MAX_LICENSE_TOTAL_BYTES:
            raise PocError("provider license bundle exceeds its total-size bound")
        destination = files_root / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, destination)
        entries.append({
            "path": relative.as_posix(),
            "bytes": size,
            "sha256": sha256_path(path),
        })
    manifest = {
        "schema_version": 1,
        "task_id": "M0-016",
        "provider": provider,
        "source_content_sha256": source_info["content_sha256"],
        "file_count": len(entries),
        "total_bytes": total_bytes,
        "files": entries,
    }
    manifest_path = bundle / "manifest.json"
    atomic_json(manifest_path, manifest)
    return {
        "path": "license-bundle/manifest.json",
        "sha256": sha256_path(manifest_path),
        "file_count": len(entries),
        "total_bytes": total_bytes,
    }


def build_provider(spec: Mapping[str, Any], src: Path, work: Path,
                   log: Path, *, repo: Path | None = None,
                   diagnostic: bool = False) -> tuple[Path, list[Path], dict[str, Any]]:
    repo = (repo or Path(__file__).resolve().parents[2]).resolve()
    build = work / "build"
    prefix = work / "prefix"
    build.mkdir(parents=True, exist_ok=True)
    jobs = str(max(2, min(os.cpu_count() or 2, 4)))
    pid = spec["id"]
    sanitizer_flags = "-O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer"
    if diagnostic and pid == "aws-lc" and sys.platform.startswith("linux"):
        # GCC reports false-positive array-bounds diagnostics while compiling
        # AWS-LC 5.5.0's generated ML-DSA amalgamation. Keep every other AWS-LC
        # warning fatal while preserving sanitizer instrumentation.
        sanitizer_flags += " -Wno-error=array-bounds"
    cmake_diagnostic_args = [
        f"-DCMAKE_C_FLAGS={sanitizer_flags}",
        f"-DCMAKE_CXX_FLAGS={sanitizer_flags}",
        "-DCMAKE_EXE_LINKER_FLAGS=-fsanitize=address,undefined",
    ] if diagnostic else []
    configure_command: list[str]
    build_commands: list[list[str]] = []
    environment_overrides: dict[str, str] = {}
    if pid == "aws-lc":
        configure_command = [
            "cmake", "-S", str(src), "-B", str(build), "-GNinja",
            f"-DCMAKE_BUILD_TYPE={'RelWithDebInfo' if diagnostic else 'Release'}",
            "-DBUILD_SHARED_LIBS=OFF",
            "-DBUILD_TESTING=OFF", "-DDISABLE_GO=ON",
            *(["-DOPENSSL_NO_ASM=ON"] if diagnostic else []),
            *cmake_diagnostic_args,
            *cmake_runtime_args(is_windows()),
            f"-DCMAKE_INSTALL_PREFIX={prefix}",
        ]
        build_commands = [[
            "cmake", "--build", str(build), "--target", "install",
            "--parallel", jobs,
        ]]
        run(configure_command, cwd=work, log=log)
        for command in build_commands:
            run(command, cwd=work, log=log)
        archives = find_provider_archives(prefix, pid, is_windows())
    elif pid == "mbedtls":
        profile_config = mbedtls_profile_config(repo)
        configure_command = [
            "cmake", "-S", str(src), "-B", str(build), "-GNinja",
            f"-DCMAKE_BUILD_TYPE={'RelWithDebInfo' if diagnostic else 'Release'}",
            "-DENABLE_TESTING=OFF",
            "-DENABLE_PROGRAMS=OFF", "-DUSE_SHARED_MBEDTLS_LIBRARY=OFF",
            f"-DTF_PSA_CRYPTO_USER_CONFIG_FILE={profile_config.as_posix()}",
            *cmake_diagnostic_args,
            *cmake_runtime_args(is_windows()),
            *mbedtls_runtime_args(is_windows()),
            f"-DCMAKE_INSTALL_PREFIX={prefix}",
        ]
        build_commands = [
            ["cmake", "--build", str(build), "--parallel", jobs],
            ["cmake", "--install", str(build)],
        ]
        run(configure_command, cwd=work, log=log)
        for command in build_commands:
            run(command, cwd=work, log=log)
        archives = find_provider_archives(prefix, pid, is_windows())
    else:
        env = os.environ.copy()
        configure_command = [
            "perl", str(src / "Configure")
        ] if is_windows() else [str(src / "Configure")]
        if is_windows():
            configure_command.append("VC-WIN64A")
        else:
            environment_overrides = {
                "CFLAGS": f"{sanitizer_flags} -fPIC" if diagnostic else "-O2 -fPIC",
                "CXXFLAGS": sanitizer_flags if diagnostic else "-O2",
                "LDFLAGS": "-fsanitize=address,undefined" if diagnostic else "",
            }
            env.update(environment_overrides)
        configure_command += [
            *(["no-asm"] if diagnostic else []),
            "no-shared", "no-module", "no-tests", "no-zlib", "no-zstd",
            f"--prefix={prefix}", "--libdir=lib",
        ]
        run(configure_command, cwd=build, log=log, env=env)
        if is_windows():
            build_commands = [["nmake"], ["nmake", "install_sw"]]
        else:
            build_commands = [["make", f"-j{jobs}"], ["make", "install_sw"]]
        for command in build_commands:
            run(command, cwd=build, log=log, env=env)
        archives = find_provider_archives(prefix, pid, is_windows())

    compiler = os.environ.get("CC", "cl" if is_windows() else "cc")
    cxx = os.environ.get("CXX", "cl" if is_windows() else "c++")
    compiler_args = [compiler, "/Bv"] if is_windows() else [compiler, "--version"]
    cxx_args = [cxx, "/Bv"] if is_windows() else [cxx, "--version"]
    if pid in {"aws-lc", "mbedtls"}:
        build_tool_args = ["ninja", "--version"]
        cmake_identity: dict[str, Any] | None = tool_identity(
            ["cmake", "--version"], cwd=work, log=log)
    else:
        build_tool_args = ["nmake", "/?"] if is_windows() else ["make", "--version"]
        cmake_identity = None
    replacements = {
        src: "<SOURCE>",
        build: "<BUILD>",
        prefix: "<PREFIX>",
        repo: "<REPOSITORY>",
    }
    normalized_environment = {
        key: normalized_argv([value], replacements)[0]
        for key, value in sorted(environment_overrides.items())
        if value
    }
    provenance = {
        "target_triple": target_triple(platform_id()),
        "compiler": tool_identity(compiler_args, cwd=work, log=log),
        "cxx_compiler": tool_identity(cxx_args, cwd=work, log=log),
        "cmake": cmake_identity,
        "build_tool": tool_identity(build_tool_args, cwd=work, log=log),
        "configure_argv": normalized_argv(configure_command, replacements),
        "build_argv": [normalized_argv(command, replacements) for command in build_commands],
        "environment": normalized_environment,
        "patches": [],
        "patch_set_sha256": hashlib.sha256(b"[]\n").hexdigest(),
        "instrumentation": (
            "address+undefined-sanitizer" if diagnostic else "none"
        ),
        "provider_instrumented": diagnostic,
    }
    return prefix, archives, provenance


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
    (out / "index.txt").write_text("", encoding="utf-8")
    (out / "serial").write_text("1000\n", encoding="utf-8")
    (out / "certs").mkdir()
    (out / "ca.cnf").write_text(
        "[ca]\n"
        "default_ca=wirestack_ca\n"
        "[wirestack_ca]\n"
        "database=index.txt\n"
        "new_certs_dir=certs\n"
        "certificate=ca.pem\n"
        "private_key=ca.key\n"
        "serial=serial\n"
        "default_md=sha256\n"
        "default_days=2\n"
        "policy=wirestack_policy\n"
        "[wirestack_policy]\n"
        "commonName=supplied\n"
        "[server_cert]\n"
        "subjectAltName=DNS:localhost\n"
        "extendedKeyUsage=serverAuth\n"
        "basicConstraints=CA:FALSE\n"
        "keyUsage=digitalSignature,keyEncipherment\n",
        encoding="utf-8",
    )
    run([
        "openssl", "ca", "-batch", "-config", "ca.cnf",
        "-in", "server.csr", "-out", "expired.pem",
        "-startdate", "20000101000000Z", "-enddate", "20000102000000Z",
        "-extensions", "server_cert",
    ], cwd=out, log=log)
    (out / "malformed.pem").write_text(
        "-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----\n",
        encoding="ascii",
    )
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
                extra_cflags: Sequence[str] = (), diagnostic: bool = False) -> Path:
    if diagnostic and is_windows():
        raise PocError("sanitizer diagnostic is unsupported on this Windows toolchain")
    work.mkdir(parents=True, exist_ok=True)
    stem = "provider-poc-diagnostic" if diagnostic else "provider-poc"
    output = work / (f"{stem}.exe" if is_windows() else stem)
    include = prefix / "include"
    source = repo / "tools/tls_provider_poc" / (
        "openssl_memory_poc.c" if spec["poc_family"] == "openssl-compatible"
        else "mbedtls_memory_poc.c"
    )
    mbedtls_definition = (
        f'TF_PSA_CRYPTO_USER_CONFIG_FILE="{mbedtls_profile_config(repo).as_posix()}"'
    )
    if is_windows():
        run([
            os.environ.get("CC", "cl"), "/nologo", "/std:c11", "/O2", "/W3", "/WX",
            "/MT", "/D_CRT_SECURE_NO_WARNINGS",
            *([f"/D{mbedtls_definition}"] if spec.get("id") == "mbedtls" else []),
            f"/I{include}", *extra_cflags,
            str(source), *[str(archive) for archive in archives],
            "bcrypt.lib", "crypt32.lib", "advapi32.lib", "user32.lib", "ws2_32.lib",
            "psapi.lib",
            f"/Fe:{output}",
        ], cwd=work, log=log)
        return output
    if spec["poc_family"] == "openssl-compatible":
        obj = work / ("poc-diagnostic.o" if diagnostic else "poc.o")
        diagnostic_flags = (
            ["-O1", "-g", "-fsanitize=address,undefined", "-fno-omit-frame-pointer"]
            if diagnostic else ["-O2"]
        )
        run([
            os.environ.get("CC", "cc"), "-std=c11", *diagnostic_flags,
            "-Wall", "-Wextra", "-Werror",
            f"-I{include}", *extra_cflags, "-c", str(source), "-o", str(obj),
        ], cwd=work, log=log)
        command = [os.environ.get("CXX", "c++"), str(obj), *[str(a) for a in archives], "-pthread", "-lm"]
        if sys.platform.startswith("linux"):
            command.append("-ldl")
        if diagnostic:
            command.append("-fsanitize=address,undefined")
        command += ["-o", str(output)]
        run(command, cwd=work, log=log)
    else:
        diagnostic_flags = (
            ["-O1", "-g", "-fsanitize=address,undefined", "-fno-omit-frame-pointer"]
            if diagnostic else ["-O2"]
        )
        run([
            os.environ.get("CC", "cc"), "-std=c99", *diagnostic_flags,
            "-Wall", "-Wextra", "-Werror",
            *([f"-D{mbedtls_definition}"] if spec.get("id") == "mbedtls" else []),
            f"-I{include}", str(source), *[str(a) for a in archives], "-pthread", "-lm",
            *(["-fsanitize=address,undefined"] if diagnostic else []),
            "-o", str(output),
        ], cwd=work, log=log)
    return output


def fixture_command(binary: Path, fixtures: Path) -> list[str]:
    return [
        str(binary), str(fixtures / "server.pem"), str(fixtures / "server.key"),
        str(fixtures / "ca.pem"), str(fixtures / "client.pem"),
        str(fixtures / "client.key"), str(fixtures / "expired.pem"),
        str(fixtures / "malformed.pem"),
    ]


def run_native_memory_diagnostic(spec: Mapping[str, Any], repo: Path, src: Path,
                                 work: Path, log: Path,
                                 fixtures: Path, current_platform: str) -> dict[str, Any]:
    if not (current_platform.startswith("linux-glibc-") or
            current_platform.startswith("macos-")):
        return {
            "status": "UNSUPPORTED",
            "tool": "address+undefined-sanitizer",
            "reason": "the selected native toolchain does not provide the configured diagnostic",
        }
    diagnostic_work = work / "diagnostic-provider"
    prefix, archives, provenance = build_provider(
        spec, src, diagnostic_work, log, repo=repo, diagnostic=True)
    binary = compile_poc(
        spec, repo, prefix, archives, diagnostic_work, log, diagnostic=True)
    env = os.environ.copy()
    env["WIRESTACK_POC_DIAGNOSTIC_CYCLES"] = "10"
    leak_detection_supported = (
        spec["id"] == "mbedtls" and
        current_platform.startswith("linux-glibc-")
    )
    env["ASAN_OPTIONS"] = (
        f"detect_leaks={1 if leak_detection_supported else 0}:"
        "halt_on_error=1:abort_on_error=1"
    )
    env["UBSAN_OPTIONS"] = "halt_on_error=1:abort_on_error=1"
    completed = run(
        fixture_command(binary, fixtures), cwd=work, log=log, env=env, check=False)
    if completed.returncode != 0:
        raise PocError("native sanitizer diagnostic failed")
    diagnostic = {
        "status": "PASS",
        "tool": "address+undefined-sanitizer",
        "cleanup_cycles": 10,
        "output_sha256": hashlib.sha256(completed.stdout.encode("utf-8")).hexdigest(),
        "provider_instrumented": True,
        "provider_static_archives": [
            {
                "name": archive.name,
                "bytes": archive.stat().st_size,
                "sha256": sha256_path(archive),
            }
            for archive in archives
        ],
        "provider_build_provenance": provenance,
        "leak_detection": {
            "status": "PASS" if leak_detection_supported else "UNSUPPORTED",
        },
    }
    if spec["id"] == "aws-lc":
        diagnostic["leak_detection"]["reason"] = (
            "AWS-LC 5.5.0 exposes no process-global cleanup API; the bounded "
            "10,000-cycle resident/allocation profile remains mandatory"
        )
    elif spec["id"] == "openssl":
        diagnostic["leak_detection"]["reason"] = (
            "static OpenSSL 3.6.3 retains process-global allocations after "
            "thread and global cleanup; broad allocator suppression is forbidden"
        )
    elif current_platform.startswith("macos-"):
        diagnostic["leak_detection"]["reason"] = (
            "leak detection is unavailable in the configured macOS sanitizer run"
        )
    return diagnostic


def exported_symbol_inventory(binary: Path, work: Path, log: Path) -> dict[str, Any]:
    if is_windows():
        command = ["dumpbin", "/exports", str(binary)]
        tool = "dumpbin /exports"
        pattern = re.compile(
            r"^\s*\d+\s+[0-9A-Fa-f]+\s+[0-9A-Fa-f]+\s+(\S+)\s*$", re.M
        )
    elif sys.platform.startswith("linux"):
        command = ["nm", "-g", "--defined-only", str(binary)]
        tool = "nm -g --defined-only"
        pattern = re.compile(r"^\s*[0-9A-Fa-f]+\s+[A-Za-z]\s+(\S+)\s*$", re.M)
    elif sys.platform == "darwin":
        command = ["nm", "-gU", str(binary)]
        tool = "nm -gU"
        pattern = re.compile(r"^\s*[0-9A-Fa-f]+\s+[A-Za-z]\s+(\S+)\s*$", re.M)
    else:
        raise PocError("unsupported platform for exported-symbol inspection")
    completed = run(command, cwd=work, log=log, check=False)
    if completed.returncode != 0:
        raise PocError("exported-symbol inspection failed")
    if is_windows() and ("Dump of file" not in completed.stdout or
                         "Summary" not in completed.stdout):
        raise PocError("dumpbin export output was not recognized")
    symbols = sorted(set(pattern.findall(completed.stdout)))
    if (len(symbols) > MAX_EXPORTED_SYMBOLS or
            any(len(symbol) > MAX_EXPORTED_SYMBOL_LENGTH for symbol in symbols)):
        raise PocError("exported-symbol inventory exceeds its bound")
    encoded = "".join(f"{symbol}\n" for symbol in symbols).encode("utf-8")
    return {
        "scope": "final-artifact-exports",
        "tool": tool,
        "count": len(symbols),
        "sha256": hashlib.sha256(encoded).hexdigest(),
        "symbols": symbols,
    }


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
        "exported_symbol_inventory": exported_symbol_inventory(binary, work, log),
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
    if caps.get("external_trust") == "PASS" and metrics.get("external_trust_calls", 0) < 4:
        raise PocError("external trust callback did not serve accept/reject on both TLS versions")
    if caps.get("sni_hostname_alpn") == "PASS" and (
        metrics.get("alpn_no_overlap_handshakes") != 2
        or metrics.get("alpn_malformed_inputs_rejected") != 2
    ):
        raise PocError("ALPN evidence did not cover no-overlap and malformed inputs")
    if (caps.get("negative_expired_certificate") == "PASS" and
            caps.get("negative_malformed_certificate") == "PASS" and
            metrics.get("certificate_negative_cases_rejected") != 2):
        raise PocError("certificate evidence did not cover expired and malformed inputs")
    if caps.get("session_resumption") == "PASS" and (
        metrics.get("session_resumption_handshakes") != 4
        or metrics.get("session_resumption_tls12_handshakes") != 2
        or metrics.get("session_resumption_tls13_handshakes") != 2
    ):
        raise PocError("session resumption did not cover TLS 1.2 and TLS 1.3")
    if caps.get("mtls") == "PASS" and (
        metrics.get("mtls_required_handshakes") != 1
        or metrics.get("mtls_optional_handshakes") != 2
    ):
        raise PocError("mTLS evidence did not cover required and optional client authentication")
    if caps.get("caller_cancellation") == "PASS" and (
        metrics.get("cancellation_wakeups") != 1
        or metrics.get("cancellation_bound_us") != CANCELLATION_WAKE_BOUND_US
        or metrics.get("cancellation_latency_us", CANCELLATION_WAKE_BOUND_US + 1)
        > CANCELLATION_WAKE_BOUND_US
    ):
        raise PocError("caller cancellation did not wake a blocked provider wait within its bound")
    peak = metrics.get("memory_profile_peak_resident_bytes", 0)
    if (metrics.get("memory_profile_bound_bytes") != MEMORY_PROFILE_BOUND_BYTES
            or peak <= 0 or peak > MEMORY_PROFILE_BOUND_BYTES):
        raise PocError("native memory profile exceeded or omitted its resident bound")
    allocated = metrics.get("provider_allocation_bytes", 0)
    if (metrics.get("provider_allocation_bound_bytes") !=
            PROVIDER_ALLOCATION_PROFILE_BOUND_BYTES
            or metrics.get("provider_allocation_call_bound") !=
            PROVIDER_ALLOCATION_CALL_BOUND
            or metrics.get("provider_allocation_calls", 0) <= 0
            or metrics.get("provider_allocation_calls", 0) >
            PROVIDER_ALLOCATION_CALL_BOUND
            or allocated <= 0 or allocated > PROVIDER_ALLOCATION_PROFILE_BOUND_BYTES
            or metrics.get("provider_allocation_peak_live_bytes", 0) <= 0
            or metrics.get("provider_allocation_peak_live_bytes", 0) >
            MEMORY_PROFILE_BOUND_BYTES):
        raise PocError("provider allocation profile exceeded or omitted its bound")
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
    current_platform = platform_id()
    result: dict[str, Any] = {
        "schema_version": RESULT_SCHEMA_VERSION,
        "task_id": "M0-016",
        "provider": args.provider,
        "platform": current_platform,
        "status": "FAIL",
        "started_at": started.isoformat(),
        "execution": {
            "repository_revision": os.environ.get("GITHUB_SHA", ""),
            "runner_os": os.environ.get("RUNNER_OS", platform.system()),
            "runner_arch": os.environ.get("RUNNER_ARCH", platform.machine()),
            "image_os": os.environ.get("ImageOS", ""),
            "image_version": os.environ.get("ImageVersion", ""),
            "container_image": os.environ.get("WIRESTACK_CONTAINER_IMAGE", ""),
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
        license_bundle = create_license_bundle(
            src, output.parent, args.provider, source_info)
        prefix, archives, build_provenance = build_provider(
            spec, src, work, log, repo=repo)
        fixtures = generate_fixtures(work, log)
        binary = compile_poc(spec, repo, prefix, archives, work, log)
        result["build"] = inspect_binary(binary, archives, work, log)
        result["build"]["license_bundle"] = license_bundle
        result["build"]["provenance"] = build_provenance
        completed = run(
            fixture_command(binary, fixtures), cwd=work, log=log, check=False)
        result["poc_exit_code"] = completed.returncode
        result["capabilities"] = parse_caps(completed.stdout, spec_all["required_capabilities"])
        result["metrics"] = parse_metrics(
            completed.stdout, args.provider, result["capabilities"])
        diagnostic = run_native_memory_diagnostic(
            spec, repo, src, work, log, fixtures, current_platform)
        result["operational_evidence"] = {
            "native_memory_diagnostic": diagnostic,
            "memory_profile": {
                "method": "native-process-peak-resident-and-provider-allocation-hooks",
                "peak_resident_bytes": result["metrics"]["memory_profile_peak_resident_bytes"],
                "resident_bound_bytes": result["metrics"]["memory_profile_bound_bytes"],
                "provider_allocation_calls": result["metrics"]["provider_allocation_calls"],
                "provider_allocation_call_bound": result["metrics"]["provider_allocation_call_bound"],
                "provider_allocation_bytes": result["metrics"]["provider_allocation_bytes"],
                "provider_allocation_bound_bytes": result["metrics"]["provider_allocation_bound_bytes"],
                "provider_allocation_peak_live_bytes": result["metrics"]["provider_allocation_peak_live_bytes"],
                "payload_bytes_per_transfer": 32768,
            },
            "cancellation": {
                "method": "caller-owned-wait-thread-and-explicit-cancel-signal",
                "wakeups": result["metrics"]["cancellation_wakeups"],
                "latency_us": result["metrics"]["cancellation_latency_us"],
                "bound_us": result["metrics"]["cancellation_bound_us"],
            },
        }
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
