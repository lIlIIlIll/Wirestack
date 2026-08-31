#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import pathlib
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "check_generated_change_risk", ROOT / "scripts/check_generated_change_risk.py"
)
assert SPEC is not None and SPEC.loader is not None
RISK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RISK)


class GeneratedChangeRiskTest(unittest.TestCase):
    def test_unrelated_change_needs_no_consumer_change(self) -> None:
        self.assertEqual(RISK.validate_changed_paths(["README.md"]), [])

    def test_macro_change_without_external_runtime_test_fails(self) -> None:
        errors = RISK.validate_changed_paths(
            ["packages/yjson_macros/src/json_codec.cj"]
        )
        self.assertEqual(len(errors), 1)
        self.assertIn("external runtime test", errors[0])

    def test_direct_spi_change_without_external_runtime_test_fails(self) -> None:
        errors = RISK.validate_changed_paths(["src/lib_json_direct_codec.cj"])
        self.assertEqual(len(errors), 1)

    def test_risk_and_external_runtime_test_pass_together(self) -> None:
        self.assertEqual(
            RISK.validate_changed_paths(
                [
                    "src/lib_json_generated_support_v1.cj",
                    "packages/codec_integration/src/generated_collections_test.cj",
                ]
            ),
            [],
        )

    def test_behavioral_diff_requires_case_public_call_and_assertion(self) -> None:
        paths = [
            "packages/yjson_macros/src/json_codec.cj",
            "packages/codec_integration/src/generated_collections_test.cj",
        ]
        valid = """+++ b/packages/codec_integration/src/generated_collections_test.cj
+    @TestCase
+    func generatedMapRoundTrips(): Unit {
+        let text = YJson.toJson(value)
+        @Expect(YJson.fromJson<HashMap<String, Int64>>(text)[\"k\"], 1)
+    }
"""
        self.assertEqual(RISK.validate_behavioral_test_diff(paths, valid), [])

        comment_only = """+++ b/packages/codec_integration/src/generated_collections_test.cj
+// @TestCase YJson.toJson @Expect(
"""
        self.assertEqual(
            len(RISK.validate_behavioral_test_diff(paths, comment_only)), 1
        )

    def test_deleted_or_unrelated_test_cannot_satisfy_behavior_gate(self) -> None:
        paths = [
            "src/lib_json_direct_codec.cj",
            "packages/codec_integration/src/generated_collections_test.cj",
        ]
        deletion = """+++ b/packages/codec_integration/src/generated_collections_test.cj
-    @TestCase
-    func removed(): Unit { @Expect(YJson.toJson(value), \"{}\") }
"""
        self.assertEqual(len(RISK.validate_behavioral_test_diff(paths, deletion)), 1)

    def test_non_test_consumer_source_does_not_satisfy_gate(self) -> None:
        errors = RISK.validate_changed_paths(
            [
                "packages/yjson_macros/src/json_codec.cj",
                "packages/codec_integration/src/main.cj",
            ]
        )
        self.assertEqual(len(errors), 1)

    def test_wiring_requires_hosted_and_release_runtime_targets(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root / "scripts").mkdir()
            (root / ".github/workflows").mkdir(parents=True)
            (root / "scripts/ci_job.sh").write_text(
                "macro-consumer)\ncjpm test --no-color\n", encoding="utf-8"
            )
            (root / ".github/workflows/ci.yml").write_text(
                "- macro-consumer\n", encoding="utf-8"
            )
            (root / "scripts/release_cangjie_checks.sh").write_text(
                "macro-consumer-tests cjpm test --no-color\n", encoding="utf-8"
            )
            self.assertEqual(RISK.validate_wiring(root), [])
            (root / ".github/workflows/ci.yml").write_text("jobs: {}\n", encoding="utf-8")
            self.assertEqual(len(RISK.validate_wiring(root)), 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
