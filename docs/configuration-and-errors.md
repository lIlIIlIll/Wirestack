# 配置与错误

yjson 的读取与写出策略都通过不可隐式猜测的 config 传入。默认配置适合可信输入和兼容
行为；服务端接收不可信内容时，应显式设置预算。

## 读取配置

```cangjie
let config = JsonReadConfig(
    unknownFieldPolicy: JsonUnknownFieldPolicy.Ignore,
    duplicateKeyPolicy: JsonDuplicateKeyPolicy.LastWins,
    numberPolicy: JsonNumberPolicy.Int64WhenExact,
    includeErrorLocation: true,
    limits: JsonReadLimits(
        maxDepth: 256,
        maxBytes: 0,
        maxStringBytes: 0,
        maxPolymorphicObjectBytes: 0
    )
)
```

三个 byte limit 的 `0` 都表示 unlimited；`maxDepth` 必须为正数。`PreserveLiteral` 保留
非结构化 number token 的文本表示。未知 typed 字段与重复 key 可分别切换为 Reject。

具体预算语义、入口覆盖和 Native 一致性见 [资源限制](resource-limits.md)。

## 写出配置

- `JsonWriteConfig.compact`：紧凑输出。
- `JsonWriteConfig.pretty`：换行和四空格缩进。
- `YJson.stringifyPretty(value)`：便利入口，默认两空格缩进。

自定义配置还控制 newline、indent、separator space、HTML-safe escaping、错误位置、最大
深度与 `maxBytes`。写出预算超限使用 `output_too_large`。Stream 失败可能已写出前缀，
但已提交长度不会超过 `maxBytes`；失败后不要继续复用该 writer。writer 只接受一个完整根值。

旧式 `JsonValueCodec<T>` 的 `YJsonAst.encodeWith/decodeWith` 只支持默认
`JsonCodecConfig.compact`。传入非默认 read/write 配置会抛出 `unsupported_config`；需要配置
生效时使用 `JsonCodec<T>` 与 `YJson` 的显式入口。

## 按稳定错误码处理

解析、codec 和预算失败使用 `JsonException`。调用方应匹配 `error.code`，不要解析 message。

| code | 含义 |
| --- | --- |
| `parse_error` | JSON token、UTF-8 或文档结构无效 |
| `unknown_field` | Reject 策略遇到未知 typed 字段 |
| `duplicate_key` | Reject 策略遇到重复 key |
| `missing_field` | generated codec 必需字段缺失 |
| `missing_discriminator` / `unknown_discriminator` | 多态 discriminator 错误 |
| `max_depth` | 读取或写出超过嵌套深度 |
| `document_too_large` | 文档 byte budget 或表示上限触发 |
| `string_too_large` | decoded UTF-8 string 超出预算 |
| `polymorphic_object_too_large` | 根多态对象 replay budget 触发 |
| `output_too_large` | 写出超过 byte budget |
| `writer_state` | writer 没有根值、存在多个根值或结构未闭合 |
| `cyclic_json_node` | 递归 AST 操作遇到祖先环 |
| `invalid_value` | typed scalar 值不满足 codec contract，例如 Rune 不是一个 Unicode scalar |
| `unsupported_config` | API 收到无法执行的非默认配置 |
| `codec_type_mismatch` / `codec_contract` | erased 类型或 fast contract 错误 |
| `missing_key` / `index_out_of_bounds` | AST 查询失败 |
| `invalid_json_pointer` / `json_pointer_not_found` | Pointer 错误 |
| `invalid_json_patch` / `json_patch_test_failed` | Patch 错误 |
| `invalid_json_path` | JSONPath 表达式无效 |
| `unsupported_schema_dialect` | Schema 不是 draft 2020-12 |
| `unsupported_schema_format` | StrictAssertion 遇到未知 format |
| `work_limit_exceeded` | JSONPath、Patch/Merge Patch 或 Schema 工作预算耗尽 |

`includeErrorLocation` 为 true 时，适用的 parse/limit 错误携带 offset、line 和 column；
语义错误不保证具有同样的位置粒度。
