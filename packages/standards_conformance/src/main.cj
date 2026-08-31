package yjson_standards_conformance

import std.collection.*
import std.env.*
import std.fs.*
import std.io.*
import yjson.*
import yjson_algorithms.*
import yjson_schema_formats.*

private class SuiteStats {
    var passed: Int64 = 0
    var failed: Int64 = 0

    func pass(): Unit { passed++ }
    func fail(suite: String, source: String, description: String, detail: String): Unit {
        failed++
        println("FAIL\t${suite}\t${source}\t${description}\t${detail}")
    }
}

private func required(objectValue: JsonObject, name: String): JsonNode {
    objectValue.get(name).getOrThrow({ => Exception("manifest is missing '${name}'") })
}

private func optionalBool(objectValue: JsonObject, name: String): Bool {
    match (objectValue.get(name)) {
        case Some(value) => value.asBool()
        case None => false
    }
}

private func readJson(path: String): JsonNode {
    var result: Option<JsonNode> = None<JsonNode>
    try (file = File(path, OpenMode.Read)) {
        result = Some(JsonNode.parse(readToEnd(file),
            config: JsonReadOptions()))
    }
    result.getOrThrow({ => Exception("failed to read manifest ${path}") })
}

private func runSchema(manifest: JsonObject, stats: SuiteStats): Unit {
    let registry = JsonSchemaRegistry()
    let formats = JsonSchemaFormatRegistry.withCoreFormats()
    if (optionalBool(manifest, "install_format_plugin")) {
        formats.install(StandardInternationalFormats())
    }
    let remotes = required(manifest, "remotes").asObject()
    for (remoteIndex in 0..remotes.size()) {
        registry.register(remotes.nameAt(remoteIndex), remotes.valueAt(remoteIndex))
    }
    let files = required(manifest, "files").asArray()
    for (fileIndex in 0..files.size()) {
        let fileObject = files[fileIndex].asObject()
        let source = required(fileObject, "source").asString()
        let formatMode = if (optionalBool(fileObject, "format_assertion")) {
            JsonSchemaFormatMode.Assertion
        } else { JsonSchemaFormatMode.Annotation }
        let config = JsonSchemaConfig(resolver: Some<UriResolver>(registry),
            formatMode: formatMode, formats: formats)
        let groups = required(fileObject, "groups").asArray()
        for (groupIndex in 0..groups.size()) {
            let group = groups[groupIndex].asObject()
            let groupDescription = required(group, "description").asString()
            let schemaNode = required(group, "schema")
            let tests = required(group, "tests").asArray()
            for (testIndex in 0..tests.size()) {
                let test = tests[testIndex].asObject()
                let description = groupDescription + " / " + required(test, "description").asString()
                let expected = required(test, "valid").asBool()
                var actual = false
                var detail = ""
                try {
                    let errors = JsonSchema.fromValue(schemaNode, config: config).validate(required(test, "data"))
                    actual = errors.isEmpty()
                    if (!actual) { detail = errors[0].message }
                } catch (error: Exception) {
                    detail = "exception: ${error.message}"
                }
                if (actual == expected) { stats.pass() }
                else { stats.fail("json-schema", source, description,
                    if (detail.isEmpty()) { "expected=${expected}, actual=${actual}" }
                    else { "expected=${expected}, actual=${actual}, ${detail}" }) }
            }
        }
    }
}

private func jsonNodeListsEquivalent(actual: ArrayList<JsonNode>, expected: JsonArray): Bool {
    if (actual.size != expected.size()) { return false }
    for (index in 0..actual.size) {
        if (!actual[index].equivalentTo(expected[index])) { return false }
    }
    true
}

private func jsonPathListsEquivalent(actual: ArrayList<String>, expected: JsonArray): Bool {
    if (actual.size != expected.size()) { return false }
    for (index in 0..actual.size) {
        if (actual[index] != expected[index].asString()) { return false }
    }
    true
}

private func matchesAnyJsonPathValueResult(actual: ArrayList<JsonNode>, test: JsonObject): Bool {
    match (test.get("result")) {
        case Some(expected) => return jsonNodeListsEquivalent(actual, expected.asArray())
        case None => ()
    }
    match (test.get("results")) {
        case Some(alternatives) =>
            let expectedValues = alternatives.asArray()
            for (index in 0..expectedValues.size()) {
                if (jsonNodeListsEquivalent(actual, expectedValues[index].asArray())) { return true }
            }
        case None => ()
    }
    false
}

private func matchesAnyJsonPathPathResult(actual: ArrayList<String>, test: JsonObject): Bool {
    match (test.get("result_paths")) {
        case Some(expected) => return jsonPathListsEquivalent(actual, expected.asArray())
        case None => ()
    }
    match (test.get("results_paths")) {
        case Some(alternatives) =>
            let expectedValues = alternatives.asArray()
            for (index in 0..expectedValues.size()) {
                if (jsonPathListsEquivalent(actual, expectedValues[index].asArray())) { return true }
            }
        case None => return true
    }
    false
}

private func runJsonPath(tests: JsonArray, stats: SuiteStats): Unit {
    for (testIndex in 0..tests.size()) {
        let test = tests[testIndex].asObject()
        let name = required(test, "name").asString()
        let selector = required(test, "selector").asString()
        let invalid = optionalBool(test, "invalid_selector")
        try {
            let path = JsonPath.parse(selector)
            if (invalid) {
                stats.fail("jsonpath", "cts.json", name, "invalid selector was accepted")
                continue
            }
            let matches = path.collect(required(test, "document"))
            let values = ArrayList<JsonNode>()
            let paths = ArrayList<String>()
            for (matched in matches) {
                values.add(matched.value.materialize())
                paths.add(matched.normalizedPath)
            }
            if (matchesAnyJsonPathValueResult(values, test) && matchesAnyJsonPathPathResult(paths, test)) {
                stats.pass()
            } else {
                stats.fail("jsonpath", "cts.json", name,
                    "selector=${selector}, values=${JsonArray(values).toString()}, paths=${paths}")
            }
        } catch (error: Exception) {
            if (invalid) { stats.pass() }
            else { stats.fail("jsonpath", "cts.json", name, "exception: ${error.message}") }
        }
    }
}

private func runJsonPatch(tests: JsonArray, stats: SuiteStats): Unit {
    for (testIndex in 0..tests.size()) {
        let test = tests[testIndex].asObject()
        let source = required(test, "source").asString()
        let description = match (test.get("comment")) {
            case Some(value) => value.asString()
            case None => "unnamed"
        }
        let expectsError = test.contains("error")
        try {
            let actual = JsonPatch.fromValue(required(test, "patch")).apply(required(test, "doc"))
            if (expectsError) { stats.fail("json-patch", source, description, "expected an error") }
            else if (actual.equivalentTo(required(test, "expected"))) { stats.pass() }
            else { stats.fail("json-patch", source, description,
                "expected=${required(test, "expected")}, actual=${actual}") }
        } catch (error: Exception) {
            if (expectsError) { stats.pass() }
            else { stats.fail("json-patch", source, description, "exception: ${error.message}") }
        }
    }
}

main(): Unit {
    let args = getCommandLine()
    if (args.size != 2) {
        println("usage: yjson_standards_conformance <manifest.json>")
        exit(2)
    }
    let manifest = readJson(args[1]).asObject()
    let stats = SuiteStats()
    runSchema(required(manifest, "schema").asObject(), stats)
    runJsonPath(required(manifest, "jsonpath").asArray(), stats)
    runJsonPatch(required(manifest, "jsonpatch").asArray(), stats)
    println("SUMMARY\tpassed=${stats.passed}\tfailed=${stats.failed}\ttotal=${stats.passed + stats.failed}")
    if (stats.failed > 0) { exit(1) }
}
