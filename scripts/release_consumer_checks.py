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


def run_fixture(name: str, dependencies: str, source: str, base: pathlib.Path) -> None:
    project = base / name
    (project / "src").mkdir(parents=True)
    manifest = f'''[package]
cjc-version = "1.1.0"
name = "yjson_release_{name}"
version = "0.0.0"
output-type = "executable"
compile-option = "-O2"

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
    parser.add_argument(
        "--only", choices=("core", "macro", "native", "yyjson"), action="append"
    )
    args = parser.parse_args()
    selected = set(args.only or ("core", "macro", "native", "yyjson"))
    modules = args.modules_root.resolve() if args.modules_root else None
    base = pathlib.Path(tempfile.mkdtemp(prefix="yjson-consumers-"))
    try:
        core = quote(modules / "yjson" if modules else ROOT)
        aggregate = quote(modules / "yjson_all" if modules else ROOT / "packages" / "yjson_all")
        native = quote(modules / "yjson_native" if modules else ROOT / "packages" / "yjson_native")
        native_accel = quote(modules / "yjson_native_accel" if modules else ROOT / "packages" / "yjson_native_accel")
        backends = quote(modules / "yjson_backends" if modules else ROOT / "packages" / "yjson_backends")
        yyjson = quote(modules / "yjson_yyjson" if modules else ROOT / "packages" / "yjson_yyjson")
        if "core" in selected:
            run_fixture("core", f'yjson = {{ path = "{core}" }}', '''package yjson_release_core
import yjson.*
main(): Unit {
    let value = YJson.parse("{\\"ok\\":true}").asObject()
    if (!value.get("ok").getOrThrow().asBool().value) { throw Exception("core") }
    let compact = YJson.parseCompact(unsafe { "[1,2,3]".rawData() })
    if (compact.root().get(2).getOrThrow().asInt64() != 3) { throw Exception("compact") }
    println("core consumer passed")
}
''', base)
        if "macro" in selected:
            run_fixture("macro", f'yjson_all = {{ path = "{aggregate}" }}', '''package yjson_release_macro
import yjson_all.*
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
''', base)
        if "native" in selected:
            run_fixture("native", f'''yjson = {{ path = "{core}" }}
yjson_native = {{ path = "{native}" }}
yjson_native_accel = {{ path = "{native_accel}" }}
yjson_backends = {{ path = "{backends}" }}''', '''package yjson_release_native
import yjson.*
import yjson_native.*
import yjson_native_accel.*
import yjson_backends.*
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
    println("native consumer passed")
}
''', base)
        if "yyjson" in selected:
            run_fixture("yyjson", f'''yjson = {{ path = "{core}" }}
yjson_yyjson = {{ path = "{yyjson}" }}
yjson_backends = {{ path = "{backends}" }}''', '''package yjson_release_yyjson
import yjson.*
import yjson_yyjson.*
import yjson_backends.*
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
    println("yyjson consumer passed")
}
''', base)
    finally:
        shutil.rmtree(base)
    return 0


if __name__ == "__main__":
    sys.exit(main())
