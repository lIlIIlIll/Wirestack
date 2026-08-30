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
    try { let _ = YJson.parse(text); false } catch (_: JsonException) { true }
}
main(): Unit {
    let value = YJson.parse("{\\"ok\\":true}").asObject()
    if (!value.get("ok").getOrThrow().asBool().value) { throw Exception("core") }
    let compact = YJson.parseCompact(unsafe { "[1,2,3]".rawData() })
    if (compact.root().get(2).getOrThrow().asInt64() != 3) { throw Exception("compact") }
    for (text in ["null", " true \\r\\n", "-0.125e+2", "\\\"\\\\u4E2D\\\\uD83D\\\\uDE42\\\"",
        "[null,true,false,-9223372036854775808,18446744073709551615,1.25e-3]",
        "{\\"nested\\":[{\\"x\\":1},[]]}"]) {
        let canonical = YJson.stringify(YJson.parse(text))
        if (YJson.parseDocument(text).toString() != canonical) { throw Exception("core semantic") }
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
    YJson.toStream(Person(9, "Stream"), output)
    let streamed = YJson.fromStream<Person>(YJsonByteArrayInputStream(output.toByteArray()))
    if (streamed.id != 9 || streamed.name != "Stream") { throw Exception("macro stream") }
    let key = "person"
    let literal = @Json({"ok": true, $(key): $(Person(8, "Bob")),})
    if (literal != "{\\\"ok\\\":true,\\\"person\\\":{\\\"id\\\":8,\\\"name\\\":\\\"Bob\\\"}}") {
        throw Exception("json literal")
    }
    let tree = @JsonValue({"name": "Alice", "items": [1, 2,]})
    tree["name"] = "Bob"
    tree["items"][0] = 9
    if (tree["name"].string != "Bob" || tree["items"][0].int64 != 9) {
        throw Exception("json value literal")
    }
    println("macro consumer passed")
}
''', base, args.override_compile_option)
        if "algorithms" in selected:
            run_fixture("algorithms", f'''yjson = {{ path = "{core}" }}
yjson_algorithms = {{ path = "{algorithms}" }}''', '''package yjson_release_algorithms
import yjson.*
import yjson_algorithms.*
main(): Unit {
    let root = YJson.parse("{\\"users\\":[{\\"id\\":7}]}")
    let matches = JsonPath.parse("$.users[*].id").values(root)
    if (matches.size != 1 || matches[0].int64 != 7) { throw Exception("json path") }
    let patch = JsonPatch.parse("[{\\"op\\":\\"replace\\",\\"path\\":\\"/users/0/id\\",\\"value\\":9}]")
    if (patch.apply(root)["users"][0]["id"].int64 != 9) { throw Exception("json patch") }
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
    let config = JsonSchemaConfig(formatMode: JsonSchemaFormatMode.StrictAssertion, formats: formats)
    let schema = JsonSchema.parse("{\\"format\\":\\"idn-hostname\\"}", config: config)
    if (!schema.validator().isValid(JsonStringValue("실례.테스트"))) { throw Exception("schema formats") }
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
        try (document = YJsonAdvanced.parseDocumentWithBackend(text, NativeCompactDocumentBackend)) {
            let _ = document.materialize()
        }
        false
    } catch (_: JsonException) { true }
}
main(): Unit {
    YJsonNativeAccel.initialize()
    let managed = YJson.parseDocument("{\\"n\\":42}")
    if (managed.root().get("n").getOrThrow().asInt64() != 42) { throw Exception("native accel") }
    try (document = YJsonAdvanced.parseDocumentWithBackend("{\\"n\\":42}",
        NativeCompactDocumentBackend)) {
        if (document.getRootInt("n").getOrThrow() != 42) { throw Exception("native advanced") }
    }
    let codec = YJson.arrayCodec(Int64Json)
    let streamOutput = YJsonMemoryOutputStream()
    YJsonAdvanced.encodeToStreamWithBackend(codec, [1, 2, 3], streamOutput,
        NativeCompactWholeDocumentStreamBackend)
    let streamed = YJsonAdvanced.decodeFromStreamWithBackend(codec,
        YJsonByteArrayInputStream(streamOutput.toByteArray()), NativeCompactWholeDocumentStreamBackend)
    if (streamed.size != 3 || streamed[2] != 3) { throw Exception("native stream") }
    for (vector in ["null", " true \\r\\n", "-0.125e+2", "\\\"\\\\u4E2D\\\\uD83D\\\\uDE42\\\"",
        "[null,true,false,-9223372036854775808,18446744073709551615,1.25e-3]",
        "{\\"nested\\":[{\\"x\\":1},[]]}"]) {
        try (advanced = YJsonAdvanced.parseDocumentWithBackend(vector, NativeCompactDocumentBackend)) {
            let expected = YJson.stringify(YJson.parse(vector))
            if (YJson.stringify(advanced.materialize()) != expected) { throw Exception("native semantic") }
        }
    }
    for (vector in ["\\\"unterminated", "\\\"bad\\\\xescape\\\"", "\\\"\\\\uD83Dvalue\\\"", "01",
        "[1,]", "{\\"a\\" 1}", "{\\"a\\":true} trailing"]) {
        if (!nativeRejects(vector)) { throw Exception("native invalid semantic") }
    }
    let text = YJson.encodeStringWith(codec, [1, 2, 3], config: JsonWriteConfig.pretty)
    let bytes = String.fromUtf8(YJson.encodeBytesWith(codec, [1, 2, 3], config: JsonWriteConfig.pretty))
    let target = YJsonMemoryOutputStream()
    YJson.encodeToStreamWith(codec, [1, 2, 3], target, config: JsonWriteConfig.pretty)
    if (bytes != text || target.toUtf8String() != text) { throw Exception("native writer targets") }
    let html = YJson.encodeStringWith(StringJson, "<tag>",
        config: JsonWriteConfig("", "", false, true))
    if (html != "\\\"\\\\u003ctag\\\\u003e\\\"") { throw Exception("native html safe") }
    try {
        let _ = YJson.encodeBytesWith(StringJson, "long",
            config: JsonWriteConfig("", "", false, false, limits: JsonWriteLimits(maxBytes: 3)))
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
        try (document = YJsonAdvanced.parseDocumentWithBackend(text, YyjsonDocumentBackend)) {
            let _ = document.materialize()
        }
        false
    } catch (_: JsonException) { true }
}
main(): Unit {
    try (document = YJsonAdvanced.parseDocumentWithBackend("{\\"n\\":42}", YyjsonDocumentBackend)) {
        if (document.getRootInt("n").getOrThrow() != 42) { throw Exception("yyjson") }
    }
    let codec = YJson.arrayCodec(Int64Json)
    let streamOutput = YJsonMemoryOutputStream()
    YJsonAdvanced.encodeToStreamWithBackend(codec, [1, 2, 3], streamOutput,
        YyjsonWholeDocumentStreamBackend)
    let streamed = YJsonAdvanced.decodeFromStreamWithBackend(codec,
        YJsonByteArrayInputStream(streamOutput.toByteArray()), YyjsonWholeDocumentStreamBackend)
    if (streamed.size != 3 || streamed[2] != 3) { throw Exception("yyjson stream") }
    for (vector in ["null", " true \\r\\n", "-0.125e+2", "\\\"\\\\u4E2D\\\\uD83D\\\\uDE42\\\"",
        "[null,true,false,-9223372036854775808,18446744073709551615,1.25e-3]",
        "{\\"nested\\":[{\\"x\\":1},[]]}"]) {
        try (advanced = YJsonAdvanced.parseDocumentWithBackend(vector, YyjsonDocumentBackend)) {
            let expected = YJson.stringify(YJson.parse(vector))
            if (YJson.stringify(advanced.materialize()) != expected) { throw Exception("yyjson semantic") }
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
