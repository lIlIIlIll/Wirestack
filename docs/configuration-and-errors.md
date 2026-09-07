# 配置与错误

用 `JsonReadOptions` 配置读取，用 `JsonWriteOptions` 配置写出。这两种配置都不可变，
可用于类型转换、流、只读文档和各后端入口。

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
| `unknownFieldPolicy` | `Ignore` | 解码为目标类型时忽略未知字段 |
| `duplicateKeyPolicy` | `Reject` | 拒绝解码后相同的对象键 |
| `maxInputBytes` | 64 MiB | 单个输入文档的 UTF-8 字节数 |
| `maxStringBytes` | 16 MiB | 解码后的字符串或键的 UTF-8 字节数 |
| `maxBufferedValueBytes` | 8 MiB | 单个完整值的缓冲区字节数，包括回放缓冲区 |
| `maxDepth` | 256 | 数组或对象的嵌套深度 |

四个数值上限必须大于零，读取选项不支持用 0 取消限制。重复键按解码后的内容比较，
因此 `"a"` 与 `"\u0061"` 视为同一个键。需要保留最后出现的值时，显式选择 `LastWins`。

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

`indent` 只能包含空格或制表符；空字符串表示紧凑输出。`maxDepth` 必须大于零。
`maxOutputBytes = 0` 表示不设置输出字节数上限，其他负数会被拒绝。`htmlSafe` 对需要安全
嵌入 HTML 的字符使用转义。

`JsonWriteOptions.compact`、`defaults` 和 `pretty()` 是常用预设。
`htmlSafePreset` 只启用 HTML 字符转义。

## 处理错误

yjson 用 `JsonException` 报告 JSON 解析、值转换、文档访问和算法执行中的错误：

```cangjie
try {
    let value = JsonNode.parse(input)
} catch (error: JsonException) {
    println(error.code)
    println(error.path)
}
```

用 `error.code` 判断错误类别，不要解析 `message`。`path` 为空或 RFC 6901 JSON Pointer；
部分解析错误还会在 `location` 中提供字节偏移、行号和列号。

配置参数不合法时，构造器抛出 `IllegalArgumentException`。调用方的流或自定义 codec 抛出的
异常也可能原样传出。

`invalid_value` 是稳定错误码：用于语法合法但目标类型转换失败、且不落入 `number_out_of_range`
（数字字面量超出数值范围）的场景，例如 Rune codec 收到多个 Unicode 标量。它不用于
JSON 结构错误（`parse_error`）或类型形状错误（`type_mismatch`）。

常用稳定错误码如下：

| code | 含义 |
| --- | --- |
| `parse_error` | JSON 词法、UTF-8、尾部内容或文档结构无效 |
| `unknown_field` | Reject 策略遇到目标类型未声明的字段 |
| `duplicate_key` | Reject 策略遇到重复键 |
| `missing_field` | 生成的 codec 缺少必需字段 |
| `missing_discriminator` / `unknown_discriminator` | 多态判别字段缺失或值未知 |
| `max_depth` | 读取、写出或转成 AST 时超过深度 |
| `document_too_large` | 输入文档超过字节数上限 |
| `string_too_large` | 解码后的字符串或键超过字节数上限 |
| `buffered_value_too_large` | 单个完整值或回放缓冲区超过字节数上限 |
| `output_too_large` | 输出超过字节数上限 |
| `writer_state` | writer 写出的根值数量或容器状态无效 |
| `cyclic_json_node` | AST 递归操作遇到祖先环 |
| `type_mismatch` / `number_out_of_range` | 值不满足目标类型；数字字面量超出目标范围 |
| `invalid_value` | 语法合法但目标类型转换失败且非范围问题（如 Rune 需要恰好一个 Unicode 标量） |
| `codec_contract` / `codec_type_mismatch` | 自定义或生成的 codec 不符合接口约定 |
| `resource_closed` | 关闭后访问后端文档 |
| `invalid_json_pointer` / `json_pointer_not_found` | Pointer 无效或目标不存在 |
| `invalid_json_patch` / `json_patch_test_failed` | Patch 无效或 test 失败 |
| `invalid_json_path` / `invalid_regex` | Path 或受限正则表达式无效 |
| `unsupported_schema_dialect` | Schema 不是 draft 2020-12 |
| `work_limit_exceeded` | 转成 AST 或执行算法时耗尽预算 |

加速模块初始化和运行期错误也使用 `JsonException`，错误码以 `acceleration_` 开头。
具体资源语义见[资源限制](resource-limits.md)。

