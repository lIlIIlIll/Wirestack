# AST 与 Compact DOM

yjson 有两种 Pure Cangjie 文档表示：可修改的 `JsonNode`，以及只读的
`CompactJsonDocument`。二者服务不同的生命周期，不是可互换的性能开关。

## 可修改 AST：`JsonNode`

```cangjie
let root = YJson.parse("{\"name\":\"Alice\",\"items\":[1,2]}")
let object = root.asObject()
object.put("active", JsonBoolValue(true))
println(YJson.stringifyPretty(object))
```

需要增删字段、替换数组元素、组合多棵树、应用 Patch 或 Schema 校验时使用 AST。节点包括
null、bool、integer、float、保留字面量的 number、string、array 和 object。

## 只读 Compact DOM

```cangjie
let bytes = unsafe { "{\"name\":\"Alice\",\"items\":[1,2]}".rawData() }
let document = YJson.parseCompactBorrowed(bytes)
let root = document.root()
let name = root.get("name").getOrThrow().asString()
let first = root.get("items").getOrThrow().get(0).getOrThrow().asInt64()
```

`CompactJsonValue` 支持 `kind()`、`size()`、数组下标、对象 key 和 scalar 转换。document
可以序列化，也可以 `materialize()` 成 `JsonNode`；materialize 后不再保留 Compact 表示的
内存优势。

## Borrowed 与 owned 输入

| 入口 | 所有权 contract |
| --- | --- |
| `parseCompactBorrowed` / `parseBorrowed` | 零复制并保留原数组；document 可达期间不得修改数组或与写操作并发 |
| `parseCompactOwned` / `parseOwned` | 解析前复制；返回后原数组可修改或复用 |

兼容入口 `YJson.parseCompact` 与 `CompactJsonDocument.parse` 保持 borrowed 语义。不能保证
输入在 document 生命周期内不可变时，选择 owned 入口。

Pure Compact document 由 GC 管理，不需要 `close()`。Native document 的生命周期完全
不同，必须显式关闭；见 [Backend 使用指南](backends.md)。
