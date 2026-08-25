# API 选择指南

## 先看结论

| 需求 | 使用 | 特性 |
| --- | --- | --- |
| class/struct/enum 与 JSON 互转 | `@JsonCodec` + `YJson.toJson/fromJson` | 类型安全、编译期生成、无运行时反射 |
| 已有一个显式 codec | `encode*With/decode*With` | 适合 built-in 或 custom codec |
| 构造 JSON 文本 | `@Json({...})` | 插值后直接写出 `String`，不先构建 AST |
| 构造、解析并修改树 | `JsonNode` / `@JsonValue` | 可修改、易组合 |
| 只读查询文档 | `YJson.parseDocument` | 统一 facade，默认 Pure Compact，可显式切换 Native backend |
| caller-owned stream | `encodeToStreamWith/decodeFromStreamWith` | 默认 Pure；可显式选择 backend；不关闭 stream |
| Native-owned DOM | optional backend package | 需要显式生命周期管理 |
| 校验 JSON 实例 | `JsonSchema` | draft 2020-12；外部资源显式 resolver；format 默认 annotation，可安装 provider |
| 定位或查询节点 | `JsonPointer` / `JsonPath` | RFC 6901 精确位置 / RFC 9535 多结果查询 |
| 原子更新文档 | `JsonPatch` / `JsonMergePatch` | RFC 6902 操作序列 / RFC 7386 merge 语义 |

如果是在 yjson、stdx.json、cjfast_json 或跨 runtime 方案之间选库，先看
[库能力对比](library-comparison.md)。该表只比较公开 contract；性能选型还需使用相同
workload、SDK 和部署环境重新测量。

## Typed API

类型能使用 `JsonCodecProvider` 时，优先采用最短入口：

```cangjie
let text = YJson.toJson(user)
let decoded = YJson.fromJson<User>(text)
```

`@JsonCodec` 会为声明生成 provider 和直接 codec。内置 scalar、`Option<T>`、`Array<T>`、`ArrayList<T>`、`HashMap<String, T>`、`DateTime`、`BigInt` 与 `Decimal` 也提供 provider；容器元素必须同样可解析 codec。

## AST 与 Compact DOM

需要更新节点、插入字段或把多个来源合并成一棵树时使用 `JsonNode`。只读取少数字段或顺序遍历大文档时先评估统一 document facade：

```cangjie
let tree = YJson.parse(text)
tree.asObject().put("active", JsonBoolValue(true))

try (document = YJson.parseDocument(text)) {
    let tree = document.materialize() // 任意深度查询的显式桥接
    let name = tree.asObject().get("name").getOrThrow().asString().value
}
```

不指定 backend 时使用 `PureCompactBackend`。依赖可选 package 后，同一入口可传入
`NativeCompactBackend` 或 `YyjsonBackend`。document 可以 `materialize()` 成
`JsonNode`，但一旦 materialize，就不再保留只读紧凑表示的内存优势。

需要 Pure/Custom Native 的逐节点 view，或后端专有统计和调优参数时，仍可直接使用
`CompactJsonDocument`、`NativeCompactJsonDocument` 或
`YyjsonCompactJsonDocument`。

## Native backend

Native 不改变默认 typed API 的身份，也不会被 `yjson_all` 隐式启用。统一的是
document 调用入口，不是依赖关系或底层表示；只有在 profiling 与部署约束都支持时
才依赖 `yjson_native` 或 `yjson_yyjson`。选择表和完整示例见 [Backend 使用指南](backends.md)。

Native package 也提供 typed stream backend：`NativeCompactStreamBackend` 与
`YyjsonStreamBackend`。它们是 whole-document 模式，通过一次 native parse/export 或
encode/copy 驱动 backend-neutral `JsonCodec<T>`；不会逐节点 FFI，也不会在失败时静默
切换到 Pure。完整语义见 [Stream I/O](streams.md)。
