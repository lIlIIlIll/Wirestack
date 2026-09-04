# 配置与错误

yjson 使用 immutable options 表达读取和写出策略。普通、generated、stream、managed
document 和显式 backend 入口复用相同的选项类型。

## 读取选项

```cangjie
let options = JsonReadOptions(
    unknownFieldPolicy: JsonUnknownFieldPolicy.Reject,
    duplicateKeyPolicy: JsonDuplicateKeyPolicy.Reject,
    maxInputBytes: 8 * 1024 * 1024,
    maxStringBytes: 1024 * 1024,
    maxBufferedValueBytes: 4 * 1024 * 1024,
    maxDepth: 128
)
```

`JsonReadOptions.defaults` 的值为：

| 选项 | 默认值 | 语义 |
| --- | ---: | --- |
| `unknownFieldPolicy` | `Ignore` | typed decode 遇到未知字段时忽略 |
| `duplicateKeyPolicy` | `Reject` | 拒绝语义重复的 object key |
| `maxInputBytes` | 64 MiB | 单个输入 document 的 UTF-8 bytes |
| `maxStringBytes` | 16 MiB | 解码后的 string 或 key UTF-8 bytes |
| `maxBufferedValueBytes` | 8 MiB | replay/whole-value buffer 的 bytes |
| `maxDepth` | 256 | array/object 嵌套深度 |

四个数值预算必须大于零。读取端没有“0 表示 unlimited”的捷径；需要更大边界时传入明确
正数。重复 key 的比较使用解码后的 key，因此 `"a"` 与 `"\u0061"` 视为同一个 key。
`LastWins` 是显式 opt-in。

## 写出选项

```cangjie
let compact = JsonWriteOptions.defaults
let pretty = JsonWriteOptions.pretty()
let bounded = JsonWriteOptions(
    indent: "  ",
    htmlSafe: true,
    maxOutputBytes: 8 * 1024 * 1024,
    maxDepth: 128
)
```

`indent` 只能包含空格或 tab；空字符串表示紧凑输出。`maxDepth` 必须大于零。
`maxOutputBytes = 0` 表示不设置输出 byte 上限，其他负数会被拒绝。`htmlSafe` 对需要安全
嵌入 HTML 的字符使用转义。

`JsonWriteOptions.compact`、`defaults` 和 `pretty()` 是常用预设。
`htmlSafePreset` 只启用 HTML-safe escaping。

## 一个异常类型

解析、codec、文档、backend 和算法失败统一抛出 `JsonException`：

```cangjie
try {
    let value = JsonNode.parse(input)
} catch (error: JsonException) {
    println(error.code)
    println(error.path)
}
```

调用方匹配 `error.code`，不要解析 message。`path` 为空或 RFC 6901 JSON Pointer；适用的
解析失败在 `location` 中携带 byte offset、line 和 column。

`invalid_value` 是稳定 code：用于语法合法但目标类型转换失败、且不落入 `number_out_of_range`
（数字字面量超出数值范围）的场景，例如 Rune codec 收到多个 Unicode scalar。它不用于
JSON 结构错误（`parse_error`）或类型形状错误（`type_mismatch`）。

常用稳定 code：

| code | 含义 |
| --- | --- |
| `parse_error` | JSON token、UTF-8、trailing content 或文档结构无效 |
| `unknown_field` | Reject 策略遇到未知 typed 字段 |
| `duplicate_key` | Reject 策略遇到重复 key |
| `missing_field` | generated codec 的必需字段缺失 |
| `missing_discriminator` / `unknown_discriminator` | generated polymorphic discriminator 无效 |
| `max_depth` | 读取、写出或 materialization 超过深度 |
| `document_too_large` | 输入 document 超过 byte budget |
| `string_too_large` | 解码后的 string/key 超过预算 |
| `buffered_value_too_large` | replay 或 whole-value buffer 超过预算 |
| `output_too_large` | 写出超过 byte budget |
| `writer_state` | writer 根值数量或容器状态无效 |
| `cyclic_json_node` | AST 递归操作遇到祖先环 |
| `type_mismatch` / `number_out_of_range` | value 不满足目标类型；数字字面量超出目标范围 |
| `invalid_value` | 语法合法但目标类型转换失败且非范围问题（如 Rune 需要恰好一个 Unicode scalar） |
| `codec_contract` / `codec_type_mismatch` | custom/generated codec contract 无效 |
| `resource_closed` | 关闭后访问显式 backend document |
| `invalid_json_pointer` / `json_pointer_not_found` | Pointer 无效或目标不存在 |
| `invalid_json_patch` / `json_patch_test_failed` | Patch 无效或 test 失败 |
| `invalid_json_path` / `invalid_regex` | Path 或受限 regex 无效 |
| `unsupported_schema_dialect` | Schema 不是 draft 2020-12 |
| `work_limit_exceeded` | materialization 或算法预算耗尽 |

acceleration 初始化和运行期失败也使用 `JsonException`，code 以 `acceleration_` 开头。
具体资源语义见[资源限制](resource-limits.md)。

