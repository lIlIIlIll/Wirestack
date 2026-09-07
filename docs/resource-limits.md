# 限制 JSON 处理的资源用量

yjson 可以限制输入大小、嵌套深度、输出大小和算法工作量。这些检查覆盖解析、类型转换、
文档构建、转成 AST 和写出过程。应用仍需自行划分消息、限制并发，并控制进程内存用量。

## 设置读写上限

```cangjie
let readOptions = JsonReadOptions(
    maxInputBytes: 8 * 1024 * 1024,
    maxStringBytes: 1024 * 1024,
    maxBufferedValueBytes: 4 * 1024 * 1024,
    maxDepth: 128
)

let writeOptions = JsonWriteOptions(
    maxOutputBytes: 8 * 1024 * 1024,
    maxDepth: 128
)
```

按协议上限和实际数据大小调整这些值。读取上限必须为正数；写出选项允许用
`maxOutputBytes = 0` 取消输出字节数限制。

## 读取和写出预算

| 选项 | 语义 | 错误码 |
| --- | --- | --- |
| `maxInputBytes` | 单个输入文档的字节数 | `document_too_large` |
| `maxStringBytes` | 解码后字符串或键的 UTF-8 字节数 | `string_too_large` |
| `maxBufferedValueBytes` | 单个完整值的缓冲区，包括生成代码使用的回放缓冲区 | `buffered_value_too_large` |
| 读写选项的 `maxDepth` | 数组或对象的嵌套深度，根容器计 1 | `max_depth` |
| `maxOutputBytes` | 编码后的 JSON 字节数 | `output_too_large` |

`\uXXXX` 按解码后的 UTF-8 字节数计入字符串上限。字符串和字节数组输入在分配完整 DOM 前
检查文档大小；流输入在读取过程中累加检查。报错时，流可能已经读入一整个缓冲区，当前位置
不保证是下一条消息的起点。

向流写出时，writer 在提交下一段字节前检查 `maxOutputBytes`。一旦失败，不要复用 writer，
也不要把已写出的部分内容当作完整 JSON。返回字符串或字节数组的入口保证结果不超过上限，
但处理过程的峰值内存可能高于这个值。

## AST 操作和文档转换

手工构造的 `JsonNode` 没有经过读取预算。`deepCopy()`、`equivalentTo()` 和默认
`materialize()` 因此限制为 256 层和 100,000 个访问节点。深度超限使用 `max_depth`；
节点数或工作量超限使用 `work_limit_exceeded`。

`materialize(maxNodes)` 可以修改节点数上限，但不能取消 256 层的限制。各后端通过
`JsonValueView` 转成 AST 时遵守相同限制。

## 算法预算

`yjson_algorithms` 使用独立预算：

| 类型 | 默认值 |
| --- | --- |
| `JsonPathLimits` | 访问 100,000 个节点，筛选 100,000 个候选节点，正则执行 100,000 步，返回 10,000 个匹配，遍历深度 256 |
| `JsonPatchLimits` | 10,000 次操作，Pointer 长度 256 段，复制 100,000 个节点 |
| `JsonSchemaLimits` | 100,000 次求值，1,000 次引用解析，正则执行 100,000 步，100 个错误，深度 256 |

JSONPath 还单独限制筛选表达式的复杂度：每个表达式默认最多 4,096 字节、256 个逻辑运算符、
64 层逻辑递归；一次查询最多执行 200,000 次逻辑运算。对应选项为
`maxFilterExpressionBytes`、`maxFilterOperators`、`maxFilterDepth` 和 `maxFilterOperations`。
`maxFilterSteps` 统计筛选的候选节点数，不统计表达式中的逻辑运算次数。

JSONPath 解析时超过表达式字节数、运算符数量或递归深度上限，会抛出
`JsonException(code: "invalid_json_path")`。执行阶段超过工作量上限时，抛出
`JsonException(code: "work_limit_exceeded")`。用 `JsonPath.parse(expression, limits: limits)`
调整解析限制；查询方法的 `limits:` 参数控制执行预算。算法选项允许用 0
取消单项限制，也提供 `.unlimited` 预设。只在可信离线任务中关闭预算。读取选项仍要求正数，
不适用这条规则。

JSONPath 的 `matches()` 返回惰性游标，调用 `next()` 时才遍历文档并消耗执行预算。
Schema 在构造时通过 resolver 解析外部引用，并编译正则表达式；验证阶段不再调用 resolver。

