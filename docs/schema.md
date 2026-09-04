# JSON Schema draft 2020-12

`JsonSchema` 位于可选 `yjson_algorithms` package，只解释 draft 2020-12。显式声明其他
dialect 时抛出 `JsonException(code: "unsupported_schema_dialect")`。

```cangjie
import yjson.*
import yjson_algorithms.*
```

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

let result = schema.validate(JsonNode.parse("{\"name\":\"Alice\"}"))
if (!result.valid) {
    println(result[0].instancePath)
    println(result[0].schemaPath)
}
```

`validate` 返回 immutable `JsonSchemaResult`；它提供 `valid`、`size`、索引访问和
`violations()`。`isValid` 只返回 Bool。`JsonSchemaViolation` 同时记录 instance 的
`instancePath`、keyword 的 `schemaPath`、code 和 message。

数值比较按 JSON 数值语义，而不是 token 拼写：`1`、`1.0` 与 `1e0` 相等，并且都满足
integer。

## 外部资源在构造时冻结

yjson 不访问网络。应用通过 `UriResolver` 提供外部 resource：

```cangjie
let registry = JsonSchemaRegistry()
registry.register(
    "urn:example:types",
    "{\"$defs\":{\"id\":{\"$anchor\":\"id\",\"type\":\"integer\",\"minimum\":1}}}"
)

let config = JsonSchemaConfig(resolver: Some<UriResolver>(registry))
let schema = JsonSchema.parse(
    "{\"$ref\":\"urn:example:types#id\"}",
    config: config
)
```

registry key 是不带 fragment 的 resource URI。构造 `JsonSchema` 时会复制根 schema，遍历并
解析完整外部引用图，再编译全部 schema regex。成功返回后：

- compiled schema 不再持有 resolver；`schema.config.resolver` 为 `None`；
- validation 不访问文件、网络、缓存或可变 registry；
- `schema.document` 每次返回独立副本；
- schema、validator 和 result 可并发读取。

resolver 的 I/O、鉴权、缓存和超时由应用在构造阶段负责。循环和重复 reference 由编译图处理，
ref resolution 受 `JsonSchemaLimits.maxRefResolutions` 约束。

## Format

`JsonSchemaFormatMode` 只有两种：

| 模式 | 已注册 format | 未注册 format |
| --- | --- | --- |
| `Annotation` | 不执行 | 不执行；默认 |
| `Assertion` | 执行 | 保留 annotation 语义 |

core registry 提供 date、time、date-time、duration、email、IPv4/IPv6、UUID、regex、JSON
Pointer 和 relative JSON Pointer。国际化 hostname/email、URI/IRI 和 RFC 6570 URI Template
由 `yjson_schema_formats` 提供：

```cangjie
let formats = JsonSchemaFormatRegistry.withCoreFormats()
formats.install(StandardInternationalFormats())

let config = JsonSchemaConfig(
    formatMode: JsonSchemaFormatMode.Assertion,
    formats: formats
)
let schema = JsonSchema.parse(schemaText, config: config)
```

`JsonSchema` 构造时取得 registry 的 frozen copy。之后修改原 registry 不会改变已编译 schema；
默认 registry 本身也是 immutable。

`JsonSchemaFormat` 实现必须保持 immutable 或自行同步：应用可以并发调用同一个 validator
instance（以及同一个 format instance），yjson 不在 format 断言周围加锁。共享可变状态
（缓存、计数器、惰性初始化）由实现自行同步。

## Regex 和工作预算

Schema `pattern` 使用内部线性时间、非回溯 regex 引擎。构造阶段拒绝反向引用等不属于
受支持正则子集的特性，code 为 `invalid_regex`。`regex` format 只进行有界的 ECMAScript
语法验证，因此接受命名分组、反向引用和 lookbehind，但不会执行这些表达式。解析和匹配
工作量都受 `maxRegexSteps` 限制。

`JsonSchemaLimits.defaults` 设置 100,000 evaluations、1,000 ref resolutions、100,000 regex
steps、100 errors 和 depth 256。预算耗尽抛出
`JsonException(code: "work_limit_exceeded")`。可信离线任务可以显式使用
`JsonSchemaLimits.unlimited`。

## Conformance 门禁

固定 corpus 的预期 cardinality 为 Schema required 1299、JSONPath CTS 703、JSON Patch 108；
安装 optional format provider 后增加 964 个适用 Schema cases。数字是 runner 的输入约束，
实际 PASS/FAIL 必须记录在对应 release evidence。入口和证据规则见
[测试指南](maintainers/testing.md)。
