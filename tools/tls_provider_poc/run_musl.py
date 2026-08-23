#!/usr/bin/env python3
"""Run M0-016 under musl, with an explicit OpenSSL secure-heap boundary."""
from __future__ import annotations

import importlib.util
import os
import sys
from pathlib import Path

MODULE_PATH = Path(__file__).resolve().with_name("run.py")
SPEC = importlib.util.spec_from_file_location("wirestack_tls_provider_poc", MODULE_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("cannot load provider PoC runner")
runner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runner)

_original_build_provider = runner.build_provider


def build_provider(spec, src, work, log):
    if spec["id"] != "openssl":
        return _original_build_provider(spec, src, work, log)

    build = work / "build"
    prefix = work / "prefix"
    jobs = str(max(2, min(os.cpu_count() or 2, 4)))
    env = os.environ.copy()
    env["CFLAGS"] = "-O2 -fPIC"
    runner.run([
        str(src / "Configure"),
        "no-shared",
        "no-module",
        "no-tests",
        "no-zlib",
        "no-zstd",
        "no-secure-memory",
        f"--prefix={prefix}",
        "--libdir=lib",
    ], cwd=src, log=log, env=env)
    runner.run(["make", f"-j{jobs}"], cwd=src, log=log, env=env)
    runner.run(["make", "install_sw"], cwd=src, log=log, env=env)
    archives = [
        runner.find_one(prefix, ["libssl.a"]),
        runner.find_one(prefix, ["libcrypto.a"]),
    ]
    return prefix, archives


runner.build_provider = build_provider
raise SystemExit(runner.main(sys.argv[1:]))
