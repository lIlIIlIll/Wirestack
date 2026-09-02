from __future__ import annotations

import copy
import importlib.util
import json
import os
import shutil
import tempfile
import unittest
from pathlib import Path

from tools.tests.test_tls_provider_poc import complete_result, runner, validator


ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = ROOT / "tools/tls_provider_poc/retain_mobile.py"
module_spec = importlib.util.spec_from_file_location("provider_mobile_retain", MODULE_PATH)
retainer = importlib.util.module_from_spec(module_spec)
assert module_spec.loader
module_spec.loader.exec_module(retainer)


class MobileRetentionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.spec = json.loads(
            (ROOT / "tools/tls_provider_poc/providers.json").read_text())
        self.revision = "a" * 40

    def make_matrix(self) -> dict:
        return {
            "schema_version": 1,
            "cells": [
                {
                    "provider": provider,
                    "platform": platform,
                    "status": "BLOCKED",
                    "reason": "awaiting hosted result",
                }
                for provider in ("aws-lc", "mbedtls", "openssl")
                for platform in self.spec["required_platforms"]
            ],
        }

    def make_result(self, root: Path, platform: str = "android-aarch64") -> tuple[Path, Path]:
        # The shared fixture intentionally covers the historical desktop
        # target set; bind its host fields to the mobile target below.
        result = complete_result(self.spec, platform="linux-glibc-x86_64")
        result["platform"] = platform
        result["execution"]["repository_revision"] = self.revision
        result["execution"]["runner_os"] = "Linux" if platform.startswith("android") else "macOS"
        result["execution"]["runner_arch"] = "X64" if platform.startswith("android") else "ARM64"
        result["execution"]["image_os"] = "ubuntu24" if platform.startswith("android") else "macos15"
        result["execution"]["native_runtime"] = (
            {
                "kind": "android-emulator",
                "runner": "github-hosted",
                "is_device": False,
                "abi": "arm64-v8a",
                "api_level": 33,
            }
            if platform.startswith("android") else {
                "kind": "ios-simulator",
                "runner": "github-hosted",
                "is_device": False,
                "arch": "arm64",
                "runtime": "com.apple.CoreSimulator.SimRuntime.iOS-18-5",
            }
        )
        result["build"]["provenance"]["target_triple"] = (
            "aarch64-linux-android" if platform.startswith("android")
            else "arm64-apple-ios-simulator"
        )
        result["operational_evidence"]["native_memory_diagnostic"] = {
            "status": "UNSUPPORTED",
            "tool": "address+undefined-sanitizer",
            "cleanup_cycles": 0,
            "provider_instrumented": False,
            "leak_detection": {"status": "UNSUPPORTED"},
        }
        source = root / "provider-source"
        source.mkdir()
        (source / "LICENSE").write_text("fixture license\n", encoding="utf-8")
        artifact = root / "artifact"
        artifact.mkdir()
        bundle_info = runner.create_license_bundle(
            source, artifact, result["provider"], result["source"])
        result["build"]["license_bundle"] = bundle_info
        result_path = artifact / "result.json"
        runner.atomic_json(result_path, result)
        return result_path, artifact / "license-bundle"

    def write_matrix(self, root: Path) -> Path:
        spec_path = root / "tools/tls_provider_poc/providers.json"
        spec_path.parent.mkdir(parents=True)
        shutil.copy2(ROOT / "tools/tls_provider_poc/providers.json", spec_path)
        path = root / "docs/evidence/M0-016/platform-matrix.json"
        path.parent.mkdir(parents=True)
        runner.atomic_json(path, self.make_matrix())
        return path

    def test_android_result_and_bundle_are_retained_and_matrix_cell_updated(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            matrix = self.write_matrix(root)
            result, bundle = self.make_result(root)
            report = retainer.retain(
                repo=root, matrix_path=matrix, result_path=result,
                license_bundle_path=bundle, expected_revision=self.revision)
            self.assertEqual(report["status"], "PASS")
            retained = root / "docs/evidence/M0-016/results/android-aarch64/aws-lc.json"
            manifest = root / "docs/evidence/M0-016/license-bundles/android-aarch64/aws-lc/manifest.json"
            self.assertTrue(retained.is_file())
            self.assertTrue(manifest.is_file())
            matrix_value = json.loads(matrix.read_text())
            cell = next(item for item in matrix_value["cells"]
                        if item["platform"] == "android-aarch64"
                        and item["provider"] == "aws-lc")
            self.assertEqual(cell["status"], "PASS")
            validator.validate_license_bundle(retained, json.loads(retained.read_text()), manifest)

    def test_repeat_retention_is_idempotent(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            matrix = self.write_matrix(root)
            result, bundle = self.make_result(root)
            first = retainer.retain(repo=root, matrix_path=matrix,
                                    result_path=result,
                                    license_bundle_path=bundle,
                                    expected_revision=self.revision)
            second = retainer.retain(repo=root, matrix_path=matrix,
                                     result_path=result,
                                     license_bundle_path=bundle,
                                     expected_revision=self.revision)
            self.assertEqual(first, second)

    def test_existing_result_mismatch_is_rejected_without_matrix_change(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            matrix = self.write_matrix(root)
            result, bundle = self.make_result(root)
            retainer.retain(repo=root, matrix_path=matrix, result_path=result,
                            license_bundle_path=bundle,
                            expected_revision=self.revision)
            original = matrix.read_bytes()
            changed_result = copy.deepcopy(json.loads(result.read_text()))
            changed_result["execution"]["image_version"] = "different"
            runner.atomic_json(result, changed_result)
            with self.assertRaisesRegex(retainer.RetentionError,
                                        "matrix cell already retains different evidence"):
                retainer.retain(repo=root, matrix_path=matrix,
                                result_path=result, license_bundle_path=bundle,
                                expected_revision=self.revision)
            self.assertEqual(matrix.read_bytes(), original)

    def test_symlink_in_license_bundle_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            matrix = self.write_matrix(root)
            result, bundle = self.make_result(root)
            outside = root / "outside"
            outside.write_text("escape\n", encoding="utf-8")
            os.symlink(outside, bundle / "files" / "escape.txt")
            with self.assertRaisesRegex(retainer.RetentionError, "symlinks"):
                retainer.retain(repo=root, matrix_path=matrix,
                                result_path=result, license_bundle_path=bundle,
                                expected_revision=self.revision)

    def test_non_mobile_result_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            matrix = self.write_matrix(root)
            result, bundle = self.make_result(root)
            value = json.loads(result.read_text())
            value["platform"] = "linux-glibc-x86_64"
            runner.atomic_json(result, value)
            with self.assertRaisesRegex(retainer.RetentionError, "only Android/iOS"):
                retainer.retain(repo=root, matrix_path=matrix,
                                result_path=result, license_bundle_path=bundle,
                                expected_revision=self.revision)

    def test_matrix_contract_is_checked_before_publish(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            matrix = self.write_matrix(root)
            value = json.loads(matrix.read_text())
            value["cells"].pop()
            runner.atomic_json(matrix, value)
            result, bundle = self.make_result(root)
            with self.assertRaisesRegex(retainer.RetentionError, "matrix coverage"):
                retainer.retain(repo=root, matrix_path=matrix,
                                result_path=result, license_bundle_path=bundle,
                                expected_revision=self.revision)

    def test_matrix_write_failure_preserves_old_target(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            matrix = self.write_matrix(root)
            result, bundle = self.make_result(root)
            original_bytes = matrix.read_bytes()
            original_atomic_json = retainer.atomic_json

            def injected_failure(path, value, before_replace=None):
                if before_replace is not None:
                    before_replace()
                raise OSError("injected matrix publication failure")

            retainer.atomic_json = injected_failure
            try:
                with self.assertRaisesRegex(retainer.RetentionError,
                                            "unable to publish matrix atomically"):
                    retainer.retain(repo=root, matrix_path=matrix,
                                    result_path=result,
                                    license_bundle_path=bundle,
                                    expected_revision=self.revision)
            finally:
                retainer.atomic_json = original_atomic_json
            self.assertEqual(matrix.read_bytes(), original_bytes)

    def test_matrix_path_escape_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            matrix = self.write_matrix(root)
            result, bundle = self.make_result(root)
            with self.assertRaisesRegex(retainer.RetentionError, "escapes repository"):
                retainer.retain(
                    repo=root, matrix_path=root / ".." / "outside.json",
                    result_path=result, license_bundle_path=bundle,
                    expected_revision=self.revision)


if __name__ == "__main__":
    unittest.main()
