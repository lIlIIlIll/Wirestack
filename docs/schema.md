# JSON Schema draft 2020-12

yjson 的 Schema 入口固定为 draft 2020-12。显式 `$schema` 若声明其他 draft，会以
`unsupported_schema_dialect` 拒绝，避免把不同 dialect 的同名 keyword 静默解释错。

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

`validate` 返回 `ArrayList<JsonValidationError>`；错误包含 instance 的 `jsonPath` 和
keyword 的 `schemaPath`。`isValid` 只返回布尔值，`validateOrThrow` 抛出第一个错误。

## Vocabulary 与关键字

当前 validator 覆盖：

- core：boolean/object schema、`$schema`、`$defs`、`$ref`、`$dynamicRef`、`$anchor`、`$dynamicAnchor`；
- validation：`type`、`enum`、`const`、`multipleOf`、四种数值边界、字符串/数组/对象大小、
  `pattern`、`required`、`dependentRequired`、`uniqueItems`；
- applicator：`properties`、`patternProperties`、`additionalProperties`、`propertyNames`、
  `prefixItems`、`items`、`contains`、`minContains`、`maxContains`、`dependentSchemas`、
  `unevaluatedItems`、`unevaluatedProperties`、`allOf`、`anyOf`、`oneOf`、`not`、`if/then/else`；
- annotation keyword 可以留在 schema 中，不改变 validation 结果。

数值比较和 `multipleOf` 使用 `Decimal`，不会先降为 `Float64`；JSON 数字的相等性按数值
而不是 token 拼写判断，例如 `1`、`1.0` 与 `1e0` 相等且都满足 `integer`。

## 外部 reference

core 不访问网络。应用通过 resolver 提供资源；内存 registry 是默认实现：

```cangjie
let registry = JsonSchemaRegistry()
registry.register("urn:example:types", """
{"$defs":{"id":{"$anchor":"id","type":"integer","minimum":1}}}
""")

let config = JsonSchemaConfig(resolver: Some<JsonSchemaResolver>(registry))
let schema = JsonSchema.parse("{\"$ref\":\"urn:example:types#id\"}", config: config)
```

registry key 是不带 fragment 的资源 URI；fragment 可以是 JSON Pointer 或 `$anchor`。
自定义 `JsonSchemaResolver` 可以从磁盘或应用缓存读取，但网络策略、缓存、鉴权与超时均由
应用负责。

## format

draft 2020-12 默认把 `format` 作为 annotation。yjson 明确区分三种模式：

| 模式 | 已注册 format | 未注册 format |
| --- | --- | --- |
| `Annotation` | 不执行 | 不执行；draft 2020-12 默认 |
| `Assertion` | 执行断言 | 保留 annotation 语义 |
| `StrictAssertion` | 执行断言 | 返回 `unsupported_schema_format` |

core registry 提供 `date`、`time`、`date-time`、`duration`、`email`、`ipv4`、`ipv6`、
`uuid`、`regex`、`json-pointer` 与 `relative-json-pointer`。需要断言时显式启用：

```cangjie
let config = JsonSchemaConfig(formatMode: JsonSchemaFormatMode.Assertion)
let schema = JsonSchema.parse("{\"format\":\"ipv4\"}", config: config)
```

应用格式通过 registry 扩展：

```cangjie
public class OrderIdFormat <: JsonSchemaFormat {
    public func validate(value: String): Bool { value.startsWith("order_") }
}

let formats = JsonSchemaFormatRegistry.withCoreFormats()
formats.register("order-id", OrderIdFormat())
let config = JsonSchemaConfig(
    formatMode: JsonSchemaFormatMode.StrictAssertion,
    formats: formats
)
```

国际化 hostname/email、URI/IRI 和 RFC 6570 URI Template 位于可选
`yjson_schema_formats` package。它通过系统 `libidn2` 执行 IDNA2008、Punycode round-trip、
Bidi、ContextJ/ContextO 校验，避免把国际化表和 native 依赖带入 core：

```cangjie
import yjson_schema_formats.*

let formats = JsonSchemaFormatRegistry.withCoreFormats()
formats.install(StandardInternationalFormats())
let config = JsonSchemaConfig(
    formatMode: JsonSchemaFormatMode.Assertion,
    formats: formats
)
```

`Annotation` 在 keyword dispatch 时直接返回，不调用 registry 或 provider。registry 的重复
名称默认拒绝；只有显式 `replace: true` 才覆盖已有断言。registry 只应在配置阶段修改；把
`JsonSchemaConfig` 共享给并发调用后，不得继续注册或替换 format。

## 官方 conformance gate

仓库通过独立 public-API consumer 运行固定 revision 的 JSON Schema Test Suite：

- suite：`json-schema-org/JSON-Schema-Test-Suite`；
- draft 2020-12 required tests：**1299/1299 PASS**。

安装 `StandardInternationalFormats` 后，适用于本 dialect 的 optional tests 为
**964/964 PASS**。完整三套标准测试合计 **3074/3074 PASS**；默认不安装 provider 的 gate
仍为 **2110/2110 PASS**，证明 required vocabulary、JSONPath 与 JSON Patch 不依赖可选
format assertion。
