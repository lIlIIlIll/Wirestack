"""Fail-closed build-time TLS platform and provider selection."""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Mapping


MATRIX_KEYS = {"schema_version", "default_platform", "platforms"}
PLATFORM_KEYS = {"default_provider", "providers"}
PROVIDER_KEYS = {"adapter", "manifest", "abi_contract", "production"}
MANIFEST_KEYS = {
    "schema_version", "provider_id", "provider_version", "source",
    "license_expression", "patches", "cmake_options", "abi", "capabilities",
}
SOURCE_KEYS = {"kind", "url", "tag", "commit", "tree", "content_sha256"}
ABI_KEYS = {"name", "version", "backend", "header"}
ABI_CONTRACT_KEYS = {
    "schema_version", "required_functions", "capability_functions", "signatures",
}
ABI_SIGNATURE_KEYS = {"calling_convention", "return", "parameters"}
ABI_C_TYPES = {
    "void", "int32_t", "int64_t", "uint16_t", "uint32_t", "uint64_t",
    "const char *", "const uint8_t *", "uint8_t *", "const uint16_t *",
    "uint16_t *", "int32_t *", "int64_t *", "uint64_t *",
}
TLS_FOREIGN_FUNCTION_RE = re.compile(
    r"(?ms)^\s*foreign\s+func\s+(wirestack_tls_[A-Za-z0-9_]+)\s*"
    r"\((.*?)\)\s*:\s*([A-Za-z][A-Za-z0-9]*(?:<[A-Za-z0-9]+>)?)"
)
CANGJIE_ABI_TYPES = {
    "Unit": "void",
    "Int32": "i32",
    "Int64": "i64",
    "UInt16": "u16",
    "UInt32": "u32",
    "UInt64": "u64",
    "CString": "cstring",
    "CPointer<UInt8>": "ptr_u8",
    "CPointer<UInt16>": "ptr_u16",
    "CPointer<Int32>": "ptr_i32",
    "CPointer<Int64>": "ptr_i64",
    "CPointer<UInt64>": "ptr_u64",
}
C_ABI_TYPES = {
    "void": "void",
    "int32_t": "i32",
    "int64_t": "i64",
    "uint16_t": "u16",
    "uint32_t": "u32",
    "uint64_t": "u64",
    "const char *": "cstring",
    "const uint8_t *": "ptr_u8",
    "uint8_t *": "ptr_u8",
    "const uint16_t *": "ptr_u16",
    "uint16_t *": "ptr_u16",
    "int32_t *": "ptr_i32",
    "int64_t *": "ptr_i64",
    "uint64_t *": "ptr_u64",
}


class SelectionError(RuntimeError):
    def __init__(self, code: str, detail: str) -> None:
        super().__init__(detail)
        self.code = code
        self.detail = detail


@dataclass(frozen=True)
class ProviderSelection:
    platform: str
    provider: str
    adapter: str
    manifest_path: Path
    abi_contract_path: Path
    manifest: Mapping[str, Any]
    abi_contract: Mapping[str, Any]
    production: bool

    @property
    def fingerprint(self) -> str:
        value = {
            "platform": self.platform,
            "provider": self.provider,
            "adapter": self.adapter,
            "manifest": self.manifest,
            "abi_contract": self.abi_contract,
        }
        raw = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
        return hashlib.sha256(raw).hexdigest()


def _load_json(path: Path, missing_code: str) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise SelectionError(missing_code, str(path)) from error
    except (OSError, json.JSONDecodeError) as error:
        raise SelectionError("invalid-json", str(path)) from error
    if not isinstance(value, dict):
        raise SelectionError("invalid-schema", f"{path}: root must be an object")
    return value


def _exact_keys(value: Mapping[str, Any], expected: set[str], where: str) -> None:
    actual = set(value)
    if actual != expected:
        unknown = sorted(actual - expected)
        missing = sorted(expected - actual)
        raise SelectionError(
            "invalid-schema",
            f"{where}: unknown={unknown}; missing={missing}",
        )


def _inside(root: Path, relative: object, field: str) -> Path:
    if not isinstance(relative, str) or not relative:
        raise SelectionError("invalid-schema", f"{field}: non-empty path required")
    path = (root / relative).resolve()
    try:
        path.relative_to(root.resolve())
    except ValueError as error:
        raise SelectionError("path-escape", field) from error
    return path


def load_manifest(path: Path, expected_provider: str) -> dict[str, Any]:
    manifest = _load_json(path, "manifest-missing")
    _exact_keys(manifest, MANIFEST_KEYS, "provider manifest")
    if manifest.get("schema_version") != 1:
        raise SelectionError("unsupported-manifest-schema", str(manifest.get("schema_version")))
    if manifest.get("provider_id") != expected_provider:
        raise SelectionError("provider-id-mismatch", str(manifest.get("provider_id")))
    version = manifest.get("provider_version")
    if not isinstance(version, str) or not version:
        raise SelectionError("provider-version-mismatch", str(version))
    source = manifest.get("source")
    if not isinstance(source, dict):
        raise SelectionError("invalid-schema", "provider source must be an object")
    _exact_keys(source, SOURCE_KEYS, "provider source")
    if source.get("kind") != "git":
        raise SelectionError("invalid-source", "source.kind")
    for field, size in (("commit", 40), ("tree", 40), ("content_sha256", 64)):
        value = source.get(field)
        if not isinstance(value, str) or len(value) != size or any(c not in "0123456789abcdef" for c in value):
            raise SelectionError("source-digest-mismatch", field)
    abi = manifest.get("abi")
    if not isinstance(abi, dict):
        raise SelectionError("invalid-schema", "provider ABI must be an object")
    _exact_keys(abi, ABI_KEYS, "provider ABI")
    if abi.get("name") != "wirestack_tls_provider" or abi.get("version") != 1:
        raise SelectionError("abi-version-mismatch", str(abi.get("version")))
    capabilities = manifest.get("capabilities")
    if not isinstance(capabilities, list) or not capabilities or not all(isinstance(item, str) for item in capabilities):
        raise SelectionError("invalid-schema", "capabilities must be a non-empty string list")
    if len(set(capabilities)) != len(capabilities):
        raise SelectionError("invalid-schema", "capabilities contain duplicates")
    return manifest


def load_abi_contract(path: Path, manifest: Mapping[str, Any]) -> dict[str, Any]:
    contract = _load_json(path, "abi-contract-missing")
    _exact_keys(contract, ABI_CONTRACT_KEYS, "ABI contract")
    if contract.get("schema_version") != 2:
        raise SelectionError("abi-version-mismatch", str(contract.get("schema_version")))
    required = contract.get("required_functions")
    mapping = contract.get("capability_functions")
    signatures = contract.get("signatures")
    if not isinstance(required, list) or not all(isinstance(item, str) and item for item in required):
        raise SelectionError("invalid-schema", "ABI required_functions")
    if len(required) != len(set(required)):
        raise SelectionError("invalid-schema", "ABI required_functions duplicates")
    if not isinstance(mapping, dict):
        raise SelectionError("invalid-schema", "ABI capability_functions")
    if not isinstance(signatures, dict) or not signatures:
        raise SelectionError("invalid-schema", "ABI signatures")
    for capability in manifest["capabilities"]:
        functions = mapping.get(capability)
        if not isinstance(functions, list) or not functions:
            raise SelectionError("capability-function-mismatch", capability)
        if not all(isinstance(item, str) and item for item in functions):
            raise SelectionError("invalid-schema", f"ABI functions for {capability}")
    declared = set(required)
    for functions in mapping.values():
        if not isinstance(functions, list) or not all(isinstance(item, str) and item for item in functions):
            raise SelectionError("invalid-schema", "ABI capability function mapping")
        declared.update(functions)
    if declared != set(signatures):
        raise SelectionError(
            "abi-signature-inventory-mismatch",
            f"missing={sorted(declared - set(signatures))}; extra={sorted(set(signatures) - declared)}",
        )
    for name, signature in signatures.items():
        if re.fullmatch(r"wirestack_tls_[A-Za-z0-9_]+", name) is None:
            raise SelectionError("invalid-schema", f"ABI signature name: {name}")
        if not isinstance(signature, dict):
            raise SelectionError("invalid-schema", f"ABI signature: {name}")
        _exact_keys(signature, ABI_SIGNATURE_KEYS, f"ABI signature {name}")
        if signature.get("calling_convention") != "c":
            raise SelectionError("abi-calling-convention-mismatch", name)
        result = signature.get("return")
        parameters = signature.get("parameters")
        if result not in ABI_C_TYPES or not isinstance(parameters, list):
            raise SelectionError("invalid-schema", f"ABI signature types: {name}")
        if not all(item in ABI_C_TYPES and item != "void" for item in parameters):
            raise SelectionError("invalid-schema", f"ABI signature parameters: {name}")
    return contract


def select_provider(
    root: Path,
    *,
    platform: str | None = None,
    provider: str | None = None,
    matrix_path: Path | None = None,
) -> ProviderSelection:
    root = root.resolve()
    matrix = _load_json(matrix_path or root / "tools/tls_provider/selection.json", "selection-missing")
    _exact_keys(matrix, MATRIX_KEYS, "selection matrix")
    if matrix.get("schema_version") != 1:
        raise SelectionError("unsupported-selection-schema", str(matrix.get("schema_version")))
    selected_platform = platform or matrix.get("default_platform")
    platforms = matrix.get("platforms")
    if not isinstance(selected_platform, str) or not isinstance(platforms, dict):
        raise SelectionError("invalid-schema", "selection platform fields")
    platform_config = platforms.get(selected_platform)
    if not isinstance(platform_config, dict):
        raise SelectionError("unsupported-platform", selected_platform)
    _exact_keys(platform_config, PLATFORM_KEYS, f"platform {selected_platform}")
    providers = platform_config.get("providers")
    if not isinstance(providers, dict):
        raise SelectionError("invalid-schema", f"providers for {selected_platform}")
    selected_provider = provider or platform_config.get("default_provider")
    if not isinstance(selected_provider, str):
        raise SelectionError("invalid-schema", "default provider")
    provider_config = providers.get(selected_provider)
    if not isinstance(provider_config, dict):
        raise SelectionError("unsupported-provider", f"{selected_platform}:{selected_provider}")
    _exact_keys(provider_config, PROVIDER_KEYS, f"provider {selected_provider}")
    if provider_config.get("production") is not True:
        raise SelectionError("unsupported-combination", f"{selected_platform}:{selected_provider}")
    adapter = provider_config.get("adapter")
    if not isinstance(adapter, str) or not adapter:
        raise SelectionError("invalid-schema", "adapter")
    manifest_path = _inside(root, provider_config.get("manifest"), "manifest")
    abi_path = _inside(root, provider_config.get("abi_contract"), "abi_contract")
    manifest = load_manifest(manifest_path, selected_provider)
    contract = load_abi_contract(abi_path, manifest)
    selection = ProviderSelection(
        selected_platform,
        selected_provider,
        adapter,
        manifest_path,
        abi_path,
        manifest,
        contract,
        True,
    )
    validate_production_imports(selection, root)
    return selection


def expected_symbols(selection: ProviderSelection) -> set[str]:
    return set(selection.abi_contract["signatures"])


def _cangjie_signature(result: str, parameters: list[str], name: str) -> dict[str, Any]:
    try:
        canonical_result = CANGJIE_ABI_TYPES[result]
        canonical_parameters = [CANGJIE_ABI_TYPES[item] for item in parameters]
    except KeyError as error:
        raise SelectionError("abi-type-unsupported", f"{name}:{error.args[0]}") from error
    return {
        "calling_convention": "c",
        "return": canonical_result,
        "parameters": canonical_parameters,
    }


def _contract_ffi_signature(signature: Mapping[str, Any]) -> dict[str, Any]:
    return {
        "calling_convention": signature["calling_convention"],
        "return": C_ABI_TYPES[signature["return"]],
        "parameters": [C_ABI_TYPES[item] for item in signature["parameters"]],
    }


def production_import_signatures(root: Path) -> dict[str, dict[str, Any]]:
    signatures: dict[str, dict[str, Any]] = {}
    source_root = root.resolve() / "src"
    for path in sorted(source_root.rglob("*.cj")):
        if path.name.endswith("_test.cj"):
            continue
        text = path.read_text(encoding="utf-8")
        for match in TLS_FOREIGN_FUNCTION_RE.finditer(text):
            name, raw_parameters, result = match.groups()
            parameters: list[str] = []
            for raw_parameter in raw_parameters.split(","):
                raw_parameter = raw_parameter.strip()
                if not raw_parameter:
                    continue
                if ":" not in raw_parameter:
                    raise SelectionError("abi-declaration-invalid", f"{path}:{name}")
                parameters.append(raw_parameter.split(":", 1)[1].strip())
            signature = _cangjie_signature(result, parameters, name)
            previous = signatures.get(name)
            if previous is not None and previous != signature:
                raise SelectionError("abi-signature-conflict", name)
            signatures[name] = signature
    return signatures


def production_import_symbols(root: Path) -> set[str]:
    return set(production_import_signatures(root))


def validate_production_imports(selection: ProviderSelection, root: Path) -> None:
    imports = production_import_signatures(root)
    missing = sorted(set(imports) - expected_symbols(selection))
    if missing:
        raise SelectionError("abi-contract-incomplete", ",".join(missing))
    mismatches = sorted(
        name for name, signature in imports.items()
        if signature != _contract_ffi_signature(selection.abi_contract["signatures"][name])
    )
    if mismatches:
        raise SelectionError("abi-signature-mismatch", ",".join(mismatches))


def native_abi_probe_source(selection: ProviderSelection, header_name: str) -> str:
    lines = [f'#include "{header_name}"', ""]
    signatures = selection.abi_contract["signatures"]
    for index, name in enumerate(sorted(signatures)):
        signature = signatures[name]
        parameters = ", ".join(signature["parameters"]) or "void"
        lines.append(f"typedef {signature['return']} (*wirestack_contract_{index})({parameters});")
        lines.append(f"static wirestack_contract_{index} wirestack_check_{index} = &{name};")
    lines.extend(["", "int main(void) { return 0; }", ""])
    return "\n".join(lines)


def validate_native_header_signatures(
    selection: ProviderSelection,
    root: Path,
    *,
    compiler: str | None = None,
) -> None:
    header = _inside(root.resolve(), selection.manifest["abi"].get("header"), "abi.header")
    if not header.is_file():
        raise SelectionError("abi-header-missing", str(header))
    selected_compiler = compiler or os.environ.get("CC") or shutil.which("clang")
    if not selected_compiler:
        raise SelectionError("abi-compiler-missing", "clang")
    with tempfile.TemporaryDirectory(prefix="wirestack-abi-signature-") as directory:
        source = Path(directory) / "signature_probe.c"
        output = Path(directory) / "signature_probe.o"
        source.write_text(native_abi_probe_source(selection, header.name), encoding="utf-8")
        completed = subprocess.run(
            [
                selected_compiler,
                "-std=c11",
                "-Werror",
                "-Wincompatible-function-pointer-types",
                "-I",
                str(header.parent),
                "-c",
                str(source),
                "-o",
                str(output),
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
    if completed.returncode != 0:
        raise SelectionError(
            "native-abi-signature-mismatch",
            (completed.stderr or completed.stdout)[:4096],
        )


def validate_symbol_set(selection: ProviderSelection, symbols: set[str]) -> None:
    missing = sorted(expected_symbols(selection) - symbols)
    if missing:
        raise SelectionError("abi-function-missing", ",".join(missing))


def archive_symbols(archive: Path, nm: str = "nm") -> set[str]:
    completed = subprocess.run(
        [nm, "-g", "--defined-only", str(archive)],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if completed.returncode != 0:
        raise SelectionError("abi-scan-failed", completed.stderr[:4096])
    return {line.split()[-1] for line in completed.stdout.splitlines() if line.split()}
