from __future__ import annotations

import copy
import importlib.util
import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MODULE = ROOT / "tools/tls_provider_poc/validate.py"
spec = importlib.util.spec_from_file_location("provider_validate", MODULE)
validator = importlib.util.module_from_spec(spec)
assert spec.loader
spec.loader.exec_module(validator)


class ProviderPocValidationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.spec = json.loads((ROOT / "tools/tls_provider_poc/providers.json").read_text())
        cls.matrix = json.loads((ROOT / "docs/evidence/M0-016/platform-matrix.json").read_text())

    def test_canonical_spec_and_matrix(self):
        validator.validate_spec(self.spec)
        validator.validate_matrix(self.matrix, self.spec)
        validator.validate_retained_results(self.matrix, self.spec, ROOT)

    def test_missing_archive_digest_fails(self):
        value = copy.deepcopy(self.spec)
        value["providers"][1].pop("sha256")
        with self.assertRaises(validator.ValidationError):
            validator.validate_spec(value)

    def test_archive_provider_requires_exact_commit(self):
        value = copy.deepcopy(self.spec)
        value["providers"][2].pop("commit")
        value["providers"][2]["commit_resolution_url"] = (
            "https://api.github.com/repos/openssl/openssl/git/ref/tags/openssl-3.6.3"
        )
        with self.assertRaises(validator.ValidationError):
            validator.validate_spec(value)

    def test_missing_platform_cell_fails(self):
        value = copy.deepcopy(self.matrix)
        value["cells"].pop()
        with self.assertRaises(validator.ValidationError):
            validator.validate_matrix(value, self.spec)

    def test_partial_matrix_cell_requires_retained_result(self):
        value = copy.deepcopy(self.matrix)
        cell = next(cell for cell in value["cells"] if cell["status"] == "PARTIAL")
        cell.pop("result")
        with self.assertRaises(validator.ValidationError):
            validator.validate_matrix(value, self.spec)

    def test_retained_result_digest_must_match(self):
        value = copy.deepcopy(self.matrix)
        cell = next(cell for cell in value["cells"] if cell["status"] == "PARTIAL")
        cell["sha256"] = "0" * 64
        with self.assertRaises(validator.ValidationError):
            validator.validate_retained_results(value, self.spec, ROOT)

    def test_blocked_capability_cannot_pass(self):
        caps = {name: "PASS" for name in self.spec["required_capabilities"]}
        caps["external_signer"] = "BLOCKED"
        result = {
            "schema_version": 1,
            "task_id": "M0-016",
            "provider": "aws-lc",
            "platform": "linux-glibc-x86_64",
            "status": "PASS",
            "source": {"content_sha256": "0" * 64, "commit": "1" * 40},
            "capabilities": caps,
            "build": {"static_archives": ["libssl.a"], "system_tls_dependencies": []},
        }
        with self.assertRaises(validator.ValidationError):
            validator.validate_result(result, self.spec)

    def test_system_tls_dependency_fails(self):
        caps = {name: "PASS" for name in self.spec["required_capabilities"]}
        result = {
            "schema_version": 1,
            "task_id": "M0-016",
            "provider": "openssl",
            "platform": "linux-glibc-x86_64",
            "status": "PASS",
            "source": {"content_sha256": "0" * 64, "commit": "1" * 40},
            "capabilities": caps,
            "build": {
                "static_archives": ["libssl.a"],
                "system_tls_dependencies": ["libssl.so.3"],
            },
        }
        with self.assertRaises(validator.ValidationError):
            validator.validate_result(result, self.spec)

    def test_pass_requires_measured_schema_v2(self):
        caps = {name: "PASS" for name in self.spec["required_capabilities"]}
        result = {
            "schema_version": 1,
            "task_id": "M0-016",
            "provider": "aws-lc",
            "platform": "linux-glibc-x86_64",
            "status": "PASS",
            "source": {"content_sha256": "0" * 64, "commit": "1" * 40},
            "capabilities": caps,
            "build": {
                "static_archives": ["libssl.a"],
                "system_tls_dependencies": [],
                "runtime_loader_library_strings": [],
            },
        }
        with self.assertRaises(validator.ValidationError):
            validator.validate_result(result, self.spec)

    def test_schema_v2_requires_exact_cleanup_and_signer_counts(self):
        caps = {name: "PASS" for name in self.spec["required_capabilities"]}
        result = {
            "schema_version": 2,
            "task_id": "M0-016",
            "provider": "aws-lc",
            "platform": "linux-glibc-x86_64",
            "status": "PASS",
            "source": {"content_sha256": "0" * 64, "commit": "1" * 40},
            "capabilities": caps,
            "metrics": {
                "repeated_cleanup_cycles": 9999,
                "external_signer_calls": 1,
            },
            "build": {
                "static_archives": ["libssl.a"],
                "system_tls_dependencies": [],
                "runtime_loader_library_strings": [],
            },
        }
        with self.assertRaises(validator.ValidationError):
            validator.validate_result(result, self.spec)

        result["metrics"] = {
            "repeated_cleanup_cycles": 10000,
            "external_signer_calls": 2,
        }
        validator.validate_result(result, self.spec)


if __name__ == "__main__":
    unittest.main()
