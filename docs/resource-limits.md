# 不可信 JSON 输入的资源边界

yjson 1.0 RC 为内存输入、流式输入、typed decode、Compact DOM、Custom Native 和
yyjson backend 提供统一的显式资源预算。默认 `maxDepth` 是 256，三个 byte budget
默认都是 `0`（不限制），因此可信输入的默认热路径不增加 byte-limit 扫描；处理 RPC、
Agent、MCP 或其他不可信输入时应显式配置。

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

## 推荐起点

下面是用于开始评审的配置档位，不是通用安全保证。应按协议允许的最大消息、字段和多态
对象大小收紧，并结合应用自身的对象分配与并发上限：

| 场景 | `maxDepth` | `maxBytes` | `maxStringBytes` | `maxPolymorphicObjectBytes` |
|---|---:|---:|---:|---:|
| HTTP API | 128 | 8 MiB | 1 MiB | 4 MiB |
| Agent / MCP tool payload | 64 | 2 MiB | 256 KiB | 1 MiB |
| 本地可信配置文件 | 256 | 按业务决定 | 按业务决定 | 按业务决定 |

`maxBytes` 只限制输入体积，不是进程的严格总内存上限。AST、typed object、索引、解码后
字符串和业务副本仍可能使峰值内存高于输入大小；并发请求还需要在上层单独限流。

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
`maxStringBytes` 约束。generated codec 通过 backend-neutral
`JsonCodecReader.readReplayValue(maxBytes)` 执行这一局部预算。

当前没有独立的 array element count、object property count 或 number-token length
配置。元素和属性数量受 `maxBytes`、表示上限与可用内存间接约束；超大 number token
由 `maxBytes`（或根容器内的 `maxPolymorphicObjectBytes`）约束，而不是
`maxStringBytes`。

所有资源参数拒绝负数。若 `includeErrorLocation` 为 `true`，异常同时携带 byte offset、
line 和 column；关闭位置计算不会改变错误码或预算结果。

generated polymorphic decode 遵循相同的 `0 = unlimited` contract。Pure reader
直接按原始输入跨度计量；Custom Native 与 yyjson 在 DOM 分配前按同一原始跨度预检，
导出的 bulk tape 不会把 tape 元数据重复计入预算。

## 覆盖的公开入口

- `YJson.parse(String/Array<Byte>)` 和 `JsonNode.parse`
- `YJson.decodeStringWith`、`decodeBytesWith`、`decodeFromStreamWith`
- `CompactJsonDocument.parse` / `YJson.parseCompact`
- `NativeCompactJsonDocument.parse`
- `YyjsonCompactJsonDocument.parse`

内存输入在创建 AST/DOM 前执行无分配预检。普通 `InputStream` 无法预知总长度，因此
`JsonParserCore` 和 `JsonDirectReader` 在填充内部缓冲区和消费 token 时增量检查；超过
预算后停止后续 refill 并抛出对应 `JsonException`。当前内部 buffer 是 4096 bytes，
一次 refill 已从底层 stream 取得的数据可能使实际 read-ahead 超过 `maxBytes`，最多到
当前这一 buffer read 的边界。内存型 stream overload 会落到 byte-array 预检路径。

资源超限或 parse 失败后，不保证 stream 停在调用方可恢复的消息边界，也不承诺可以继续
复用。需要多消息协议时，应先由 framing 层切分消息。

## Backend 一致性

| Failure | Pure Cangjie | Custom Native | yyjson Direct |
|---|---|---|---|
| `document_too_large` | parse 前或 stream refill 时拒绝 | C DOM 分配前拒绝 | yyjson DOM 分配前拒绝 |
| `string_too_large` | 解码扫描时拒绝 | allocation-free C 预检时拒绝 | 同一 C 预检时拒绝 |
| `polymorphic_object_too_large` | 内存预检或 stream 增量拒绝 | C DOM 分配前拒绝 | yyjson DOM 分配前拒绝 |
| `max_depth` | reader/parser 拒绝 | Custom Native parser 拒绝 | yyjson semantic validation 拒绝 |

原有 `YJ_Compact_Parse` 和 `YJ_Yyjson_Parse` C ABI 保持不变。1.0 RC 新增
`YJ_Compact_ParseWithLimits`、`YJ_Yyjson_ParseWithLimits` 和共享的
`YJ_JSON_ValidateLimits`。Cangjie facade 在三个资源预算全为零时继续调用旧入口，显式
启用任一预算时才调用新入口。

## 兼容性与版本配套

这是相对 pre-1.0 snapshot 的明确配置变更：`JsonReadConfig` 构造器新增两个参数，且
`maxPolymorphicObjectBytes` 的默认值从 16 MiB 改为 `0`。旧二进制和旧生成代码不能
作为 ABI 兼容证据；应用、`yjson_macros`、`yjson_all`、`yjson_native` 和
`yjson_yyjson` 应统一升级并针对 `1.0.0-rc.1` source candidate 重新编译。

默认配置的语义是无限制，并保留原 fast path。限制模式会增加一次线性预检或增量计数，
其目标是控制不可信输入风险，不承诺与无限制模式相同的吞吐量。
