# AST 与只读 Document

yjson 的普通数据模型有两种：可修改的 `JsonNode` 和 GC 管理的只读 `JsonDocument`。
二者共享 `JsonValueView` 查询接口，但生命周期和修改能力不同。

## 可修改 AST：`JsonNode`

```cangjie
let root = JsonNode.parse("{\"name\":\"Alice\",\"items\":[1,2]}").asObject()
root.put("active", JsonNode.boolean(true))
println(root.toJson(options: JsonWriteOptions.pretty()))
```

需要增删字段、替换数组元素、组合树或应用 in-place Patch 时使用 AST。推荐使用
`JsonNode.nullValue`、`boolean`、`int64`、`uint64`、`float64`、`number`、
`string`、`array` 和 `object` 工厂创建节点。

多个父节点可以共享同一子节点形成 DAG。不要把 array/object 直接或间接放回祖先路径；
序列化、`deepCopy()` 和 `equivalentTo()` 检测到环时抛出
`JsonException(code: "cyclic_json_node")`。这些递归操作默认最多访问 100,000 个节点并限制
为 256 层。

`JsonNode` 可修改，不提供并发读写保证。共享前由应用完成同步，或改用 immutable document。

## 只读 managed document

```cangjie
let document = YJson.parseDocument("{\"name\":\"Alice\",\"items\":[1,2]}")
let root = document.root()
let name = root.member("name").getOrThrow().asString()
let first = root.member("items").getOrThrow().element(0).getOrThrow().asInt64()
```

`JsonDocument` 由 GC 管理，没有 `close()` 或 backend identity。它保持输入所有权，并只通过
`JsonValueView` 暴露：

- `kind()`、`size()`
- `element(index)`
- `member(name)`、`memberName(index)`、`memberValue(index)`
- scalar `as*` 转换
- `materialize()` 和 `materialize(maxNodes)`

managed document 和它的 view 是 immutable，可并发读取。String 输入的 storage 由 document
持有；byte-array 入口在返回前获取自有副本，因此调用方随后可以修改原数组。

## 转成可修改树

```cangjie
let mutable = document.materialize()
mutable.asObject().put("active", JsonNode.boolean(true))
```

无参数 `materialize()` 使用 100,000 节点、256 层的默认边界。显式
`materialize(maxNodes)` 只替换 node budget，depth 仍为 256。超出 node budget 使用
`work_limit_exceeded`，超出深度使用 `max_depth`。

显式 Native/yyjson document 也返回 `JsonValueView`，但它们实现
`BackendJsonDocument <: Resource`，必须关闭。详见 [Backend 使用指南](backends.md)。

