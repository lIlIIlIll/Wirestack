#!/usr/bin/env python3
"""Check the maintained network capability map, generated docs and native receipt."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import sys

if __package__ in {None, ""}:
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from tools import evidence_digest as digest
from tools import m7_021_linux_release as release
from tools import m7_026_linux_api_freeze as api

ROOT = Path(__file__).resolve().parents[1]
TASK = "M9-003"
NATIVE_REPORT = f"docs/evidence/{TASK}/native-udp.json"
DESCRIPTION = "docs/references/linux-network-capabilities.json"
DOCS = ("docs/api/README.md", "docs/guides/network-foundation-linux.md")
BEGIN = "<!-- NETWORK_CAPABILITIES:BEGIN -->"
END = "<!-- NETWORK_CAPABILITIES:END -->"
SOCKETS = {"TcpStream", "TcpListener", "UdpSocket", "UnixStream", "UnixListener", "UnixDatagramSocket"}
OPERATIONS = SOCKETS | {"RawSocket", "DnsClient", "Resolver", "DnsMessageParser"}


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def relative_file(root: Path, value: str) -> Path:
    require(isinstance(value, str) and bool(value), "missing relative file")
    path = Path(value)
    require(not path.is_absolute() and ".." not in path.parts and "\\" not in value,
            "path must be repository-relative")
    resolved = (root / path).resolve()
    require(resolved.is_relative_to(root.resolve()) and resolved.is_file(), f"missing or escaping file: {value}")
    return resolved


def symbol_index(inventory: dict) -> dict[str, dict]:
    symbols = {}
    for declaration in inventory["declarations"]:
        name = declaration["package"] + "." + declaration["name"]
        symbols[name] = declaration
        for member in declaration.get("members", []):
            symbols[name + "." + member["name"]] = member
    return symbols


def validate_description(root: Path, description: dict, inventory: dict) -> dict:
    require(description.get("schema_version") == 1 and description.get("source_task") == TASK,
            "unsupported capability description schema/task")
    require(description.get("platform") == "linux-x86_64-glibc", "unsupported capability target")
    require(description.get("sdk_reference") == "docs/references/m7-033-ci-toolchain.json",
            "missing qualified SDK reference")
    relative_file(root, description["sdk_reference"])
    relative_file(root, description["native_runner"])
    consumers = description.get("consumer_sources", [])
    require(consumers and len(consumers) == len(set(consumers)), "missing/duplicate consumer sources")
    for source in consumers:
        relative_file(root, source)
    scenarios = description.get("required_scenarios", [])
    require(scenarios and len(scenarios) == len(set(scenarios)), "missing/duplicate native scenarios")
    policy = description.get("environment_failure_policy", {})
    require(set(policy) == {"permission_denied", "missing_native_error", "cross_compile"}
            and all(isinstance(value, str) and value.strip() for value in policy.values()),
            "missing distinction between capability and environment failures")
    symbols = symbol_index(inventory)
    backend_symbols = dict(symbols)
    for name in ("package.cj", "udp_socket.cj", "unix_listener.cj"):
        declarations = api.extract_public_declarations(root / "src/internal/transport_stdnet" / name)[2]
        backend_symbols.update(symbol_index({"declarations": declarations}))
    capability = symbols["wirestack.net.SocketCapabilities"]
    fields = {member["name"] for member in capability["members"] if member["kind"] == "let"}
    require(bool(fields), "public inventory has no capability fields")
    defaults = description.get("constructor_defaults", {})
    require(set(defaults) == fields and all(type(value) is bool for value in defaults.values()),
            "constructor-default inventory is incomplete")
    constructor = symbols["wirestack.net.SocketCapabilities.init"]["signature"]
    for field, expected in defaults.items():
        match = re.search(r"\b" + re.escape(field) + r"!\s*:\s*Bool\s*=\s*(true|false)\b", constructor)
        require(match is not None and (match.group(1) == "true") is expected,
                "public capability constructor defaults drifted")
    rows = description.get("rows", [])
    require(rows and len(rows) == len({row.get("id") for row in rows}), "missing/duplicate capability rows")
    coverage, used_symbols, used_scenarios = set(), set(), set()
    for row in rows:
        name = row.get("id")
        require(isinstance(name, str) and re.fullmatch(r"[A-Za-z0-9-]+", name) is not None,
                "invalid capability row identity")
        require(type(row.get("supported")) is bool, f"{name}: supported must be Bool")
        require(row.get("object") and row.get("label"), f"{name}: missing object/label")
        conditions = row.get("conditions", [])
        require(conditions and all(isinstance(item, str) and item.strip() for item in conditions),
                f"{name}: missing support conditions")
        public = row.get("public_symbols", [])
        require(public and len(public) == len(set(public)), f"{name}: missing/duplicate public symbols")
        require(all(symbol in symbols for symbol in public), f"{name}: public operation was removed")
        if row["supported"]:
            require(any(symbols[symbol]["kind"] in {"func", "init", "prop"} for symbol in public),
                    f"{name}: a type alone is not a callable capability")
        used_symbols.update(public)
        backends = row.get("backend_symbols", [])
        require(backends and all(item in backend_symbols for item in backends),
                f"{name}: missing or unknown backend prerequisites")
        cases = row.get("scenario_ids", [])
        require(cases and len(cases) == len(set(cases)) and set(cases) <= set(scenarios),
                f"{name}: missing/unknown native scenario")
        used_scenarios.update(cases)
        require(row.get("evidence") == NATIVE_REPORT,
                f"{name}: missing task-bound native evidence reference")
        field = row.get("capability_field")
        if field is not None:
            key = (row["object"], field)
            require(row["object"] in SOCKETS and field in fields and key not in coverage,
                    f"{name}: unknown/duplicate capability field")
            coverage.add(key)
            overrides = row.get("instance_support", {})
            require(isinstance(overrides, dict) and all(isinstance(key, str) and key and type(value) is bool
                    for key, value in overrides.items()), f"{name}: invalid instance support conditions")
        failure = row.get("failure")
        if row["supported"]:
            require(failure is None, f"{name}: supported operation cannot have an unavailable-operation failure")
        else:
            require(isinstance(failure, dict), f"{name}: missing stable failure reason")
            require(set(failure) == {"kind", "category", "phase", "code", "retryability"},
                    f"{name}: incomplete failure taxonomy")
            if failure["kind"] == "no_public_operation":
                require(all(failure[key] is None for key in ("category", "phase", "code", "retryability")),
                        f"{name}: absent API must not invent a runtime exception")
            else:
                require(failure["kind"] == "structured_error", f"{name}: unknown failure kind")
                for key, enum in (("category", "NetworkErrorCategory"), ("phase", "NetworkPhase"),
                                  ("code", "NetworkErrorCode"), ("retryability", "Retryability")):
                    require(f"wirestack.{enum}.{failure[key]}" in symbols, f"{name}: unknown stable {key}")
    require(coverage == {(owner, field) for owner in SOCKETS for field in fields},
            "capability field/object coverage is incomplete")
    require(used_scenarios == set(scenarios), "orphan native scenario")
    for declaration in inventory["declarations"]:
        if declaration["package"] == "wirestack.net" and declaration["name"] in OPERATIONS:
            for member in declaration["members"]:
                if member["kind"] in {"func", "init"}:
                    symbol = f"wirestack.net.{declaration['name']}.{member['name']}"
                    require(symbol in used_symbols, f"unmapped public network operation: {symbol}")
    return {"rows": len(rows), "socket_objects": sorted(SOCKETS), "capability_fields": sorted(fields),
            "native_scenarios": scenarios}


def render(description: dict, document: str) -> str:
    prefix = "../references/"
    identity = digest.text_evidence_digest_bytes(
        json.dumps(description, ensure_ascii=False, sort_keys=True).encode("utf-8")).to_json()
    lines = [BEGIN, "<!-- capability-description: " + json.dumps(identity, sort_keys=True) + " -->",
             "", "## 当前 Linux 公开网络能力", "",
             f"此表由 [{Path(DESCRIPTION).name}]({prefix}{Path(DESCRIPTION).name}) 生成。",
             "`支持` 仅指所列公开入口和条件；OS/SDK 有同名能力不等于 Wirestack 已提供入口。",
             "静态一致性不等于原生 PASS；原生证据必须另外核验 source、SDK、target 和安装产物。", "",
             "| 对象 | 能力字段 | 支持 | 条件 / 失败边界 | 原生场景 |", "|---|---|---|---|---|"]
    for row in description["rows"]:
        if row["capability_field"] is None:
            continue
        condition = " ".join(row["conditions"][1:] or row["conditions"])
        lines.append(f"| `{row['object']}` | `{row['capability_field']}` | {'支持' if row['supported'] else '不支持'} | {condition} | {', '.join(row['scenario_ids'])} |")
    lines += ["", "| 操作 / 地址形式 | 公开入口 | 支持条件或失败 | 原生场景 |", "|---|---|---|---|"]
    for row in description["rows"]:
        if row["capability_field"] is not None:
            continue
        methods = ", ".join("`" + symbol.removeprefix("wirestack.net.") + "`" for symbol in row["public_symbols"])
        conditions = " ".join(row["conditions"][1:])
        failure = row["failure"]
        if failure is not None:
            if failure["kind"] == "no_public_operation":
                conditions += " 无公开调用入口，不能虚构运行时 Unsupported 方法。"
            else:
                conditions += " `" + "/".join(failure[key] for key in ("category", "phase", "code", "retryability")) + "`。"
        lines.append(f"| {row['label']} | {methods} | {'支持；' if row['supported'] else '不支持；'}{conditions} | {', '.join(row['scenario_ids'])} |")
    lines += ["", *description["environment_failure_policy"].values(),
              f"[当前原生收据](../evidence/{TASK}/native-udp.json)记录实际 source/SDK/target；未运行或交叉编译不能转成支持。", "", END]
    return "\n".join(lines)


def documentation(root: Path, description: dict, *, write: bool) -> None:
    for name in DOCS:
        path = relative_file(root, name)
        text = path.read_text(encoding="utf-8")
        require(text.count(BEGIN) == 1 and text.count(END) == 1 and text.index(BEGIN) < text.index(END),
                f"{name}: missing/duplicate generated capability markers")
        start, end = text.index(BEGIN), text.index(END) + len(END)
        generated = render(description, name)
        if write:
            path.write_text(text[:start] + generated + text[end:], encoding="utf-8")
        else:
            require(text[start:end] == generated, f"{name}: capability documentation drift")


def native_inputs(root: Path, description: dict) -> set[str]:
    return ({path.relative_to(root).as_posix() for path in release.production_sources(root)}
            | set(release.QUALIFICATION_INPUTS)
            | {DESCRIPTION, description["sdk_reference"], description["native_runner"], *description["consumer_sources"],
               "tools/check_network_capabilities.py", "tools/development_baseline.py",
               "tools/m9_001_native_capabilities.py", "tools/evidence_digest.py",
               "tools/m7_026_linux_api_freeze.py", "tools/m7_027_linux_examples.py",
               "tools/m8_002_native_sockets.py", "tools/m8_003_native_sockets.py",
               "tools/m8_004_native_dns.py", "tools/m8_005_native_http.py",
               "src/net/m8_002_udp_test.cj", "src/net/m9_003_udp_test.cj",
               "src/internal/transport_stdnet/m9_003_udp_lifecycle_test.cj"})


def verify_artifacts(root: Path, value: object) -> None:
    if isinstance(value, dict):
        if "path" in value and "digest" in value:
            path = relative_file(root, value["path"])
            identity = value["digest"]
            if identity.get("domain") == digest.TEXT_EVIDENCE_DOMAIN:
                require(digest.text_evidence_sha256_equal(identity, digest.text_evidence_digest(path).to_json()),
                        "native text artifact changed")
            else:
                require(digest.artifact_byte_sha256_equal(identity, digest.artifact_byte_digest(path).to_json()),
                        "native binary artifact changed")
        for child in value.values():
            verify_artifacts(root, child)
    elif isinstance(value, list):
        for child in value:
            verify_artifacts(root, child)



def validate_native(root: Path, description: dict, report: dict) -> None:
    require(report.get("schema_version") == 1 and report.get("source_task") == TASK and report.get("status") == "PASS",
            "native receipt is missing, failed or belongs to another task")
    require(report.get("platform") == description["platform"] and report.get("native_execution") is True
            and report.get("cross_compiled") is False, "native target/execution proof is missing")
    current_source = digest.TextEvidenceDigest(release.source_tree_sha256(root)).to_json()
    require(digest.text_evidence_sha256_equal(report.get("source_digest", {}), current_source),
            "native source identity is stale")
    require(digest.text_evidence_sha256_equal(report.get("installed_source_digest", {}), current_source),
            "consumer did not use the current installed source")
    require(digest.text_evidence_sha256_equal(report.get("capability_description_digest", {}),
            digest.text_evidence_digest(root / DESCRIPTION).to_json()), "native capability conditions are stale")
    pin = json.loads(relative_file(root, description["sdk_reference"]).read_text(encoding="utf-8"))["sdk"]
    require(digest.artifact_byte_sha256_equal(report.get("sdk", {}).get("archive", {}),
            {"domain": digest.ARTIFACT_BYTE_DOMAIN, "sha256": pin["sha256"]}), "native SDK identity differs")
    require(report["sdk"].get("matched_archive_files", 0) > 0, "installed SDK was not checked against its archive")
    cases = report.get("scenarios", [])
    require(len(cases) == len({case.get("id") for case in cases}), "duplicate native scenario")
    require({case.get("id") for case in cases} == set(description["required_scenarios"])
            and all(case.get("status") == "PASS" for case in cases), "missing, skipped or failed native scenario")
    observed = report.get("observed_capabilities", {})
    require(set(observed) == SOCKETS, "missing native capability object")
    for owner in SOCKETS:
        fields = {row["capability_field"] for row in description["rows"]
                  if row["object"] == owner and row["capability_field"] is not None}
        require(set(observed[owner]) == fields, "native capability field inventory differs")
    for row in description["rows"]:
        field = row["capability_field"]
        if field is not None:
            require(observed[row["object"]].get(field) is row["supported"],
                    f"{row['id']}: public capability contradicts installed execution")
            overrides = row.get("instance_support", {})
            if overrides:
                observations = report.get("capability_observations", {}).get(row["object"], [])
                names = [item.get("instance") for item in observations]
                require(len(names) == len(set(names)) and set(overrides) <= set(names),
                        f"{row['id']}: missing or duplicate conditional native instance")
                for item in observations:
                    expected = overrides.get(item["instance"], row["supported"])
                    require(item.get("capabilities", {}).get(field) is expected,
                            f"{row['id']}: address-family capability contradicts execution")
    artifact = report.get("artifact", {})
    require(digest.artifact_byte_sha256_equal(artifact.get("digest", {}),
            digest.artifact_byte_digest(relative_file(root, artifact.get("path"))).to_json()),
            "native artifact bytes differ")
    commands = report.get("commands", [])
    require(commands and all(item.get("exit_code") == 0 and item.get("timed_out") is False for item in commands),
            "native command failed or timed out")
    for command in commands:
        require(all(isinstance(command.get(key), dict) and {"path", "digest"} <= set(command[key])
                    for key in ("stdout", "stderr")), "native command logs are missing")
    inputs = report.get("input_digests", {})
    require(native_inputs(root, description) <= set(inputs), "native execution inputs are incomplete")
    for name, identity in inputs.items():
        require(digest.text_evidence_sha256_equal(identity,
                digest.text_evidence_digest(relative_file(root, name)).to_json()), "native execution input changed")
    verify_artifacts(root, report)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--write-docs", action="store_true")
    parser.add_argument("--native-report", type=Path)
    parser.add_argument("--require-native", action="store_true")
    parser.add_argument("--report", type=Path)
    parser.add_argument("--api-report", type=Path)
    args = parser.parse_args(argv)
    report = {"schema_version": 1, "source_task": TASK, "status": "FAIL", "native": "NOT_RUN"}
    try:
        root = args.root.resolve()
        require(not (args.check and args.write_docs), "choose check or write-docs")
        description = json.loads(relative_file(root, DESCRIPTION).read_text(encoding="utf-8"))
        inventory = api.build_inventory(root, task_id=TASK)
        report.update(validate_description(root, description, inventory))
        documentation(root, description, write=args.write_docs)
        require(not args.require_native or args.native_report is not None, "native report is required")
        if args.native_report is not None:
            native = json.loads((root / args.native_report).read_text(encoding="utf-8"))
            validate_native(root, description, native)
            report["native"] = "PASS"
        report.update(status="PASS", description_digest=digest.text_evidence_digest(root / DESCRIPTION).to_json(),
                      inventory_sha256=inventory["inventorySha256"])
        if args.api_report:
            path = root / args.api_report
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps({"schema_version": 1, "source_task": TASK, "status": "PASS",
                                       "inventory": inventory}, indent=2) + "\n", encoding="utf-8")
    except (OSError, ValueError, KeyError, TypeError) as error:
        report["error"] = str(error)
    if args.report:
        path = args.root.resolve() / args.report
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False))
    return 0 if report["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
