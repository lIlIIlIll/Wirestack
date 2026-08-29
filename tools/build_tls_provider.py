#!/usr/bin/env python3
"""Build the TLS provider selected for one target platform."""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Sequence

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from tools import build_linux_tls_provider
from tools.tls_provider.selection import (
    SelectionError,
    archive_symbols,
    select_provider,
    validate_native_header_signatures,
    validate_symbol_set,
)


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--platform")
    parser.add_argument("--provider")
    parser.add_argument("--offline", action="store_true")
    parser.add_argument("--print-manifest", action="store_true")
    parser.add_argument("--json", action="store_true")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    root = args.repo.resolve()
    selected = select_provider(
        root,
        platform=args.platform or os.environ.get("WIRESTACK_TARGET_PLATFORM"),
        provider=args.provider or os.environ.get("WIRESTACK_TLS_PROVIDER"),
    )
    validate_native_header_signatures(selected, root)
    if selected.adapter != "linux-aws-lc":
        raise SelectionError("adapter-unavailable", selected.adapter)
    adapter_args = [
        "--repo", str(root),
        "--abi-contract", str(selected.abi_contract_path),
    ]
    if args.offline:
        adapter_args.append("--offline")
    status = build_linux_tls_provider.main(adapter_args)
    if status != 0:
        raise SelectionError("adapter-build-failed", str(status))
    current = root / "target/native/current"
    archive = current / "lib/libwirestack_tls_provider.a"
    validate_symbol_set(selected, archive_symbols(archive))
    manifest = json.loads((current / "provider-manifest.json").read_text(encoding="utf-8"))
    if manifest.get("providerId") != selected.provider or manifest.get("abiVersion") != 1:
        raise SelectionError("build-manifest-mismatch", selected.provider)
    result = {
        "abi_version": 1,
        "adapter": selected.adapter,
        "build_fingerprint": manifest.get("build_fingerprint"),
        "platform": selected.platform,
        "provider": selected.provider,
        "selection_fingerprint": selected.fingerprint,
        "status": "PASS",
    }
    if args.json or args.print_manifest:
        print(json.dumps(result, sort_keys=True))
    else:
        print(f"TLS provider ready: {selected.platform} + {selected.provider}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except SelectionError as error:
        print(json.dumps({"code": error.code, "detail": error.detail, "status": "FAIL"}, sort_keys=True), file=sys.stderr)
        raise SystemExit(2)
    except build_linux_tls_provider.BuildError as error:
        print(json.dumps({"code": "adapter-build-failed", "detail": str(error), "status": "FAIL"}, sort_keys=True), file=sys.stderr)
        raise SystemExit(3)
