#!/usr/bin/env python3
"""Regression tests for exact public API inventory declaration binding."""

from __future__ import annotations

import pathlib
import sys
import tempfile
import unittest


sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

from check_api_inventory import (
    C_ABI_DELTA,
    CANGJIE_DELTA,
    CANGJIE_REVIEW_RATIONALES,
    _record_digest,
    check_c_abi_delta,
    check_cangjie_delta,
    check_declarations,
    check_release_manifest_fields,
)


class PublicApiInventoryTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temp.name)
        self.source = "src/sample.cj"
        source_path = self.root / self.source
        source_path.parent.mkdir(parents=True)
        source_path.write_text("public class JsonReadOptions {}\n", encoding="utf-8")
        self.snapshot = self.root / "public-api-snapshot.txt"
        self.record = (
            "yjson|src/sample.cj|<top-level>|public class JsonReadOptions"
        )
        self.snapshot.write_text(self.record + "\n", encoding="utf-8")

    def tearDown(self) -> None:
        self.temp.cleanup()

    def inventory(self) -> dict:
        return {
            "api": [{
                "domain": "cangjie",
                "package": "yjson",
                "symbol": "JsonReadOptions",
                "declarations": [{
                    "source": self.source,
                    "owner": "<top-level>",
                    "signature": "public class JsonReadOptions",
                }],
            }],
        }

    def check(self, inventory: dict) -> None:
        check_declarations(inventory, root=self.root, snapshot=self.snapshot,
            package_names={"yjson"})

    def test_accepts_exact_snapshot_record(self) -> None:
        self.check(self.inventory())

    def test_rejects_broad_source_needle_schema(self) -> None:
        inventory = self.inventory()
        entry = inventory["api"][0]
        del entry["declarations"]
        entry["source"] = self.source
        entry["needle"] = "public class Json"
        with self.assertRaisesRegex(SystemExit, "legacy source/needle matching"):
            self.check(inventory)

    def test_rejects_signature_not_in_snapshot(self) -> None:
        inventory = self.inventory()
        inventory["api"][0]["declarations"][0]["signature"] = "public class JsonWriteOptions"
        with self.assertRaisesRegex(SystemExit, "declaration is missing from the public API snapshot"):
            self.check(inventory)

    def test_rejects_duplicate_reviewed_declaration(self) -> None:
        inventory = self.inventory()
        inventory["api"].append({
            "domain": "cangjie",
            "package": "yjson",
            "symbol": "Duplicate summary",
            "declarations": [dict(inventory["api"][0]["declarations"][0])],
        })
        with self.assertRaisesRegex(SystemExit, "duplicate reviewed declaration"):
            self.check(inventory)

    def test_rejects_missing_source(self) -> None:
        inventory = self.inventory()
        inventory["api"][0]["declarations"][0]["source"] = "src/missing.cj"
        with self.assertRaisesRegex(SystemExit, "references missing source"):
            self.check(inventory)

    def test_accepts_explicit_c_abi_domain_and_prefix(self) -> None:
        header = self.root / "native" / "sample.h"
        header.parent.mkdir(parents=True)
        header.write_text("int32_t YJ_Sample(void);\n", encoding="utf-8")
        record = "c-abi|native/sample.h|<top-level>|int32_t YJ_Sample(void);"
        self.snapshot.write_text(record + "\n", encoding="utf-8")
        inventory = {"api": [{
            "domain": "c-abi",
            "prefix": "c-abi",
            "symbol": "YJ_Sample",
            "declarations": [{
                "source": "native/sample.h",
                "owner": "<top-level>",
                "signature": "int32_t YJ_Sample(void);",
            }],
        }]}
        self.check(inventory)

    def test_rejects_unknown_declaration_domain(self) -> None:
        inventory = self.inventory()
        inventory["api"][0]["domain"] = "generic"
        with self.assertRaisesRegex(SystemExit, "unsupported declaration domain"):
            self.check(inventory)


class CAbiDeltaTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.snapshot = pathlib.Path(self.temp.name) / "snapshot.txt"
        self.common = "c-abi|native/sample.h|<top-level>|int32_t YJ_Common(void);"
        self.added = "c-abi|native/sample.h|<top-level>|int32_t YJ_Added(void);"
        self.removed = "c-abi|native/sample.h|<top-level>|int32_t YJ_Removed(void);"
        self.snapshot.write_text(self.common + "\n" + self.added + "\n", encoding="utf-8")
        self.inventory = {"api": [{
            "domain": "c-abi",
            "prefix": "c-abi",
            "symbol": "sample ABI",
            "delta_artifact": str(C_ABI_DELTA.relative_to(C_ABI_DELTA.parents[1])),
            "declarations": [{
                "source": "native/sample.h",
                "owner": "<top-level>",
                "signature": "int32_t YJ_Added(void);",
            }],
        }]}
        self.delta = {
            "schema_version": 1,
            "domain": "c-abi",
            "baseline_commit": "a" * 40,
            "baseline_production_records": 2,
            "baseline_production_sha256": _record_digest({self.common, self.removed}),
            "excluded_preprocessor_guard": "YJ_TESTING",
            "changes": [
                self.change("added", self.added),
                self.change("removed", self.removed),
            ],
        }

    def tearDown(self) -> None:
        self.temp.cleanup()

    def change(self, direction: str, record: str) -> dict:
        return {
            "direction": direction,
            "record": record,
            "compatibility": "additive" if direction == "added" else "breaking",
            "classification": "fixture classification",
            "review_status": "reviewed-for-0.1.0",
        }

    def test_accepts_complete_classified_production_delta(self) -> None:
        check_c_abi_delta(self.inventory, self.delta, snapshot=self.snapshot)

    def test_rejects_unclassified_baseline_difference(self) -> None:
        self.delta["changes"] = [self.change("added", self.added)]
        with self.assertRaisesRegex(SystemExit, "does not reconstruct"):
            check_c_abi_delta(self.inventory, self.delta, snapshot=self.snapshot)

    def test_rejects_test_only_record(self) -> None:
        self.delta["changes"][0]["record"] = (
            "c-abi|native/sample.h|<top-level>|int32_t YJ_TestOnly(void);"
        )
        with self.assertRaisesRegex(SystemExit, "production c-abi"):
            check_c_abi_delta(self.inventory, self.delta, snapshot=self.snapshot)


class CangjieDeltaTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.snapshot = pathlib.Path(self.temp.name) / "snapshot.txt"
        self.common = "yjson|src/sample.cj|<top-level>|public class Common"
        self.added = "yjson|src/sample.cj|<top-level>|public class Added"
        self.removed = "yjson|src/sample.cj|<top-level>|public class Removed"
        self.snapshot.write_text(self.common + "\n" + self.added + "\n", encoding="utf-8")
        self.inventory = {
            "cangjie_delta_artifact": str(CANGJIE_DELTA.relative_to(CANGJIE_DELTA.parents[1]))
        }
        self.delta = {
            "schema_version": 2,
            "domain": "cangjie",
            "baseline_commit": "a" * 40,
            "baseline_records": 2,
            "baseline_sha256": _record_digest({self.common, self.removed}),
            "review_status": "pending-migration-review",
            "removed_records": 1,
            "removed_sha256": _record_digest({self.removed}),
            "added_records": 1,
            "added_sha256": _record_digest({self.added}),
            "review_groups": [{
                "classification": "unclassified",
                "rationale": CANGJIE_REVIEW_RATIONALES["unclassified"],
                "review_status": "pending-migration-review",
                "removed": [self.removed],
                "added": [self.added],
            }],
        }

    def tearDown(self) -> None:
        self.temp.cleanup()

    def check(self, *, release_status: str = "migration") -> None:
        check_cangjie_delta(
            self.inventory, self.delta, snapshot=self.snapshot,
            release_status=release_status,
        )

    def test_accepts_complete_pending_delta_during_migration(self) -> None:
        self.check()

    def test_release_ready_rejects_pending_migration_review(self) -> None:
        with self.assertRaisesRegex(SystemExit, "requires explicit approval"):
            self.check(release_status="release-ready")

    def test_release_ready_rejects_pending_group(self) -> None:
        self.delta["review_status"] = "approved-for-release"
        with self.assertRaisesRegex(SystemExit, "pending review groups"):
            self.check(release_status="release-ready")

    def test_accepts_fully_reviewed_release_approval(self) -> None:
        added = "yjson|src/lib_json_value.cj|<top-level>|public class Added"
        removed = "yjson|src/lib_json_value.cj|<top-level>|public class Removed"
        self.snapshot.write_text(self.common + "\n" + added + "\n", encoding="utf-8")
        self.delta.update({
            "baseline_sha256": _record_digest({self.common, removed}),
            "review_status": "approved-for-release",
            "removed_sha256": _record_digest({removed}),
            "added_sha256": _record_digest({added}),
            "review_groups": [{
                "classification": "application-api-maturity-reset",
                "rationale": CANGJIE_REVIEW_RATIONALES["application-api-maturity-reset"],
                "review_status": "reviewed-for-0.1.0",
                "removed": [removed],
                "added": [added],
            }],
        })
        self.check(release_status="release-ready")

    def test_rejects_incomplete_delta(self) -> None:
        self.delta["review_groups"][0]["removed"] = []
        self.delta["removed_records"] = 0
        self.delta["removed_sha256"] = _record_digest(set())
        with self.assertRaisesRegex(SystemExit, "does not reconstruct"):
            self.check()

    def test_rejects_approval_with_unclassified_declarations(self) -> None:
        self.delta["review_status"] = "approved-for-release"
        self.delta["review_groups"][0]["review_status"] = "reviewed-for-0.1.0"
        with self.assertRaisesRegex(SystemExit, "cannot contain unclassified"):
            self.check(release_status="release-ready")

    def test_rejects_duplicate_declaration_review(self) -> None:
        duplicate = dict(self.delta["review_groups"][0])
        duplicate["classification"] = "typed-generated-spi"
        duplicate["rationale"] = CANGJIE_REVIEW_RATIONALES["typed-generated-spi"]
        self.delta["review_groups"].append(duplicate)
        with self.assertRaisesRegex(SystemExit, "duplicate Cangjie added review record"):
            self.check()


class ReleaseManifestFieldsTest(unittest.TestCase):
    def manifests(self) -> tuple[dict, dict]:
        development = {
            "package": {
                "name": "yjson_sample",
                "cjc-version": "1.1.0",
                "output-type": "dynamic",
                "compile-option": "-O2",
                "override-compile-option": "",
                "script-dir": "",
                "link-option": "-L target/native -lsample",
                "package-configuration": {},
            },
            "dependencies": {},
            "test-dependencies": {"yjson": {"path": ".."}},
            "profile": {"bench": {"build": {"compile-option": "-O2"}}},
        }
        released = {
            "package": {
                "name": "yjson_sample",
                "cjc-version": "1.1.0",
                "output-type": "dynamic",
                "compile-option": "-O2",
                "script-dir": "",
                "link-option": "-L target/native -lsample",
            },
            "dependencies": {},
        }
        return development, released

    def check(self, development: dict, released: dict,
            *, has_build_script: bool = False) -> None:
        check_release_manifest_fields("yjson_sample", development, released,
            has_build_script=has_build_script)

    def test_accepts_equal_release_build_contract_and_default_omissions(self) -> None:
        development, released = self.manifests()
        self.check(development, released)

    def test_rejects_release_critical_package_field_drift(self) -> None:
        cases = {
            "cjc-version": "1.2.0",
            "output-type": "static",
            "compile-option": "-O0",
            "override-compile-option": "-O1",
            "script-dir": "scripts",
            "link-option": "-lother",
        }
        for field, value in cases.items():
            with self.subTest(field=field):
                development, released = self.manifests()
                released["package"][field] = value
                with self.assertRaisesRegex(SystemExit, f"package.{field}"):
                    self.check(development, released)

    def test_rejects_package_configuration_drift(self) -> None:
        development, released = self.manifests()
        released["package"]["package-configuration"] = {"feature": True}
        with self.assertRaisesRegex(SystemExit, "package.package-configuration"):
            self.check(development, released)

    def test_rejects_future_package_build_field_drift(self) -> None:
        development, released = self.manifests()
        development["package"]["build-mode"] = "native"
        with self.assertRaisesRegex(SystemExit, "package.build-mode"):
            self.check(development, released)

    def test_rejects_non_library_output_type_even_when_equal(self) -> None:
        development, released = self.manifests()
        development["package"]["output-type"] = "executable"
        released["package"]["output-type"] = "executable"
        with self.assertRaisesRegex(SystemExit, "must be static or dynamic"):
            self.check(development, released)

    def test_build_script_requires_explicit_script_dir_on_both_sides(self) -> None:
        development, released = self.manifests()
        del released["package"]["script-dir"]
        with self.assertRaisesRegex(SystemExit, "must declare package.script-dir for build.cj"):
            self.check(development, released, has_build_script=True)

    def test_rejects_top_level_build_table_drift(self) -> None:
        development, released = self.manifests()
        development["target"] = {"x86_64-unknown-linux-gnu": {"compile-option": "-O2"}}
        with self.assertRaisesRegex(SystemExit, "top-level target"):
            self.check(development, released)

    def test_rejects_release_only_profile_or_test_dependencies(self) -> None:
        for field in ("profile", "test-dependencies"):
            with self.subTest(field=field):
                development, released = self.manifests()
                released[field] = {}
                with self.assertRaisesRegex(SystemExit, "must not contain"):
                    self.check(development, released)


if __name__ == "__main__":
    unittest.main()
