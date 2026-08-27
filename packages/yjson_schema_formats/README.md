# yjson_schema_formats

可选 JSON Schema format provider，覆盖国际化 hostname/email、URI/IRI reference 与 RFC
6570 URI Template。package 使用系统 `libidn2` 完成 IDNA2008、Punycode round-trip、Bidi
和 ContextJ/ContextO 验证。

```cangjie
import yjson.*
import yjson_schema_formats.*

let formats = JsonSchemaFormatRegistry.withCoreFormats()
formats.install(StandardInternationalFormats())
let config = JsonSchemaConfig(
    formatMode: JsonSchemaFormatMode.Assertion,
    formats: formats
)
```

core 默认 `Annotation`，不会执行注册的 assertion。`StrictAssertion` 遇到未知 format 时
返回 `unsupported_schema_format`。registry 应在配置阶段完成修改，共享给并发 validation
后不得继续注册或替换。

Schema dialect、resolver 与 conformance 说明见 [JSON Schema](../../docs/schema.md)。
