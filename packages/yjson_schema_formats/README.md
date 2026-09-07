# yjson_schema_formats

本包为 JSON Schema 增加 hostname、国际化 hostname 和 email、URI 与 IRI reference、
RFC 6570 URI Template 格式校验。IDNA2008 相关校验使用系统 `libidn2`。

## 构建要求

构建需要 `libidn2` 开发文件（包含 `idn2.h`）、C 编译器和 `ar`。
编译器默认使用 `clang`，可通过 `CC` 指定。Debian 和 Ubuntu 的开发包名为
`libidn2-dev`，只安装运行库不足以编译本包。运行时也需要 `libidn2`。

## 启用格式校验

将格式实现注册到 `JsonSchemaFormatRegistry`，再选择 `Assertion` 模式。
下面的 `schemaText` 是待编译的 Schema 文本：

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

默认的 `Annotation` 模式仅记录格式注解，不执行校验。`Assertion` 只校验已注册的格式；
未知格式仍作为注解，不会导致校验失败。

`JsonSchema` 构造时会复制并冻结格式注册表。之后修改原注册表，不影响已经构造的 Schema。
方言、引用解析和标准符合性说明见 [JSON Schema](../../docs/schema.md)。
