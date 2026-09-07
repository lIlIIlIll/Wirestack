# JSON Schema draft 2020-12

`JsonSchema` 位于可选包 `yjson_algorithms`，只支持 draft 2020-12。显式声明其他
方言时抛出 `JsonException(code: "unsupported_schema_dialect")`。

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

`validate` 返回不可变的 `JsonSchemaResult`，提供 `valid`、`size`、索引访问和
`violations()`。`isValid` 只返回 Bool。`JsonSchemaViolation` 记录数据位置 `instancePath`、
规则位置 `schemaPath`、错误码和消息。

数值比较不受写法影响：`1`、`1.0` 与 `1e0` 相等，并且都满足 `integer` 类型约束。

## 外部资源在构造时冻结

yjson 不访问网络。应用通过 `UriResolver` 提供外部资源：

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

注册表的键是去掉片段标识符（`#` 及其后内容）的资源 URI。构造 `JsonSchema` 时会复制
根 Schema，解析所有外部引用，再编译其中的正则表达式。成功返回后：

- 编译后的 Schema 不再持有 resolver，`schema.config.resolver` 为 `None`；
- 校验不访问文件、网络、缓存或可变注册表；
- `schema.document` 每次返回独立副本；
- Schema、校验器和结果可并发读取。

resolver 的 I/O、鉴权、缓存和超时由应用在构造阶段负责。编译器处理循环和重复引用，
引用解析次数受 `JsonSchemaLimits.maxRefResolutions` 约束。

## 格式校验

`JsonSchemaFormatMode` 只有两种：

| 模式 | 已注册格式 | 未注册格式 |
| --- | --- | --- |
| `Annotation` | 不执行 | 不执行；默认 |
| `Assertion` | 执行 | 仅作注解 |

核心注册表提供 date、time、date-time、duration、email、IPv4/IPv6、UUID、regex、JSON
Pointer 和 relative JSON Pointer。国际化主机名和邮箱、URI/IRI，以及 RFC 6570 URI Template
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

`JsonSchema` 构造时保存注册表的不可变副本。之后修改原注册表不会影响已编译的 Schema；
默认注册表本身也不可变。

`JsonSchemaFormat` 实现必须保持不可变或自行同步。应用可以并发调用同一个校验器和
格式实例，yjson 不会为格式校验加锁。若实现包含缓存、计数器或惰性初始化，需要自行同步。

## 正则表达式和工作量限制

Schema `pattern` 使用内部线性时间、非回溯正则引擎。构造阶段拒绝反向引用等不属于
受支持正则子集的特性，错误码为 `invalid_regex`。`regex` 格式只进行有界的 ECMAScript
语法验证，因此接受命名分组、反向引用和 lookbehind，但不会执行这些表达式。解析和匹配
工作量都受 `maxRegexSteps` 限制。

`JsonSchemaLimits.defaults` 最多允许 100,000 次求值、1,000 次引用解析、100,000 个正则
步骤、100 条错误和 256 层深度。预算耗尽抛出
`JsonException(code: "work_limit_exceeded")`。可信离线任务可以显式使用
`JsonSchemaLimits.unlimited`。

## 标准符合性测试

固定语料包含 1299 个必测 Schema 用例、703 个 JSONPath CTS 用例和 108 个 JSON Patch 用例。
安装可选格式扩展后，增加 964 个适用的 Schema 用例。这些数量用于检查语料是否完整，
每次运行的 PASS/FAIL 另行记录在发布证据中。测试入口和记录要求见
[测试指南](maintainers/testing.md)。
