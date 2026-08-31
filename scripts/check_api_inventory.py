#!/usr/bin/env python3
"""Validate the checked-in public API inventory and package pairing contract."""

from __future__ import annotations

import hashlib
import json
import pathlib
import subprocess
import sys
import tomllib

from release_graph import ROOT, load_release_graph


INVENTORY = ROOT / "release" / "public-api-inventory.toml"
SNAPSHOT = ROOT / "release" / "public-api-snapshot.txt"
C_ABI_DELTA = ROOT / "release" / "public-c-abi-delta-bfd29.toml"
CANGJIE_DELTA = ROOT / "release" / "public-cangjie-delta-bfd29.toml"
REQUIRED_PACKAGE_BUILD_FIELDS = ("cjc-version", "output-type")
OPTIONAL_STRING_BUILD_FIELDS = (
    "compile-option", "override-compile-option", "script-dir", "link-option",
)
OPTIONAL_TABLE_BUILD_FIELDS = ("package-configuration",)
NON_BUILD_PACKAGE_METADATA = {"name", "version", "organization", "description", "target-dir"}
NON_RELEASE_TOP_LEVEL_FIELDS = {"package", "dependencies", "test-dependencies", "profile"}


def load_toml(path: pathlib.Path) -> dict:
    return tomllib.loads(path.read_text(encoding="utf-8"))


def fail(message: str) -> None:
    raise SystemExit(f"api inventory error: {message}")


def check_release_manifest_fields(package_name: str, development: dict, released: dict,
        *, has_build_script: bool) -> None:
    """Require release manifests to preserve build-affecting development fields."""
    development_package = development.get("package")
    released_package = released.get("package")
    if not isinstance(development_package, dict) or not isinstance(released_package, dict):
        fail(f"{package_name} manifests must contain package tables")

    for field in REQUIRED_PACKAGE_BUILD_FIELDS:
        development_value = development_package.get(field)
        released_value = released_package.get(field)
        if not isinstance(development_value, str) or not development_value:
            fail(f"development {package_name} package.{field} must be a non-empty string")
        if released_value != development_value:
            fail(f"release {package_name} package.{field} does not match development")
    if released_package["output-type"] not in {"static", "dynamic"}:
        fail(f"release {package_name} package.output-type must be static or dynamic")

    for field in OPTIONAL_STRING_BUILD_FIELDS:
        development_value = development_package.get(field, "")
        released_value = released_package.get(field, "")
        if not isinstance(development_value, str) or not isinstance(released_value, str):
            fail(f"{package_name} package.{field} must be a string when present")
        if released_value != development_value:
            fail(f"release {package_name} package.{field} does not match development")
    if has_build_script:
        for manifest_kind, manifest_package in (
                ("development", development_package), ("release", released_package)):
            if "script-dir" not in manifest_package:
                fail(f"{manifest_kind} {package_name} must declare package.script-dir for build.cj")

    for field in OPTIONAL_TABLE_BUILD_FIELDS:
        development_value = development_package.get(field, {})
        released_value = released_package.get(field, {})
        if not isinstance(development_value, dict) or not isinstance(released_value, dict):
            fail(f"{package_name} package.{field} must be a table when present")
        if released_value != development_value:
            fail(f"release {package_name} package.{field} does not match development")

    known_package_fields = (
        set(REQUIRED_PACKAGE_BUILD_FIELDS) | set(OPTIONAL_STRING_BUILD_FIELDS) |
        set(OPTIONAL_TABLE_BUILD_FIELDS) | NON_BUILD_PACKAGE_METADATA
    )
    for field in sorted((set(development_package) | set(released_package)) - known_package_fields):
        if development_package.get(field) != released_package.get(field):
            fail(f"release {package_name} package.{field} does not match development")

    # Future target/ffi/build tables must be copied deliberately. Development
    # profiles are local test/benchmark settings and are intentionally omitted.
    if "profile" in released or "test-dependencies" in released:
        fail(f"release {package_name} must not contain profile or test-dependencies tables")
    development_sections = set(development) - NON_RELEASE_TOP_LEVEL_FIELDS
    released_sections = set(released) - {"package", "dependencies"}
    for field in sorted(development_sections | released_sections):
        if development.get(field) != released.get(field):
            fail(f"release {package_name} top-level {field} does not match development")


def check_versions(inventory: dict) -> None:
    graph = load_release_graph()
    if inventory.get("release_version") is not None or inventory.get("package_pairing") is not None:
        fail("release version and package pairing must come only from release/release-graph.toml")
    for package in graph.packages:
        development = load_toml(ROOT / package.development_manifest)
        released = load_toml(ROOT / package.release_manifest)
        package_root = (ROOT / package.source_root).parent
        check_release_manifest_fields(package.name, development, released,
            has_build_script=(package_root / "build.cj").is_file())
        for kind, manifest in (("development", development), ("release", released)):
            if manifest["package"]["name"] != package.name:
                fail(f"{kind} manifest name does not match graph package {package.name}")
            if manifest["package"]["version"] != graph.version:
                fail(f"{kind} {package.name} version is not {graph.version}")
            dependencies = manifest.get("dependencies", {})
            expected_dependencies = package.dependencies
            if set(dependencies) != set(expected_dependencies):
                fail(f"{kind} {package.name} dependencies do not match release graph")
            if kind == "development":
                test_dependencies = manifest.get("test-dependencies", {})
                if set(test_dependencies) != set(package.test_dependencies):
                    fail(f"development {package.name} test dependencies do not match release graph")
        for dependency in package.dependencies:
            if released["dependencies"][dependency] != graph.version:
                fail(f"release {package.name} dependency {dependency} is not pinned to {graph.version}")


def check_declarations(inventory: dict, *, root: pathlib.Path = ROOT,
        snapshot: pathlib.Path = SNAPSHOT, package_names: set[str] | None = None) -> None:
    """Bind every reviewed inventory item to exact snapshot declarations.

    The complete snapshot generator remains responsible for discovering every
    public declaration. This inventory is the smaller, human-reviewed change
    summary, so each summary item names the exact snapshot records that support
    it instead of using a source substring that could match an unrelated type.
    """
    if package_names is None:
        package_names = set(load_release_graph().names)
    if not snapshot.is_file():
        fail(f"public API snapshot is missing: {snapshot}")
    snapshot_records = set(snapshot.read_text(encoding="utf-8").splitlines())
    seen_records: set[str] = set()
    for entry in inventory["api"]:
        domain = entry.get("domain")
        if domain == "cangjie":
            package = entry.get("package")
            if package not in package_names:
                fail(f"{entry['symbol']} uses unknown package {package}")
            if "prefix" in entry:
                fail(f"{entry['symbol']} Cangjie entry must not declare prefix")
            record_prefix = package
        elif domain == "c-abi":
            if "package" in entry:
                fail(f"{entry['symbol']} C ABI entry must not declare package")
            if entry.get("prefix") != "c-abi":
                fail(f"{entry['symbol']} C ABI entry must declare prefix c-abi")
            record_prefix = "c-abi"
        else:
            fail(f"{entry['symbol']} uses unsupported declaration domain {domain}")
        if "source" in entry or "needle" in entry:
            fail(f"{entry['symbol']} uses legacy source/needle matching")
        declarations = entry.get("declarations")
        if not isinstance(declarations, list) or not declarations:
            fail(f"{entry['symbol']} has no exact declarations")
        for declaration in declarations:
            if set(declaration) != {"source", "owner", "signature"}:
                fail(f"{entry['symbol']} declaration must contain only source, owner, and signature")
            source = declaration["source"]
            owner = declaration["owner"]
            signature = declaration["signature"]
            if not all(isinstance(value, str) and value for value in (source, owner, signature)):
                fail(f"{entry['symbol']} declaration fields must be non-empty strings")
            if any("\n" in value or "|" in value for value in (source, owner, signature)):
                fail(f"{entry['symbol']} declaration fields must be one snapshot-safe line")
            path = root / source
            if not path.is_file():
                fail(f"{entry['symbol']} references missing source {source}")
            if domain == "c-abi" and (not source.startswith("native/") or not source.endswith(".h")):
                fail(f"{entry['symbol']} C ABI declaration must reference a native header")
            record = f"{record_prefix}|{source}|{owner}|{signature}"
            if record not in snapshot_records:
                fail(f"{entry['symbol']} declaration is missing from the public API snapshot: {record}")
            if record in seen_records:
                fail(f"duplicate reviewed declaration: {record}")
            seen_records.add(record)


def _record_digest(records: set[str]) -> str:
    payload = "\n".join(sorted(records)) + "\n"
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


CANGJIE_REVIEW_RATIONALES = {
    "typed-generated-spi": (
        "Freeze the v1 generated bridge on GeneratedCodecProviderV1<T> -> JsonCodec<T>; "
        "remove Any erasure, reification adapters, casts, and the previous raw codec interfaces."
    ),
    "application-api-maturity-reset": (
        "Define the 0.1 application model around JsonNode, JsonValueView, JsonDocument, and "
        "bounded JsonReadOptions/JsonWriteOptions without compatibility aliases."
    ),
    "facade-and-custom-codec-redesign": (
        "Use one YJson overload family and the JsonReader/JsonWriter custom-codec boundary; "
        "move built-in codec lookup under JsonCodecs and remove direct engine entry points."
    ),
    "experimental-engine-surface-closure": (
        "Remove public parser, writer, Compact, tape, and temporal fast-path prototypes; retain "
        "only the versioned first-party seams required across lockstep packages."
    ),
    "algorithm-view-and-result-redesign": (
        "Make algorithms consume read-only JsonValueView/JsonDocument inputs and return bounded, "
        "structured results or lazy cursors instead of mutable-node-only prototype results."
    ),
    "advanced-backend-package-redesign": (
        "Replace backend tuning and implementation-specific document types with explicit advanced "
        "package facades, managed views, metadata, and resource-owning BackendJsonDocument values."
    ),
    "experimental-macro-removal": (
        "Remove the experimental JSON literal macros from the 0.1 package graph while retaining "
        "the typed @JsonCodec generator."
    ),
    "unclassified": "No reviewed migration rule matches this declaration.",
}


def _classify_cangjie_delta_record(record: str) -> str:
    parts = record.split("|", 3)
    if len(parts) != 4:
        return "unclassified"
    package, source, owner, declaration = parts
    if package == "yjson_algorithms":
        return "algorithm-view-and-result-redesign"
    if package in {"yjson_backends", "yjson_native", "yjson_yyjson"}:
        return "advanced-backend-package-redesign"
    if package == "yjson_macros":
        return "experimental-macro-removal"
    generated_owners = {
        "JsonCodecProvider", "JsonCompactRawCodec", "JsonDirectWriteCodec", "JsonFastCodec",
        "JsonArrayListFastCodec", "JsonCompactRawArrayListElementCodec", "JsonCodecBulkWriter",
        "JsonReplayValue", "JsonAnyCodec", "GeneratedSupportV1", "GeneratedCodecProviderV1",
        "GeneratedCodecV1", "GeneratedObjectCodecV1", "GeneratedObjectCodecProviderV1",
        "GeneratedDirectWriteCodecV1", "GeneratedCompactWriteCodecV1",
        "GeneratedCompactArrayListElementCodecV1", "GeneratedBulkWriterV1",
        "GeneratedReplayValueV1", "GeneratedReadStateV1", "GeneratedWriteStateV1",
    }
    generated_markers = (
        "Generated", "__yJson", "eraseJsonCodec", "jsonCodecOf", "jsonTryWriteCompact",
        "readJsonFastWith", "writeJsonDirectWith", "JsonAnyCodec", "JsonArrayListFastCodec",
        "JsonCodecBulkWriter", "JsonCodecProvider", "JsonCompactRawArrayListElementCodec",
        "JsonCompactRawCodec", "JsonDirectWriteCodec", "JsonFastCodec", "JsonObjectCodec",
        "JsonReplayValue", "JsonDecodeContext", "JsonEncodeContext",
    )
    if (source == "src/lib_json_generated_support_v1.cj" or owner in generated_owners or
            source == "src/lib_json_temporal_number_fast.cj" or
            (source == "src/lib_json_direct_codec.cj" and
                any(marker in declaration for marker in generated_markers))):
        return "typed-generated-spi"
    if source in {
        "src/lib_json_direct_reader.cj", "src/lib_json_direct_writer.cj",
        "src/lib_json_fast_reader.cj", "src/lib_json_compact_document.cj",
        "src/lib_json_stream_tape.cj",
    }:
        return "experimental-engine-surface-closure"
    if source in {
        "src/lib_json_value.cj", "src/lib_json_bind.cj", "src/lib_json_document.cj",
        "src/lib_json_stream_writer.cj", "src/lib_json_runtime.cj",
    }:
        return "application-api-maturity-reset"
    if source in {"src/lib_json_direct_codec.cj", "src/lib_json_builtin_codecs.cj"}:
        return "facade-and-custom-codec-redesign"
    return "unclassified"


def _is_production_c_abi_record(record: object) -> bool:
    if not isinstance(record, str) or "_Test" in record:
        return False
    parts = record.split("|", 3)
    return (len(parts) == 4 and parts[0] == "c-abi" and
            parts[1].startswith("native/") and parts[1].endswith(".h") and
            parts[2] == "<top-level>" and bool(parts[3]))


def check_c_abi_delta(inventory: dict, delta: dict, *, snapshot: pathlib.Path = SNAPSHOT) -> None:
    """Verify the reviewed production C ABI delta against its frozen baseline digest."""
    if delta.get("schema_version") != 1 or delta.get("domain") != "c-abi":
        fail("unsupported C ABI delta schema or domain")
    baseline_commit = delta.get("baseline_commit")
    if not isinstance(baseline_commit, str) or len(baseline_commit) != 40 or any(
            char not in "0123456789abcdef" for char in baseline_commit):
        fail("C ABI delta baseline_commit must be a full lowercase SHA")
    if delta.get("excluded_preprocessor_guard") != "YJ_TESTING":
        fail("C ABI delta must explicitly exclude YJ_TESTING")
    baseline_digest = delta.get("baseline_production_sha256")
    baseline_count = delta.get("baseline_production_records")
    if (not isinstance(baseline_digest, str) or len(baseline_digest) != 64 or
            any(char not in "0123456789abcdef" for char in baseline_digest)):
        fail("C ABI delta baseline_production_sha256 is invalid")
    if not isinstance(baseline_count, int) or baseline_count < 0:
        fail("C ABI delta baseline_production_records is invalid")

    snapshot_records = set(snapshot.read_text(encoding="utf-8").splitlines())
    current = {record for record in snapshot_records if record.startswith("c-abi|")}
    changes = delta.get("changes")
    if not isinstance(changes, list) or not changes:
        fail("C ABI delta must classify changes")
    added: set[str] = set()
    removed: set[str] = set()
    for change in changes:
        required = {"direction", "record", "compatibility", "classification", "review_status"}
        if set(change) != required:
            fail("each C ABI delta change must contain exact classification fields")
        direction = change["direction"]
        record = change["record"]
        if direction not in {"added", "removed"}:
            fail(f"invalid C ABI delta direction: {direction}")
        if not _is_production_c_abi_record(record):
            fail("C ABI delta records must be production c-abi snapshot records")
        expected_compatibility = "additive" if direction == "added" else "breaking"
        if change["compatibility"] != expected_compatibility:
            fail(f"C ABI {direction} record must be classified {expected_compatibility}")
        if not isinstance(change["classification"], str) or not change["classification"]:
            fail("C ABI delta classification must be non-empty")
        if change["review_status"] != "reviewed-for-0.1.0":
            fail("C ABI delta change is not reviewed for 0.1.0")
        target = added if direction == "added" else removed
        if record in target:
            fail(f"duplicate C ABI delta record: {record}")
        target.add(record)
    if not added <= current:
        fail("C ABI added records are missing from the current snapshot")
    if removed & current:
        fail("C ABI removed records are still present in the current snapshot")
    baseline = (current - added) | removed
    if len(baseline) != baseline_count or _record_digest(baseline) != baseline_digest:
        fail("C ABI classified delta does not reconstruct the frozen production baseline")

    c_abi_entries = [entry for entry in inventory["api"] if entry.get("domain") == "c-abi"]
    expected_artifact = str(C_ABI_DELTA.relative_to(ROOT))
    if not c_abi_entries or any(
            entry.get("delta_artifact") != expected_artifact for entry in c_abi_entries):
        fail("all inventory C ABI entries must bind to the reviewed delta artifact")
    reviewed_added = set()
    for entry in c_abi_entries:
        for item in entry["declarations"]:
            record = f"c-abi|{item['source']}|{item['owner']}|{item['signature']}"
            if record in reviewed_added:
                fail(f"duplicate inventory C ABI declaration: {record}")
            reviewed_added.add(record)
    if reviewed_added != added:
        fail("inventory C ABI declarations do not match all classified additions")


def check_cangjie_delta(inventory: dict, delta: dict, *, snapshot: pathlib.Path = SNAPSHOT,
        release_status: str) -> None:
    """Verify a complete, declaration-by-declaration Cangjie migration review."""
    if delta.get("schema_version") != 2 or delta.get("domain") != "cangjie":
        fail("unsupported Cangjie delta schema or domain")
    if inventory.get("cangjie_delta_artifact") != str(CANGJIE_DELTA.relative_to(ROOT)):
        fail("inventory is not bound to the reviewed Cangjie delta artifact")
    baseline_commit = delta.get("baseline_commit")
    if not isinstance(baseline_commit, str) or len(baseline_commit) != 40 or any(
            char not in "0123456789abcdef" for char in baseline_commit):
        fail("Cangjie delta baseline_commit must be a full lowercase SHA")
    review_status = delta.get("review_status")
    if review_status not in {"pending-migration-review", "approved-for-release"}:
        fail("Cangjie delta has an invalid review_status")
    if release_status == "release-ready" and review_status != "approved-for-release":
        fail("release-ready graph requires explicit approval of the complete Cangjie delta")

    snapshot_records = set(snapshot.read_text(encoding="utf-8").splitlines())
    current = {
        record for record in snapshot_records
        if record and not record.startswith("#") and not record.startswith("c-abi|")
    }
    groups = delta.get("review_groups")
    if not isinstance(groups, list) or not groups:
        fail("Cangjie delta must contain review_groups")
    directions: dict[str, set[str]] = {"added": set(), "removed": set()}
    classifications: set[str] = set()
    pending_groups: list[str] = []
    for group in groups:
        required = {"classification", "rationale", "review_status", "removed", "added"}
        if not isinstance(group, dict) or set(group) != required:
            fail("each Cangjie review group must contain exact classification fields")
        classification = group["classification"]
        if classification not in CANGJIE_REVIEW_RATIONALES or classification in classifications:
            fail(f"invalid or duplicate Cangjie review classification: {classification}")
        classifications.add(classification)
        if group["rationale"] != CANGJIE_REVIEW_RATIONALES[classification]:
            fail(f"Cangjie review rationale drifted for {classification}")
        group_status = group["review_status"]
        if group_status not in {"pending-migration-review", "reviewed-for-0.1.0"}:
            fail(f"invalid Cangjie review group status: {classification}")
        if group_status != "reviewed-for-0.1.0":
            pending_groups.append(classification)
        for direction in ("added", "removed"):
            records = group[direction]
            if not isinstance(records, list) or not all(
                    isinstance(record, str) and record and not record.startswith("c-abi|")
                    for record in records):
                fail(f"Cangjie review group {classification} has invalid {direction} records")
            for record in records:
                if record in directions[direction]:
                    fail(f"duplicate Cangjie {direction} review record: {record}")
                if _classify_cangjie_delta_record(record) != classification:
                    fail(f"Cangjie review classification does not match declaration: {record}")
                directions[direction].add(record)
    if review_status == "approved-for-release" and pending_groups:
        fail("approved Cangjie delta still contains pending review groups")
    if review_status == "approved-for-release" and "unclassified" in classifications:
        fail("approved Cangjie delta cannot contain unclassified declarations")
    for direction in ("added", "removed"):
        record_set = directions[direction]
        count = delta.get(f"{direction}_records")
        digest = delta.get(f"{direction}_sha256")
        if count != len(record_set) or digest != _record_digest(record_set):
            fail(f"Cangjie delta {direction} count or digest does not match records")
    added = directions["added"]
    removed = directions["removed"]
    if added & removed:
        fail("Cangjie delta records cannot be both added and removed")
    if not added <= current:
        fail("Cangjie added records are missing from the current snapshot")
    if removed & current:
        fail("Cangjie removed records are still present in the current snapshot")
    baseline = (current - added) | removed
    baseline_count = delta.get("baseline_records")
    baseline_digest = delta.get("baseline_sha256")
    if baseline_count != len(baseline) or baseline_digest != _record_digest(baseline):
        fail("Cangjie classified delta does not reconstruct the frozen baseline")


def write_cangjie_delta_artifact(baseline_commit: str,
        destination: pathlib.Path = CANGJIE_DELTA) -> None:
    """Regenerate an exact, classified, pending-approval delta from a Git baseline."""
    baseline_text = subprocess.check_output(
        ["git", "show", f"{baseline_commit}:release/public-api-snapshot.txt"],
        cwd=ROOT, text=True,
    )
    current_text = SNAPSHOT.read_text(encoding="utf-8")
    select = lambda text: {
        line for line in text.splitlines()
        if line and not line.startswith("#") and not line.startswith("c-abi|")
    }
    baseline = select(baseline_text)
    current = select(current_text)
    added = sorted(current - baseline)
    removed = sorted(baseline - current)
    grouped: dict[str, dict[str, list[str]]] = {}
    for direction, records in (("removed", removed), ("added", added)):
        for record in records:
            classification = _classify_cangjie_delta_record(record)
            group = grouped.setdefault(classification, {"removed": [], "added": []})
            group[direction].append(record)
    lines = [
        "# Exact Cangjie declaration delta. Every declaration belongs to exactly one",
        "# reviewed migration group; global release approval remains explicit.",
        "schema_version = 2",
        'domain = "cangjie"',
        f"baseline_commit = {json.dumps(baseline_commit)}",
        f"baseline_records = {len(baseline)}",
        f"baseline_sha256 = {json.dumps(_record_digest(baseline))}",
        'review_status = "pending-migration-review"',
        f"removed_records = {len(removed)}",
        f"removed_sha256 = {json.dumps(_record_digest(set(removed)))}",
        f"added_records = {len(added)}",
        f"added_sha256 = {json.dumps(_record_digest(set(added)))}",
    ]
    for classification in sorted(grouped):
        group = grouped[classification]
        group_status = (
            "pending-migration-review" if classification == "unclassified"
            else "reviewed-for-0.1.0"
        )
        lines.extend([
            "",
            "[[review_groups]]",
            f"classification = {json.dumps(classification)}",
            f"rationale = {json.dumps(CANGJIE_REVIEW_RATIONALES[classification])}",
            f"review_status = {json.dumps(group_status)}",
            "removed = [",
        ])
        lines.extend(f"  {json.dumps(record)}," for record in group["removed"])
        lines.append("]")
        lines.append("added = [")
        lines.extend(f"  {json.dumps(record)}," for record in group["added"])
        lines.append("]")
    destination.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    inventory = load_toml(INVENTORY)
    if inventory.get("inventory_version") != 2:
        fail("unsupported inventory_version")
    check_versions(inventory)
    check_declarations(inventory)
    check_c_abi_delta(inventory, load_toml(C_ABI_DELTA))
    graph = load_release_graph()
    check_cangjie_delta(inventory, load_toml(CANGJIE_DELTA), release_status=graph.status)
    subprocess.run([sys.executable, str(ROOT / "scripts/test_release_graph.py")],
        cwd=ROOT, check=True)
    subprocess.run([sys.executable, str(ROOT / "scripts/test_generate_public_api_snapshot.py")],
        cwd=ROOT, check=True)
    subprocess.run([sys.executable, str(ROOT / "scripts/test_check_api_inventory.py")],
        cwd=ROOT, check=True)
    subprocess.run([sys.executable, str(ROOT / "scripts/test_release_temp_tree.py")],
        cwd=ROOT, check=True)
    subprocess.run([sys.executable, str(ROOT / "scripts/generate_public_api_snapshot.py")],
        cwd=ROOT, check=True)
    print(f"public API inventory passed: version={graph.version} packages={len(graph.packages)} "
          f"reviewed_deltas={len(inventory['api'])}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
