#!/usr/bin/env python3
"""Build and run source-external consumers for every supported package path."""

import argparse
import pathlib
import shutil
import subprocess
import sys
import tempfile


ROOT = pathlib.Path(__file__).resolve().parents[1]


def quote(path: pathlib.Path) -> str:
    return path.as_posix().replace('"', '\\"')


def run_fixture(
    name: str,
    dependencies: str,
    source: str,
    base: pathlib.Path,
    override_compile_option: str,
) -> None:
    project = base / name
    (project / "src").mkdir(parents=True)
    manifest = f'''[package]
cjc-version = "1.1.0"
name = "yjson_release_{name}"
version = "0.0.0"
output-type = "executable"
compile-option = "-O2"
override-compile-option = "{override_compile_option}"

[dependencies]
{dependencies}
'''
    (project / "cjpm.toml").write_text(manifest, encoding="utf-8")
    (project / "src" / "main.cj").write_text(source, encoding="utf-8")
    result = subprocess.run(
        ["cjpm", "run"], cwd=project, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    )
    if result.returncode != 0:
        print(result.stdout[-12000:], file=sys.stderr)
        for log in sorted(project.rglob("script-log")):
            print(f"--- {log} ---", file=sys.stderr)
            print(log.read_text(encoding="utf-8", errors="replace")[-4000:], file=sys.stderr)
        raise subprocess.CalledProcessError(result.returncode, ["cjpm", "run"])
    print(f"external consumer passed: {name}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--modules-root", type=pathlib.Path)
    parser.add_argument("--override-compile-option", default="")
    parser.add_argument(
        "--only", choices=("core", "macro", "algorithms", "schema-formats", "native", "yyjson"),
        action="append"
    )
    args = parser.parse_args()
    selected = set(args.only or (
        "core", "macro", "algorithms", "schema-formats", "native", "yyjson"))
    modules = args.modules_root.resolve() if args.modules_root else None
    base = pathlib.Path(tempfile.mkdtemp(prefix="yjson-consumers-"))
    try:
        core = quote(modules / "yjson" if modules else ROOT)
        macros = quote(modules / "yjson_macros" if modules else ROOT / "packages" / "yjson_macros")
        native = quote(modules / "yjson_native" if modules else ROOT / "packages" / "yjson_native")
        native_accel = quote(modules / "yjson_native_accel" if modules else ROOT / "packages" / "yjson_native_accel")
        backends = quote(modules / "yjson_backends" if modules else ROOT / "packages" / "yjson_backends")
        algorithms = quote(modules / "yjson_algorithms" if modules else ROOT / "packages" / "yjson_algorithms")
        schema_formats = quote(modules / "yjson_schema_formats" if modules else ROOT / "packages" / "yjson_schema_formats")
        yyjson = quote(modules / "yjson_yyjson" if modules else ROOT / "packages" / "yjson_yyjson")
        if "core" in selected:
            run_fixture("core", f'yjson = {{ path = "{core}" }}', '''package yjson_release_core
import yjson.*
func rejects(text: String): Bool {
    try { let _ = JsonNode.parse(text); false } catch (_: JsonException) { true }
}
main(): Unit {
    let value = JsonNode.parse("{\\"ok\\":true}").asObject()
    if (!value.get("ok").getOrThrow().asBool()) { throw Exception("core") }
    let compact = YJson.parseDocument(unsafe { "[1,2,3]".rawData() })
    if (compact.root().element(2).getOrThrow().asInt64() != 3) { throw Exception("compact") }
    for (text in ["null", " true \\r\\n", "-0.125e+2", "\\\"\\\\u4E2D\\\\uD83D\\\\uDE42\\\"",
        "[null,true,false,-9223372036854775808,18446744073709551615,1.25e-3]",
        "{\\"nested\\":[{\\"x\\":1},[]]}"]) {
        let canonical = JsonNode.parse(text).toJson()
        if (YJson.parseDocument(text).root().materialize().toJson() != canonical) {
            throw Exception("core semantic")
        }
    }
    for (text in ["\\\"unterminated", "\\\"bad\\\\xescape\\\"", "\\\"\\\\uD83Dvalue\\\"", "01",
        "[1,]", "{\\"a\\" 1}", "{\\"a\\":true} trailing"]) {
        if (!rejects(text)) { throw Exception("core invalid semantic") }
    }
    println("core consumer passed")
}
''', base, args.override_compile_option)
        if "macro" in selected:
            run_fixture("macro", f'''yjson = {{ path = "{core}" }}
yjson_macros = {{ path = "{macros}" }}''', '''package yjson_release_macro
import yjson.*
import yjson_macros.*
@JsonCodec
class Person {
    public let id: Int64
    public let name: String
    public init(id: Int64, name: String) { this.id = id; this.name = name }
}
main(): Unit {
    let text = YJson.toJson(Person(7, "Alice"))
    let value = YJson.fromJson<Person>(text)
    if (value.id != 7 || value.name != "Alice") { throw Exception("macro") }
    let output = YJsonMemoryOutputStream()
    YJson.writeJson(Person(9, "Stream"), output)
    let streamed = YJson.fromJson<Person>(YJsonByteArrayInputStream(output.toByteArray()))
    if (streamed.id != 9 || streamed.name != "Stream") { throw Exception("macro stream") }
    println("macro consumer passed")
}
''', base, args.override_compile_option)
        if "algorithms" in selected:
            run_fixture("algorithms", f'''yjson = {{ path = "{core}" }}
yjson_algorithms = {{ path = "{algorithms}" }}''', '''package yjson_release_algorithms
import yjson.*
import yjson_algorithms.*
main(): Unit {
    let root = JsonNode.parse("{\\"users\\":[{\\"id\\":7}]}")
    let matches = JsonPath.parse("$.users[*].id").collectValues(root)
    if (matches.size != 1 || matches[0].asInt64() != 7) { throw Exception("json path") }
    let patch = JsonPatch.parse("[{\\"op\\":\\"replace\\",\\"path\\":\\"/users/0/id\\",\\"value\\":9}]")
    if (patch.apply(root)["users"][0]["id"].asInt64() != 9) { throw Exception("json patch") }
    let schema = JsonSchema.parse("{\\"type\\":\\"object\\",\\"required\\":[\\"users\\"]}")
    if (!schema.validate(root).isEmpty()) { throw Exception("json schema") }
    println("algorithms consumer passed")
}
''', base, args.override_compile_option)
        if "schema-formats" in selected:
            run_fixture("schema_formats", f'''yjson = {{ path = "{core}" }}
yjson_algorithms = {{ path = "{algorithms}" }}
yjson_schema_formats = {{ path = "{schema_formats}" }}''', '''package yjson_release_schema_formats
import yjson.*
import yjson_algorithms.*
import yjson_schema_formats.*
main(): Unit {
    let formats = JsonSchemaFormatRegistry.withCoreFormats()
    formats.install(StandardInternationalFormats())
    let config = JsonSchemaConfig(formatMode: JsonSchemaFormatMode.Assertion, formats: formats)
    let schema = JsonSchema.parse("{\\"format\\":\\"idn-hostname\\"}", config: config)
    if (!schema.validator().isValid(JsonNode.string("실례.테스트"))) { throw Exception("schema formats") }
    println("schema formats consumer passed")
}
''', base, args.override_compile_option)
        if "native" in selected:
            run_fixture("native", f'''yjson = {{ path = "{core}" }}
yjson_native = {{ path = "{native}" }}
yjson_native_accel = {{ path = "{native_accel}" }}
yjson_backends = {{ path = "{backends}" }}''', '''package yjson_release_native
import yjson.*
import yjson_native.*
import yjson_native_accel.*
import yjson_backends.*
func nativeRejects(text: String): Bool {
    try {
        try (document = NativeBackends.customNative.parseDocument(text)) {
            let _ = document.materialize()
        }
        false
    } catch (_: JsonException) { true }
}
main(): Unit {
    YJsonNativeAccel.initialize()
    let managed = YJson.parseDocument("{\\"n\\":42}")
    if (managed.root().member("n").getOrThrow().asInt64() != 42) { throw Exception("native accel") }
    let json = NativeBackends.customNative
    try (document = json.parseDocument("{\\"n\\":42}")) {
        if (document.root().member("n").getOrThrow().asInt64() != 42) {
            throw Exception("native advanced")
        }
    }
    let codec = JsonCodecs.array(JsonCodecs.int64)
    let streamOutput = YJsonMemoryOutputStream()
    json.writeJson([1, 2, 3], streamOutput, codec: codec)
    let streamed = json.fromJson(
        YJsonByteArrayInputStream(streamOutput.toByteArray()), codec: codec)
    if (streamed.size != 3 || streamed[2] != 3) { throw Exception("native stream") }
    for (vector in ["null", " true \\r\\n", "-0.125e+2", "\\\"\\\\u4E2D\\\\uD83D\\\\uDE42\\\"",
        "[null,true,false,-9223372036854775808,18446744073709551615,1.25e-3]",
        "{\\"nested\\":[{\\"x\\":1},[]]}"]) {
        try (advanced = json.parseDocument(vector)) {
            let expected = JsonNode.parse(vector).toJson()
            if (advanced.materialize().toJson() != expected) { throw Exception("native semantic") }
        }
    }
    for (vector in ["\\\"unterminated", "\\\"bad\\\\xescape\\\"", "\\\"\\\\uD83Dvalue\\\"", "01",
        "[1,]", "{\\"a\\" 1}", "{\\"a\\":true} trailing"]) {
        if (!nativeRejects(vector)) { throw Exception("native invalid semantic") }
    }
    let text = YJson.toJson([1, 2, 3], codec: codec, options: JsonWriteOptions.pretty())
    let bytes = String.fromUtf8(
        YJson.toJsonBytes([1, 2, 3], codec: codec, options: JsonWriteOptions.pretty()))
    let target = YJsonMemoryOutputStream()
    YJson.writeJson([1, 2, 3], target, codec: codec, options: JsonWriteOptions.pretty())
    if (bytes != text || target.toUtf8String() != text) { throw Exception("native writer targets") }
    let html = YJson.toJson("<tag>", codec: JsonCodecs.string,
        options: JsonWriteOptions(htmlSafe: true))
    if (html != "\\\"\\\\u003ctag\\\\u003e\\\"") { throw Exception("native html safe") }
    try {
        let _ = YJson.toJsonBytes("long", codec: JsonCodecs.string,
            options: JsonWriteOptions(maxOutputBytes: 3))
        throw Exception("native max bytes accepted")
    } catch (error: JsonException) {
        if (error.code != "output_too_large") { throw error }
    }
    println("native consumer passed")
}
''', base, args.override_compile_option)
        if "yyjson" in selected:
            run_fixture("yyjson", f'''yjson = {{ path = "{core}" }}
yjson_yyjson = {{ path = "{yyjson}" }}
yjson_backends = {{ path = "{backends}" }}''', '''package yjson_release_yyjson
import yjson.*
import yjson_yyjson.*
import yjson_backends.*
func yyjsonRejects(text: String): Bool {
    try {
        try (document = YyjsonBackends.yyjson.parseDocument(text)) {
            let _ = document.materialize()
        }
        false
    } catch (_: JsonException) { true }
}
main(): Unit {
    let json = YyjsonBackends.yyjson
    try (document = json.parseDocument("{\\"n\\":42}")) {
        if (document.root().member("n").getOrThrow().asInt64() != 42) {
            throw Exception("yyjson")
        }
    }
    let codec = JsonCodecs.array(JsonCodecs.int64)
    let streamOutput = YJsonMemoryOutputStream()
    json.writeJson([1, 2, 3], streamOutput, codec: codec)
    let streamed = json.fromJson(
        YJsonByteArrayInputStream(streamOutput.toByteArray()), codec: codec)
    if (streamed.size != 3 || streamed[2] != 3) { throw Exception("yyjson stream") }
    for (vector in ["null", " true \\r\\n", "-0.125e+2", "\\\"\\\\u4E2D\\\\uD83D\\\\uDE42\\\"",
        "[null,true,false,-9223372036854775808,18446744073709551615,1.25e-3]",
        "{\\"nested\\":[{\\"x\\":1},[]]}"]) {
        try (advanced = json.parseDocument(vector)) {
            let expected = JsonNode.parse(vector).toJson()
            if (advanced.materialize().toJson() != expected) { throw Exception("yyjson semantic") }
        }
    }
    for (vector in ["\\\"unterminated", "\\\"bad\\\\xescape\\\"", "\\\"\\\\uD83Dvalue\\\"", "01",
        "[1,]", "{\\"a\\" 1}", "{\\"a\\":true} trailing"]) {
        if (!yyjsonRejects(vector)) { throw Exception("yyjson invalid semantic") }
    }
    println("yyjson consumer passed")
}
''', base, args.override_compile_option)
    finally:
        shutil.rmtree(base)
    return 0


if __name__ == "__main__":
    sys.exit(main())
