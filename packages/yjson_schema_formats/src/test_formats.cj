package yjson_schema_formats

import std.unittest.*
import std.unittest.testmacro.*
import yjson.*

private func formatAccepts(name: String, value: String): Bool {
    let formats = JsonSchemaFormatRegistry.withCoreFormats()
    formats.install(StandardInternationalFormats())
    let config = JsonSchemaConfig(formatMode: JsonSchemaFormatMode.StrictAssertion, formats: formats)
    JsonSchema.parse("{\"format\":\"${name}\"}", config: config)
        .validator().isValid(JsonStringValue(value))
}

@Test
class InternationalSchemaFormatsTest {
    @TestCase
    func idnaUsesContextAndBidiRules(): Unit {
        @Expect(formatAccepts("idn-hostname", "실례.테스트"))
        @Expect(formatAccepts("hostname", "xn--9n2bp8q.xn--9t4b11yi5a"))
        @Expect(!formatAccepts("idn-hostname", "a·l"))
        @Expect(!formatAccepts("idn-hostname", "0a.א"))
    }

    @TestCase
    func uriIriAndTemplateAreRegistered(): Unit {
        @Expect(formatAccepts("uri", "https://example.com/a?b=c#d"))
        @Expect(formatAccepts("iri", "https://例え.テスト/路径"))
        @Expect(formatAccepts("uri-template", "https://example.com{/segments*}{?query}"))
        @Expect(!formatAccepts("uri", "https://[@example.org/test.txt"))
    }
}
