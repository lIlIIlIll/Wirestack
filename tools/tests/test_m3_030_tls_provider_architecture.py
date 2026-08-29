from __future__ import annotations

import copy
import json
import tempfile
import unittest
from dataclasses import replace
from pathlib import Path

from tools.tls_provider.selection import (
    SelectionError,
    expected_symbols,
    load_manifest,
    load_abi_contract,
    production_import_signatures,
    production_import_symbols,
    select_provider,
    validate_native_header_signatures,
    validate_production_imports,
    validate_symbol_set,
)


ROOT = Path(__file__).resolve().parents[2]


class M3030TlsProviderArchitectureTests(unittest.TestCase):
    def selection(self):
        return select_provider(ROOT)

    def mutate_matrix(self, mutation):
        matrix = json.loads((ROOT / "tools/tls_provider/selection.json").read_text())
        mutation(matrix)
        temporary = tempfile.TemporaryDirectory(prefix="wirestack-m3-030-")
        path = Path(temporary.name) / "selection.json"
        path.write_text(json.dumps(matrix), encoding="utf-8")
        return temporary, path

    def mutate_manifest(self, mutation):
        manifest = json.loads((ROOT / "native/tls/aws_lc/provider.json").read_text())
        mutation(manifest)
        temporary = tempfile.TemporaryDirectory(prefix="wirestack-m3-030-")
        path = Path(temporary.name) / "provider.json"
        path.write_text(json.dumps(manifest), encoding="utf-8")
        return temporary, path

    def assert_selection_error(self, code, callback):
        with self.assertRaises(SelectionError) as caught:
            callback()
        self.assertEqual(code, caught.exception.code)

    def test_default_selection_is_exact_linux_aws_lc(self):
        selected = self.selection()
        self.assertEqual("linux-x86_64-glibc", selected.platform)
        self.assertEqual("aws-lc", selected.provider)
        self.assertEqual("5.5.0", selected.manifest["provider_version"])
        self.assertEqual(1, selected.manifest["abi"]["version"])
        self.assertTrue(selected.production)

    def test_unknown_platform_fails_without_fallback(self):
        self.assert_selection_error(
            "unsupported-platform",
            lambda: select_provider(ROOT, platform="future-os-x86_64"),
        )

    def test_unknown_provider_on_known_platform_fails_without_fallback(self):
        self.assert_selection_error(
            "unsupported-provider",
            lambda: select_provider(ROOT, provider="not-installed"),
        )

    def test_disallowed_platform_provider_pair_fails_closed(self):
        temporary, path = self.mutate_matrix(
            lambda value: value["platforms"]["linux-x86_64-glibc"]["providers"].update({
                "test-only": {
                    "abi_contract": "tools/tls_provider/abi-v1.json",
                    "adapter": "test-only",
                    "manifest": "native/tls/aws_lc/provider.json",
                    "production": False,
                }
            })
        )
        try:
            self.assert_selection_error(
                "unsupported-combination",
                lambda: select_provider(ROOT, provider="test-only", matrix_path=path),
            )
        finally:
            temporary.cleanup()

    def test_missing_manifest_and_path_escape_are_rejected(self):
        for replacement, code in (("missing.json", "manifest-missing"), ("../outside.json", "path-escape")):
            temporary, path = self.mutate_matrix(
                lambda value, replacement=replacement: value["platforms"]["linux-x86_64-glibc"]["providers"]["aws-lc"].update({"manifest": replacement})
            )
            try:
                self.assert_selection_error(code, lambda path=path: select_provider(ROOT, matrix_path=path))
            finally:
                temporary.cleanup()

    def test_unknown_schema_and_field_are_rejected(self):
        for mutation, code in (
            (lambda value: value.update({"schema_version": 2}), "unsupported-selection-schema"),
            (lambda value: value.update({"unexpected": True}), "invalid-schema"),
        ):
            temporary, path = self.mutate_matrix(mutation)
            try:
                self.assert_selection_error(code, lambda path=path: select_provider(ROOT, matrix_path=path))
            finally:
                temporary.cleanup()

    def test_manifest_identity_version_source_and_abi_mismatches_fail(self):
        cases = (
            (lambda value: value.update({"provider_id": "other"}), "provider-id-mismatch"),
            (lambda value: value.update({"provider_version": ""}), "provider-version-mismatch"),
            (lambda value: value["source"].update({"content_sha256": "0" * 63}), "source-digest-mismatch"),
            (lambda value: value["abi"].update({"version": 2}), "abi-version-mismatch"),
        )
        for mutation, code in cases:
            temporary, path = self.mutate_manifest(mutation)
            try:
                self.assert_selection_error(code, lambda path=path: load_manifest(path, "aws-lc"))
            finally:
                temporary.cleanup()

    def test_missing_abi_function_and_false_capability_are_rejected(self):
        selected = self.selection()
        symbols = expected_symbols(selected)
        symbols.remove("wirestack_tls_engine_enable_peer_verification")
        self.assert_selection_error(
            "abi-function-missing",
            lambda: validate_symbol_set(selected, symbols),
        )

    def test_contract_covers_every_production_tls_import(self):
        selected = self.selection()
        imports = production_import_symbols(ROOT)
        self.assertEqual(55, len(imports))
        self.assertEqual(set(), imports - expected_symbols(selected))
        self.assertEqual(
            {"wirestack_tls_engine_load_verify_locations"},
            expected_symbols(selected) - imports,
        )

        contract = copy.deepcopy(selected.abi_contract)
        contract["required_functions"].remove(
            "wirestack_tls_engine_enable_peer_verification"
        )
        del contract["signatures"]["wirestack_tls_engine_enable_peer_verification"]
        incomplete = replace(selected, abi_contract=contract)
        self.assert_selection_error(
            "abi-contract-incomplete",
            lambda: validate_production_imports(incomplete, ROOT),
        )

    def test_cangjie_ffi_parameter_and_return_drift_fail_closed(self):
        selected = self.selection()
        with tempfile.TemporaryDirectory(prefix="wirestack-m3-030-ffi-") as directory:
            root = Path(directory)
            source = root / "src/internal/tls_engine/package.cj"
            source.parent.mkdir(parents=True)
            source.write_text(
                "package wirestack.internal.tls_engine\n"
                "foreign func wirestack_tls_provider_destroy(handle: Int32): UInt64\n",
                encoding="utf-8",
            )
            self.assertEqual(
                {"wirestack_tls_provider_destroy"},
                set(production_import_signatures(root)),
            )
            self.assert_selection_error(
                "abi-signature-mismatch",
                lambda: validate_production_imports(selected, root),
            )

    def test_native_header_parameter_and_return_drift_fail_closed(self):
        selected = self.selection()
        manifest = copy.deepcopy(selected.manifest)
        with tempfile.TemporaryDirectory(prefix="wirestack-m3-030-header-") as directory:
            root = Path(directory)
            header = root / manifest["abi"]["header"]
            header.parent.mkdir(parents=True)
            original = (ROOT / manifest["abi"]["header"]).read_text(encoding="utf-8")
            header.write_text(
                original.replace(
                    "void wirestack_tls_provider_destroy(uint64_t handle);",
                    "uint64_t wirestack_tls_provider_destroy(int32_t handle);",
                ),
                encoding="utf-8",
            )
            mutated = replace(selected, manifest=manifest)
            self.assert_selection_error(
                "native-abi-signature-mismatch",
                lambda: validate_native_header_signatures(mutated, root),
            )

    def test_signature_schema_and_calling_convention_fail_closed(self):
        selected = self.selection()
        for mutation, code in (
            (lambda value: value.update({"schema_version": 1}), "abi-version-mismatch"),
            (
                lambda value: value["signatures"]["wirestack_tls_provider_destroy"].update(
                    {"calling_convention": "stdcall"}
                ),
                "abi-calling-convention-mismatch",
            ),
        ):
            contract = copy.deepcopy(selected.abi_contract)
            mutation(contract)
            with tempfile.TemporaryDirectory(prefix="wirestack-m3-030-contract-") as directory:
                path = Path(directory) / "abi.json"
                path.write_text(json.dumps(contract), encoding="utf-8")
                self.assert_selection_error(
                    code,
                    lambda path=path: load_abi_contract(path, selected.manifest),
                )

    def test_future_adapter_registration_does_not_modify_generic_source(self):
        before = {
            path: (ROOT / path).read_bytes()
            for path in ("src/internal/tls_engine/package.cj", "src/tls/facade.cj", "src/internal/http1/tls_client_pipeline.cj")
        }
        matrix = json.loads((ROOT / "tools/tls_provider/selection.json").read_text())
        matrix["platforms"]["future-test-platform"] = copy.deepcopy(matrix["platforms"]["linux-x86_64-glibc"])
        self.assertIn("future-test-platform", matrix["platforms"])
        after = {path: (ROOT / path).read_bytes() for path in before}
        self.assertEqual(before, after)

    def test_task_manifest_contains_no_long_gate(self):
        manifest = json.loads((ROOT / "tools/tasks/M3-030.json").read_text())
        self.assertFalse(manifest["long_running_gate"])
        self.assertTrue(all(not command["long_running"] for command in manifest["acceptance_commands"]))


if __name__ == "__main__":
    unittest.main()
