# API 选择指南

已知目标类型时，用 codec 在类型和 JSON 之间转换。需要操作 JSON 树时，根据是否修改数据选择
`JsonNode` 或 `JsonDocument`。流式读写和 Native 后端也有对应入口。

## 按需求选择

| 需求 | 首选入口 | 约束 |
| --- | --- | --- |
| class、struct 或 enum 与 JSON 互转 | `@JsonCodec` + `YJson.toJson/fromJson` | 编译期生成，无运行时反射 |
| 在源码中构造 JSON 树 | `@Json({...})` + `yjson_macros` | 编译期校验，结果是可修改的 `JsonNode` |
| 已有内置或自定义 codec | 同一 `YJson` 入口并传 `codec:` | 无需实现 `GeneratedCodecProviderV1` |
| 构造或修改 JSON 树 | `JsonNode.parse` / `JsonNode.object` / `JsonNode.array` | 返回可修改 `JsonNode` |
| 只读查询文档 | `YJson.parseDocument` | 返回 GC 管理的 `JsonDocument` |
| 读写调用方提供的流 | `YJson.fromJson(InputStream)` / `YJson.writeJson` | yjson 不关闭流 |
| 校验 JSON 实例 | `yjson_algorithms.JsonSchema` | draft 2020-12；默认有限预算 |
| 精确定位或多结果查询 | `JsonPointer` / `JsonPath` | 统一操作 `JsonValueView` |
| 更新 JSON | `JsonPatch` / Merge Patch | 默认返回新树，也可选择原地修改 API |

`@JsonValue({...})` 是 `@Json` 的显式别名。literal 中可以使用 `$()` 插入运行时值或动态
字符串 key；字段之间必须有逗号，允许尾随逗号。需要 JSON 文本时，对结果调用 `toJson()`。
`yjson_macros` 源码位于独立仓库 [`lIlIIlIll/yjson_macros`](https://github.com/lIlIIlIll/yjson_macros)；
应用需要同时声明 `yjson` 和 `yjson_macros` 两个依赖。

## 转换为已知类型

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

不能修改类型声明，或需要自定义 JSON 格式时，实现 `JsonCodec<T>`，并显式传入 codec：

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

只读查询时使用 `JsonDocument`：

```cangjie
let document = YJson.parseDocument(text)
let name = document.root().member("name").getOrThrow().asString()
```

`document.root()` 返回 `JsonValueView`。需要修改时调用 `materialize()`，但这会分配完整
`JsonNode` 树。转换默认限制为 100,000 个节点和 256 层。

## 是否需要 Native

默认使用纯仓颉实现。如果性能分析表明 JSON 底层操作是瓶颈，且部署平台已通过加速模块的验证，
可以在首次 `YJson` 调用前执行一次 `YJsonNativeAccel.initialize()`。初始化后继续使用相同的
`YJson` API。

需要 Native 或 yyjson 文档，或由这些后端整篇缓冲的 I/O 时，使用对应入口：

```cangjie
let native = NativeBackends.customNative
let yyjson = YyjsonBackends.yyjson
```

这两个后端返回的文档必须关闭。默认 `YJson` 的文档仍由 GC 管理。完整说明见
[Backend 使用指南](backends.md)。

## 下一步

- 类型声明和字段规则：[Codec 生成](codec-generation.md)
- 数据模型和所有权：[AST 与只读 Document](ast-and-compact.md)
- 流的读写和关闭：[Stream I/O](streams.md)
- 输入限制和错误码：[配置与错误](configuration-and-errors.md)

