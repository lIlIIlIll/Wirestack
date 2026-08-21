# AST 与 Compact DOM

## `JsonNode`: 可修改 AST

`YJson.parse` 返回 `JsonNode`。节点类型包括 null、bool、integer、float、保留字面量的 number、string、array 与 object：

```cangjie
let root = YJson.parse("{\"name\":\"Alice\",\"items\":[1,2]}")
let object = root.asObject()
object.put("active", JsonBoolValue(true))
println(YJson.stringifyPretty(object))
```

当输入需要增删字段、替换数组元素、与其他树组合或交给 `JsonSchema` 校验时使用 AST。

## `CompactJsonDocument`: Pure Cangjie 只读 DOM

```cangjie
let bytes = unsafe { "{\"name\":\"Alice\",\"items\":[1,2]}".rawData() }
let document = YJson.parseCompactBorrowed(bytes)
let root = document.root()
let name = root.get("name").getOrThrow().asString()
let first = root.get("items").getOrThrow().get(0).getOrThrow().asInt64()
```

`CompactJsonValue` 支持 `kind()`、`size()`、按数组下标或对象 key 查询，以及 scalar 转换。document 可以 `toString()`，也可以 `materialize()` 成 `JsonNode`。

Pure Compact document 由 Cangjie 对象管理，不需要 `close()`。输入所有权有两个显式入口：

| 入口 | 输入 contract |
| --- | --- |
| `parseBorrowed` / `parseCompactBorrowed` | 零复制并保留原数组。document 可达期间，调用方必须把数组视为 immutable，不得修改内容或与写操作并发。 |
| `parseOwned` / `parseCompactOwned` | 解析前复制数组。返回后调用方可以修改或复用原数组。 |

兼容入口 `CompactJsonDocument.parse` 与 `YJson.parseCompact` 保持 borrowed 语义。无法保证输入在 document 生命周期内不被修改时，应使用 owned 入口。Native Compact document 的生命周期不同，见 [Backend 使用指南](backends.md)。
