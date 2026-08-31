from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from tools import build_apple_resolver


class BuildAppleResolverCacheTests(unittest.TestCase):
    def test_never_evicts_an_active_cjpm_lease(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output_root = Path(directory)
            cache = output_root / "cache"
            entries = [cache / f"entry-{index}" for index in range(5)]
            for entry in entries:
                (entry / ".leases").mkdir(parents=True)
            (entries[0] / ".leases/41-live.json").write_text(
                json.dumps({
                    "schema_version": 1,
                    "pid": 41,
                    "process_identity": "live-process",
                }),
                encoding="utf-8",
            )
            with mock.patch.object(
                build_apple_resolver,
                "process_identity",
                side_effect=lambda pid: {41: "live-process"}.get(pid),
            ):
                build_apple_resolver.prune_cache(output_root, entries[1])
            self.assertTrue(entries[0].is_dir())
            self.assertTrue(entries[1].is_dir())
            self.assertEqual(
                build_apple_resolver.MAX_CACHE_ENTRIES,
                len(list(cache.iterdir())),
            )

    def test_fails_closed_when_live_leases_fill_capacity(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output_root = Path(directory)
            cache = output_root / "cache"
            for index in range(build_apple_resolver.MAX_CACHE_ENTRIES):
                lease_root = cache / f"entry-{index}" / ".leases"
                lease_root.mkdir(parents=True)
                (lease_root / f"{100 + index}-live.json").write_text(
                    json.dumps({
                        "schema_version": 1,
                        "pid": 100 + index,
                        "process_identity": f"live-{index}",
                    }),
                    encoding="utf-8",
                )
            with mock.patch.object(
                build_apple_resolver,
                "process_identity",
                side_effect=lambda pid: f"live-{pid - 100}",
            ):
                with self.assertRaisesRegex(
                    build_apple_resolver.BuildError, "active CJPM builds"
                ):
                    build_apple_resolver.prune_cache(
                        output_root, cache / "new-entry", reserve_new=True
                    )
            self.assertEqual(
                build_apple_resolver.MAX_CACHE_ENTRIES,
                len(list(cache.iterdir())),
            )

    def test_removes_stale_leases_before_pruning(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output_root = Path(directory)
            cache = output_root / "cache"
            entries = [cache / f"entry-{index}" for index in range(4)]
            for entry in entries:
                entry.mkdir(parents=True)
            lease_path = entries[0] / ".leases/41-stale.json"
            lease_path.parent.mkdir()
            lease_path.write_text(
                json.dumps({
                    "schema_version": 1,
                    "pid": 41,
                    "process_identity": "exited-process",
                }),
                encoding="utf-8",
            )
            with mock.patch.object(
                build_apple_resolver, "process_identity", return_value=None
            ):
                build_apple_resolver.prune_cache(
                    output_root, cache / "new-entry", reserve_new=True
                )
            self.assertEqual(3, len(list(cache.iterdir())))
            self.assertFalse(lease_path.exists())

    def test_rejects_malformed_lease_without_deleting_its_entry(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output_root = Path(directory)
            entry = output_root / "cache/entry"
            lease_path = entry / ".leases/bad.json"
            lease_path.parent.mkdir(parents=True)
            lease_path.write_text('{"schema_version": 99}\n', encoding="utf-8")
            with self.assertRaisesRegex(
                build_apple_resolver.BuildError, "invalid resolver cache lease"
            ):
                build_apple_resolver.prune_cache(output_root, entry)
            self.assertTrue(entry.is_dir())


if __name__ == "__main__":
    unittest.main()
