# 从 pre-1.0 snapshot 迁移到 1.0 RC

`1.0.0-rc.1` 固化 API 命名、资源预算与 package/backend 边界。所有 yjson package
应一次升级到同一版本并重新编译；候选版尚未发布到 registry。

## AST rename

```cangjie
// pre-1.0 snapshot
let value: JsonValue = ...

// 1.0 RC
let value: JsonNode = ...
```

如果源码同时使用 `@JsonValue({...})`，需要特别注意：这里的 `JsonValue` 是 macro
名称，而 runtime 树类型是 `JsonNode`。旧名称被该 macro 占用，必须迁移。

## `JsonReadConfig`

1.0 RC 增加明确的 byte budget：

```cangjie
let config = JsonReadConfig(
    maxDepth: 128,
    maxBytes: 8 * 1024 * 1024,
    maxStringBytes: 1024 * 1024,
    maxPolymorphicObjectBytes: 4 * 1024 * 1024
)
```

三个 byte limit 在 1.0 RC 中默认都是 `0`，表示 unlimited。`maxBytes` 和
`maxStringBytes` 是新增字段；`maxPolymorphicObjectBytes` 从 pre-1.0 snapshot 的
16 MiB 改为 unlimited，是需要安全评审的行为变化，不代表适合不可信输入。

## Package pairing

| Package | 1.0 RC 要求 |
| --- | --- |
| `yjson_macros` | 与 `yjson` exact version match |
| `yjson_all` | 聚合并锁定 matching core + macros |
| `yjson_native` | 与 `yjson` exact version match，显式 opt-in |
| `yjson_yyjson` | 与 `yjson` exact version match，显式 opt-in |

core 不再代表任何隐式 Native link dependency。Native document 是显式资源，应改为 `try (document = ...)` 或在 `finally` 中 `close()`。

## JSON literal

1.0 RC 提供：

```cangjie
let text: String = @Json({"id": $(id)})
let tree: JsonNode = @JsonValue({"id": $(id)})
```

`JsonObjectValue.put` 现在返回同一个对象以支持链式调用，不再返回 `Unit`。Native
package 不会被 core 或 `yjson_all` 隐式启用；generated code 必须与完全匹配的 runtime
版本一起重新编译。

完整 snapshot delta、generated-code bridge 与兼容性处置见
[1.0 RC API/ABI change inventory](../public-api-inventory.md)；用户可见变更摘要见
[Release notes](../../RELEASE_NOTES.md)。
