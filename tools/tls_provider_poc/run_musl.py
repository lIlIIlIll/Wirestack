#!/usr/bin/env python3
"""Run M0-016 under musl, with an explicit OpenSSL secure-heap boundary."""
from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

MODULE_PATH = Path(__file__).resolve().with_name("run.py")
SPEC = importlib.util.spec_from_file_location("wirestack_tls_provider_poc", MODULE_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("cannot load provider PoC runner")
runner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runner)

_original_build_provider = runner.build_provider


def build_provider(spec, src, work, log, *, repo=None, diagnostic=False):
    if spec["id"] != "openssl":
        return _original_build_provider(
            spec, src, work, log, repo=repo, diagnostic=diagnostic)
    return _original_build_provider(
        spec, src, work, log, repo=repo, diagnostic=diagnostic,
        extra_configure_args=("no-secure-memory",))


runner.build_provider = build_provider
raise SystemExit(runner.main(sys.argv[1:]))
