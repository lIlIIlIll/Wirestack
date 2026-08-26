# API 选择指南

yjson 提供多条 JSON 路径。先按“是否有目标类型、是否需要修改、是否需要 stream 或
Native”选择入口，不要因为某个底层类型看起来更快就直接依赖它。

## 一张表做决定

| 需求 | 首选入口 | 需要注意 |
| --- | --- | --- |
| class/struct/enum 与 JSON 互转 | `@JsonCodec` + `YJson.toJson/fromJson` | 编译期生成，无运行时反射 |
| 已有 built-in 或 custom codec | `encode*With/decode*With` | 显式传入 `JsonCodec<T>` |
| 直接拼出 JSON 文本 | `@Json({...})` | 返回 `String`，不构建 AST |
| 构造或修改 JSON 树 | `@JsonValue` / `YJson.parse` | 返回可修改 `JsonNode` |
| 只读查询文档 | `YJson.parseDocument` | GC 管理的 Compact document |
| 读写 caller-owned stream | `toStream/fromStream` 或 `*StreamWith` | yjson 不关闭 stream |
| 校验 JSON 实例 | `yjson_algorithms.JsonSchema` | draft 2020-12；默认有限预算 |
| 精确定位或多结果查询 | `yjson_algorithms` 的 Pointer / Path | 默认有限预算 |
| 原子更新 JSON | `yjson_algorithms` 的 Patch / Merge Patch | 默认有限预算 |

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

不能修改类型声明，或 wire format 需要手写逻辑时，实现 `JsonCodec<T>`，再调用
`encodeStringWith`、`decodeStringWith` 或对应 bytes/stream 入口。详见
[自定义 Codec](custom-codecs.md)。

## 没有目标类型：选择一种数据模型

- 需要增删字段、修改数组、应用 Patch 或交给 Schema 校验：使用 `JsonNode`。
- 只读查询并希望降低中间对象数量：使用 `YJson.parseDocument`。
- 只需立刻生成 JSON 文本：使用 `@Json`，不要先创建 `JsonNode`。

```cangjie
let tree = YJson.parse(text)
tree.asObject().put("active", JsonBoolValue(true))

let document = YJson.parseDocument(text)
let name = document.materialize()["name"].string
```

`materialize()` 会转成完整 `JsonNode`，因此也会放弃 Compact 表示的内存特性。需要频繁、
任意深度修改时，应从一开始就选择 AST。

## 是否需要 Native

默认从 Pure Cangjie 开始。只有 profiling 证明读写是瓶颈，并且部署环境能构建 Native
package 时，才在应用启动、首次 `YJson` 调用前执行一次
`YJsonNativeAccel.initialize()`。初始化成功后继续使用相同 `YJson` API；失败不会静默回退。

只有确实需要 Custom Native/yyjson whole-document DOM 或 stream 行为时，才使用
`yjson_backends` 的显式资源 API。完整选择矩阵见 [Backend 使用指南](backends.md)。

## 下一步

- 类型声明和字段规则：[Codec 生成](codec-generation.md)
- 数据模型与所有权：[AST 与 Compact DOM](ast-and-compact.md)
- Stream 语义：[Stream I/O](streams.md)
- 输入预算与错误码：[配置与错误](configuration-and-errors.md)
