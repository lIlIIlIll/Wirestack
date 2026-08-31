# yjson_schema_formats

可选 JSON Schema format provider，覆盖 hostname、国际化 hostname/email、URI/IRI reference
和 RFC 6570 URI Template。package 使用系统 `libidn2` 完成 IDNA2008 相关验证。

```cangjie
import yjson_algorithms.*
import yjson_schema_formats.*

let formats = JsonSchemaFormatRegistry.withCoreFormats()
formats.install(StandardInternationalFormats())

let config = JsonSchemaConfig(
    formatMode: JsonSchemaFormatMode.Assertion,
    formats: formats
)
let schema = JsonSchema.parse(schemaText, config: config)
```

默认 `Annotation` 模式不执行 format assertion。`Assertion` 只执行已注册 format；未知
format 保留 annotation 语义，不构成 validation 失败。

`JsonSchema` 构造时获取 registry 的 frozen copy，后续修改原 registry 不影响已编译 schema。
Schema dialect、resolver 和 conformance 说明见
[JSON Schema](../../docs/schema.md)。

