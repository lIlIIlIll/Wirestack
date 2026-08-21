# API 选择指南

## 先看结论

| 需求 | 使用 | 特性 |
| --- | --- | --- |
| class/struct/enum 与 JSON 互转 | `@JsonCodec` + `YJson.toJson/fromJson` | 类型安全、编译期生成、无运行时反射 |
| 已有一个显式 codec | `encode*With/decode*With` | 适合 built-in 或 custom codec |
| 构造 JSON 文本 | `@Json({...})` | 插值后直接写出 `String`，不先构建 AST |
| 构造、解析并修改树 | `JsonNode` / `@JsonValue` | 可修改、易组合 |
| 只读查询文档 | `CompactJsonDocument` | Pure Cangjie，避免完整 `JsonNode` 树 |
| caller-owned stream | `encodeToStreamWith/decodeFromStreamWith` | 不关闭调用方 stream |
| Native-owned DOM | optional backend package | 需要显式生命周期管理 |
| 校验 JSON 实例 | `JsonSchema` | 常用 draft 2020-12 子集 |

## Typed API

类型能使用 `JsonCodecProvider` 时，优先采用最短入口：

```cangjie
let text = YJson.toJson(user)
let decoded = YJson.fromJson<User>(text)
```

`@JsonCodec` 会为声明生成 provider 和直接 codec。内置 scalar、`Option<T>`、`Array<T>`、`ArrayList<T>`、`HashMap<String, T>`、`DateTime`、`BigInt` 与 `Decimal` 也提供 provider；容器元素必须同样可解析 codec。

## AST 与 Compact DOM

需要更新节点、插入字段或把多个来源合并成一棵树时使用 `JsonNode`。只读取少数字段或顺序遍历大文档时先评估 `CompactJsonDocument`：

```cangjie
let tree = YJson.parse(text)
tree.asObject().put("active", JsonBoolValue(true))

let compact = YJson.parseCompact(unsafe { text.rawData() })
let name = compact.root().get("name").getOrThrow().asString()
```

Compact DOM 可以 `materialize()` 成 `JsonNode`，但一旦 materialize，就不再保留只读紧凑表示的内存优势。

## Native backend

Native 不改变默认 typed API 的身份，也不会被 `yjson_all` 隐式启用。只有在 profiling 与部署约束都支持时才依赖 `yjson_native` 或 `yjson_yyjson`；选择表和完整示例见 [Backend 使用指南](backends.md)。
