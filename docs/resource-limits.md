# 不可信 JSON 的资源边界

资源限制用于在解析、typed decode、DOM 构建和写出期间尽早拒绝超大输入。它们不能替代
协议 framing、并发限流、认证授权或进程级内存控制。

## 推荐起点

```cangjie
let readConfig = JsonReadConfig(
    limits: JsonReadLimits(
        maxDepth: 128,
        maxBytes: 8 * 1024 * 1024,
        maxStringBytes: 1024 * 1024,
        maxPolymorphicObjectBytes: 4 * 1024 * 1024
    ))

let writeConfig = JsonWriteConfig("", "", false, false,
    limits: JsonWriteLimits(maxDepth: 128, maxBytes: 8 * 1024 * 1024))
```

具体数值必须根据协议上限和业务 payload 调整。所有资源参数拒绝负数；byte limit 的
`0` 表示 unlimited。

## 每个预算限制什么

| 配置 | 语义 | 错误码 |
| --- | --- | --- |
| `maxDepth` | array/object 嵌套；根容器计 1，scalar 不增加 | `max_depth` |
| `maxBytes` | 单个输入文档或输出结果的 bytes | `document_too_large` / `output_too_large` |
| `maxStringBytes` | 解码后 UTF-8 string/key bytes | `string_too_large` |
| `maxPolymorphicObjectBytes` | generated 多态根容器 replay span | `polymorphic_object_too_large` |

`\uXXXX` 按解码后的 Unicode scalar 计量，因此原生 UTF-8 与等价转义得到同一
`maxStringBytes` 结果。超大 number token 由 `maxBytes` 或多态根预算约束，不计入 string
预算。

写出端对所有 direct、generated raw、AST 和 stream 路径使用同一容器深度定义。writer 必须
完成且只完成一个根值；没有根值、第二个根值或未闭合容器使用 `writer_state`。Stream
`maxBytes` 在向调用方 sink 提交下一段 bytes 前检查，触发 `output_too_large` 后该 writer
进入终止状态，sink 中已提交的前缀不会超过配置值。内存 String/bytes 入口在返回结果前执行
同一预算检查。

可修改 `JsonNode` 允许共享同一子节点形成 DAG，但递归序列化、`deepCopy()` 和语义等价比较
会拒绝祖先环，错误码为 `cyclic_json_node`。序列化按遍历顺序发现环，因此 Stream sink 在
报错前可能已有不超过预算的 JSON 前缀。

## 覆盖路径

预算覆盖 `YJson.parse`、String/bytes typed decode、stream decode、Pure Compact、Custom
Native、yyjson Direct 和 generated polymorphic replay。未知字段 skip 继续遵守剩余深度，
不会用无法证明子树深度的 shortcut 绕过检查。

内存输入在 AST/DOM 分配前预检。普通 stream 无法预知总长度，Pure reader 在 refill 和
消费 token 时增量检查；底层 stream 可能已多提供一个当前 4096-byte buffer 的数据。
失败后不保证 stream 位于可恢复消息边界。

## Backend 一致性

| Failure | Pure | Custom Native | yyjson Direct |
| --- | --- | --- | --- |
| 文档过大 | parse 前或 refill 时拒绝 | DOM 分配前拒绝 | DOM 分配前拒绝 |
| string/key 过大 | 解码扫描时拒绝 | allocation-free 预检 | allocation-free 预检 |
| 多态根过大 | replay 前拒绝 | DOM 分配前拒绝 | DOM 分配前拒绝 |
| 深度过大 | reader/parser 拒绝 | Native parser 拒绝 | semantic validation 拒绝 |

`includeErrorLocation` 只控制位置信息，不改变错误码或预算结果。启用限制可能增加线性预检
或计数成本，不承诺与 unlimited fast path 相同的吞吐量。

高层算法还具有独立的 `JsonPathLimits`、`JsonPatchLimits` 与 `JsonSchemaLimits`；默认值
适用于不可信输入，预算耗尽统一使用 `work_limit_exceeded`。
