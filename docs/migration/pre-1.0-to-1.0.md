# 从 pre-1.0 snapshot 迁移到 1.0

1.0 固化 runtime 类型名、资源预算和 package/backend 边界。所有 yjson package 应一次升级
到同一 checkout 或 release，并重新编译 generated code。

## `JsonValue` → `JsonNode`

```cangjie
// before
let value: JsonValue = ...

// 1.0
let value: JsonNode = ...
```

`@JsonValue({...})` 现在是 expression macro 名称；runtime 树类型是 `JsonNode`。

## Resource config

```cangjie
let config = JsonReadConfig(
    maxDepth: 128,
    maxBytes: 8 * 1024 * 1024,
    maxStringBytes: 1024 * 1024,
    maxPolymorphicObjectBytes: 4 * 1024 * 1024
)
```

三个 byte limit 默认都是 `0 = unlimited`。`maxBytes` 与 `maxStringBytes` 是新增项；多态
预算从 pre-1.0 的 16 MiB 变为 unlimited。接收不可信输入的应用必须重新评审配置。

写出预算使用 `JsonWriteConfig.maxBytes`。Pure stream 失败前可能已写出前缀；Native
whole-document backend 在提交到 caller stream 前检查。

## Codec interface

`JsonDirectCodec<T>` 改名为 backend-neutral `JsonCodec<T>`，无兼容 alias。custom codec 的
参数改为 `JsonCodecReader` / `JsonCodecWriter`，才能被 Pure 和 Native stream 共同驱动。

## Backend

- Pure 仍是默认。
- `NativeCompactStreamBackend` / `YyjsonStreamBackend` 必须显式选择。
- 不自动探测，也不静默 fallback。
- Native document 使用 `try (document = ...)` 或 `finally` 显式关闭。

## Package pairing

`yjson_macros`、`yjson_all`、`yjson_native`、`yjson_yyjson` 与 core 必须 exact match。
`yjson_all` 不再代表任何隐式 Native dependency。

## JSON literal 与 builder

当前 `0.1.x` 使用 `yjson_macros` 的 expression macro 在源码中构造可修改的 `JsonNode`：

```cangjie
let tree: JsonNode = @Json({"id": $(id)})
let same: JsonNode = @JsonValue({"id": $(id)})
```

完整的 literal 语法和 API 选择见[API 选择指南](../choosing-an-api.md)；公开变更见
[API/ABI inventory](../public-api-inventory.md)和[Release notes](../../RELEASE_NOTES.md)。
