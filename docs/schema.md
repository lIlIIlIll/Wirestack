# JSON Schema draft 2020-12

yjson 只解释 draft 2020-12。显式 `$schema` 声明其他 dialect 时返回
`unsupported_schema_dialect`，避免把不同 draft 的同名 keyword 静默解释错。

## 最小校验

```cangjie
let schema = JsonSchema.parse("""
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "type": "object",
  "required": ["name"],
  "properties": {"name": {"type": "string", "minLength": 1}},
  "additionalProperties": false
}
""")

schema.validateOrThrow(YJson.parse("{\"name\":\"Alice\"}"))
```

- `validate` 返回全部 `JsonValidationError`；错误包含 instance `jsonPath` 和 keyword
  `schemaPath`。
- `isValid` 只返回 Bool。
- `validateOrThrow` 抛出第一个错误。

## 支持的语义

实现覆盖 draft 2020-12 core、validation 与 applicator 的 required suite，包括 reference、
dynamic reference、对象/数组 applicator、组合关键字、unevaluated 关键字和 Decimal 数值
比较。annotation keyword 可以保留，但不改变 validation 结果。

数值相等按数值而不是 token 拼写判断：`1`、`1.0` 与 `1e0` 相等且都满足 integer。

## 外部资源

core 不访问网络。应用通过 `JsonSchemaResolver` 提供资源：

```cangjie
let registry = JsonSchemaRegistry()
registry.register("urn:example:types", """
{"$defs":{"id":{"$anchor":"id","type":"integer","minimum":1}}}
""")

let config = JsonSchemaConfig(resolver: Some<JsonSchemaResolver>(registry))
let schema = JsonSchema.parse("{\"$ref\":\"urn:example:types#id\"}", config: config)
```

registry key 不含 fragment；fragment 可以是 JSON Pointer 或 `$anchor`。文件、缓存、网络、
鉴权和超时策略由应用实现。`JsonSchema` 复制 schema document；公开 `document` 每次返回
独立副本。resolver 仍是实时依赖，需要可重复结果时应冻结其资源集合。

## Format

| 模式 | 已注册 format | 未注册 format |
| --- | --- | --- |
| `Annotation` | 不执行 | 不执行；默认 |
| `Assertion` | 执行 | 保留 annotation 语义 |
| `StrictAssertion` | 执行 | `unsupported_schema_format` |

core 提供常用日期、时间、IP、UUID、regex 与 pointer formats。国际化 hostname/email、
URI/IRI 和 RFC 6570 URI Template 由可选 `yjson_schema_formats` 提供：

```cangjie
let formats = JsonSchemaFormatRegistry.withCoreFormats()
formats.install(StandardInternationalFormats())
let config = JsonSchemaConfig(
    formatMode: JsonSchemaFormatMode.Assertion,
    formats: formats
)
```

registry 应在配置阶段完成修改；共享给并发 validation 后不得继续注册或替换 format。

## Conformance 证据

固定 revision 的公开 consumer 当前记录 required 1299/1299、JSONPath CTS 703/703、JSON
Patch 108/108。安装 optional format provider 后，适用 optional Schema cases 为 964/964。
数字属于对应 release evidence；稳定测试政策见[测试指南](maintainers/testing.md)。
