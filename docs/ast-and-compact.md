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
let document = YJson.parseCompact(bytes)
let root = document.root()
let name = root.get("name").getOrThrow().asString()
let first = root.get("items").getOrThrow().get(0).getOrThrow().asInt64()
```

`CompactJsonValue` 支持 `kind()`、`size()`、按数组下标或对象 key 查询，以及 scalar 转换。document 可以 `toString()`，也可以 `materialize()` 成 `JsonNode`。

Pure Compact document 由 Cangjie 对象管理，不需要 `close()`。它保留输入 bytes 作为文档表示的一部分，因此不是“不持有输入”的 streaming view。Native Compact document 的生命周期不同，见 [Backend 使用指南](backends.md)。
