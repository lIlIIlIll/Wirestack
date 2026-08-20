# 不可信 JSON 输入的资源边界

yjson 2.0 为内存输入、流式输入、typed decode、Compact DOM、Custom Native 和
yyjson backend 提供统一的显式资源预算。所有预算默认都是 `0`（不限制），因此可信输入
的默认热路径不增加限制扫描；处理 RPC、Agent、MCP 或其他不可信输入时应显式配置。

```cangjie
let limits = JsonReadConfig(
    maxDepth: 128,
    maxBytes: 8 * 1024 * 1024,
    maxStringBytes: 1 * 1024 * 1024,
    maxPolymorphicObjectBytes: 4 * 1024 * 1024
)

let value = YJson.parse(payload, config: limits)
let model = YJson.decodeFromStreamWith(ModelJson, input, config: limits)
```

## 预算语义

| 配置 | 计量对象 | `0` 的含义 | 超限错误码 |
|---|---|---|---|
| `maxBytes` | 完整输入的原始字节数；流式输入按实际读取字节累计 | 不限制 | `document_too_large` |
| `maxStringBytes` | 每个字符串值和对象 key 解码后的 UTF-8 字节数 | 不限制 | `string_too_large` |
| `maxPolymorphicObjectBytes` | 根数组或根对象从 opening token 到 closing token 的原始字节跨度，包含所有嵌套内容，不含前后空白 | 不限制 | `polymorphic_object_too_large` |
| `maxDepth` | 数组和对象的嵌套深度 | 不适用，必须为正数 | `max_depth` |

`\uXXXX` 转义按解码后的 Unicode scalar 计量。例如 `"\u4E2D"` 的字符串预算是
3 字节，代理对 `"\uD83D\uDE42"` 是 4 字节。原生 UTF-8 与等价转义因此具有相同
的 `maxStringBytes` 结果。

`maxPolymorphicObjectBytes` 只约束根容器。标量根值仍由 `maxBytes` 和
`maxStringBytes` 约束。`JsonDirectReader.readBoundedValue(maxBytes)` 的局部显式预算
仍然保留，适合在一个更大协议中只限制当前 polymorphic value。

所有资源参数拒绝负数。若 `includeErrorLocation` 为 `true`，异常同时携带 byte offset、
line 和 column；关闭位置计算不会改变错误码或预算结果。

## 覆盖的公开入口

- `YJson.parse(String/Array<Byte>)` 和 `JsonValue.parse`
- `YJson.decodeStringWith`、`decodeBytesWith`、`decodeFromStreamWith`
- `CompactJsonDocument.parse` / `YJson.parseCompact`
- `NativeCompactJsonDocument.parse`
- `YyjsonCompactJsonDocument.parse`

内存输入在创建 AST/DOM 前执行无分配预检。普通 `InputStream` 无法预知总长度，因此
`JsonParserCore` 和 `JsonDirectReader` 在填充内部缓冲区和消费 token 时增量检查；超过
预算后停止继续读取并抛出对应 `JsonException`。内存型 stream overload 会落到同一
byte-array 预检路径。

## Backend 一致性

| Failure | Pure Cangjie | Custom Native | yyjson Direct |
|---|---|---|---|
| `document_too_large` | parse 前或 stream refill 时拒绝 | C DOM 分配前拒绝 | yyjson DOM 分配前拒绝 |
| `string_too_large` | 解码扫描时拒绝 | allocation-free C 预检时拒绝 | 同一 C 预检时拒绝 |
| `polymorphic_object_too_large` | 内存预检或 stream 增量拒绝 | C DOM 分配前拒绝 | yyjson DOM 分配前拒绝 |
| `max_depth` | reader/parser 拒绝 | Custom Native parser 拒绝 | yyjson semantic validation 拒绝 |

原有 `YJ_Compact_Parse` 和 `YJ_Yyjson_Parse` C ABI 保持不变。2.0 新增
`YJ_Compact_ParseWithLimits`、`YJ_Yyjson_ParseWithLimits` 和共享的
`YJ_JSON_ValidateLimits`。Cangjie facade 在三个资源预算全为零时继续调用旧入口，显式
启用任一预算时才调用新入口。

## 兼容性与版本配套

这是 2.0 的明确破坏性配置变更：`JsonReadConfig` 构造器新增两个参数，且
`maxPolymorphicObjectBytes` 的默认值从 16 MiB 改为 `0`。旧二进制和旧生成代码不能
作为 ABI 兼容证据；应用、`yjson_macros`、`yjson_all`、`yjson_native` 和
`yjson_yyjson` 应统一升级并重新编译为 2.0。

默认配置的语义是无限制，并保留原 fast path。限制模式会增加一次线性预检或增量计数，
其目标是控制不可信输入风险，不承诺与无限制模式相同的吞吐量。
