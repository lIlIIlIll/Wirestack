# 不可信 JSON 的资源边界

资源限制在解析、typed decode、文档构建、materialization 和写出期间拒绝超大工作量。它们
不能替代协议 framing、并发限流、认证授权或进程级内存控制。

## 推荐起点

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

数值必须根据协议上限和 payload 调整。读取预算全部为正数；`maxOutputBytes = 0` 才表示
不限制输出 bytes。

## 读取和写出预算

| 选项 | 语义 | 错误码 |
| --- | --- | --- |
| `maxInputBytes` | 单个输入 document 的 bytes | `document_too_large` |
| `maxStringBytes` | 解码后 string/key 的 UTF-8 bytes | `string_too_large` |
| `maxBufferedValueBytes` | generated replay 或 whole-value buffer | `buffered_value_too_large` |
| read/write `maxDepth` | array/object 嵌套；根容器计 1 | `max_depth` |
| `maxOutputBytes` | 已编码 JSON bytes | `output_too_large` |

`\uXXXX` 按解码后的 UTF-8 值计入 string budget。String/bytes 输入在完整 DOM 分配前检查
document 上限；stream 在读取过程中递增检查。stream 可能已经从底层读取了当前 buffer，但不会
把输入位置伪装成可恢复的消息边界。

stream writer 在提交下一段 bytes 前检查 `maxOutputBytes`。一旦失败，不要复用 writer，也
不要把已经写出的前缀当作有效 JSON。内存 String/bytes 入口保证返回值不超过预算，但这个
上限不是峰值分配保证。

## AST 和 materialization

手工构造的 `JsonNode` 没有经过读取预算。`deepCopy()`、`equivalentTo()` 和默认
`materialize()` 因此限制为 256 层和 100,000 个访问节点。深度超限使用 `max_depth`；
node/work budget 耗尽使用 `work_limit_exceeded`。

`materialize(maxNodes)` 可以替换 node budget，但不能取消 256 层边界。显式 backend façade
同样通过统一 `JsonValueView` 和这组 materialization contract 返回 AST。

## 算法预算

`yjson_algorithms` 使用独立预算：

| 类型 | 默认值 |
| --- | --- |
| `JsonPathLimits` | 100,000 visited、100,000 filter、100,000 regex、10,000 matches、depth 256 |
| `JsonPatchLimits` | 10,000 operations、256 pointer segments、100,000 copied nodes |
| `JsonSchemaLimits` | 100,000 evaluations、1,000 ref resolutions、100,000 regex、100 errors、depth 256 |

任一维度耗尽都抛出 `JsonException(code: "work_limit_exceeded")`。算法预算允许 0 表示该
维度 unlimited，并提供 `.unlimited` 预设；这与读取预算的正数规则不同。只在可信离线任务
中关闭预算。

JSONPath 的 `matches()` 返回惰性 cursor，预算在 `next()` 推进时消耗；创建 cursor 本身
不预先遍历 document。Schema 在构造时解析外部 resolver 图并编译 regex，validation 不再访问
resolver。

