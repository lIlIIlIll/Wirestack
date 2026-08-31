# API 选择指南

先按“是否有目标类型、是否需要修改、是否使用 stream 或 Native”选择入口。不要让底层存储
类型泄漏到普通应用 API。

## 一张表做决定

| 需求 | 首选入口 | 约束 |
| --- | --- | --- |
| class/struct/enum 与 JSON 互转 | `@JsonCodec` + `YJson.toJson/fromJson` | 编译期生成，无运行时反射 |
| 已有 built-in 或 custom codec | 同一 `YJson` 入口并传 `codec:` | 不要求 generated provider |
| 构造或修改 JSON 树 | `JsonNode.parse` / `JsonNode.object` / `JsonNode.array` | 返回可修改 `JsonNode` |
| 只读查询文档 | `YJson.parseDocument` | 返回 GC 管理的 `JsonDocument` |
| 读写 caller-owned stream | `YJson.fromJson(InputStream)` / `YJson.writeJson` | yjson 不关闭 stream |
| 校验 JSON 实例 | `yjson_algorithms.JsonSchema` | draft 2020-12；默认有限预算 |
| 精确定位或多结果查询 | `JsonPointer` / `JsonPath` | 统一操作 `JsonValueView` |
| 更新 JSON | `JsonPatch` / Merge Patch | 返回新树，或显式选择 in-place API |

## 有目标类型：使用 typed codec

类型由你控制时，在声明上添加 `@JsonCodec`：

```cangjie
@JsonCodec
class User {
    public let id: Int64
    public init(id: Int64) { this.id = id }
}

let text = YJson.toJson(User(7))
let user = YJson.fromJson<User>(text)
```

不能修改类型声明，或 wire format 需要专门逻辑时，实现 `JsonCodec<T>`，并把 codec 传给
同一组入口：

```cangjie
let text = YJson.toJson(value, codec: UserIdJson)
let value = YJson.fromJson(text, codec: UserIdJson)
```

详见[自定义 Codec](custom-codecs.md)。

## 没有目标类型：选择数据模型

需要修改时使用 `JsonNode`：

```cangjie
let tree = JsonNode.parse(text).asObject()
tree.put("active", JsonNode.boolean(true))
```

只读查询时使用 managed document：

```cangjie
let document = YJson.parseDocument(text)
let name = document.root().member("name").getOrThrow().asString()
```

`document.root()` 返回 `JsonValueView`。需要修改时调用 `materialize()`，但这会分配完整
`JsonNode` 树。默认 materialization 限制 100,000 个节点和 256 层。

## 是否需要 Native

默认从 Pure Cangjie 开始。只有 profiling 证明 JSON primitive 是瓶颈，并且部署环境属于
qualified platform 时，才在首次 `YJson` 调用前执行一次
`YJsonNativeAccel.initialize()`。初始化后继续使用相同 `YJson` API。

需要 Native/yyjson 的显式 document 或 whole-document I/O 时，使用命名 façade：

```cangjie
let native = NativeBackends.customNative
let yyjson = YyjsonBackends.yyjson
```

这两条路径返回显式资源，并不改变默认 `YJson` 的生命周期。完整说明见
[Backend 使用指南](backends.md)。

## 下一步

- 类型声明和字段规则：[Codec 生成](codec-generation.md)
- 数据模型和所有权：[AST 与只读 Document](ast-and-compact.md)
- Stream 语义：[Stream I/O](streams.md)
- 输入预算和错误码：[配置与错误](configuration-and-errors.md)

