# AST 与只读 Document

yjson 的普通数据模型有两种：可修改的 `JsonNode` 和 GC 管理的只读 `JsonDocument`。
二者共享 `JsonValueView` 查询接口，但生命周期和修改能力不同。

## 可修改 AST：`JsonNode`

```cangjie
let root = JsonNode.parse("{\"name\":\"Alice\",\"items\":[1,2]}").asObject()
root.put("active", JsonNode.boolean(true))
println(root.toJson(options: JsonWriteOptions.pretty()))
```

需要增删字段、替换数组元素、组合树或原地应用 Patch 时，使用 AST。用
`JsonNode.nullValue`、`boolean`、`int64`、`uint64`、`float64`、`number`、
`string`、`array` 和 `object` 工厂创建节点。

多个父节点可以共享同一子节点形成 DAG。不要把数组或对象直接或间接插入自身的子节点。
序列化、`deepCopy()` 和 `equivalentTo()` 检测到环时抛出
`JsonException(code: "cyclic_json_node")`。这些递归操作默认最多访问 100,000 个节点并限制
为 256 层。

`JsonNode` 可修改，不提供并发读写保证。共享前由应用完成同步，或改用只读文档。

## 只读文档：`JsonDocument`

```cangjie
let document = YJson.parseDocument("{\"name\":\"Alice\",\"items\":[1,2]}")
let root = document.root()
let name = root.member("name").getOrThrow().asString()
let first = root.member("items").getOrThrow().element(0).getOrThrow().asInt64()
```

`JsonDocument` 由 GC 管理，不需要 `close()`，也不提供后端标识。文档通过
`JsonValueView` 提供查询和转换方法：

- `kind()`、`size()`
- `element(index)`
- `member(name)`、`memberName(index)`、`memberValue(index)`
- 标量 `as*` 转换
- `materialize()` 和 `materialize(maxNodes)`

只读文档及其视图可并发读取。文档持有输入 `String` 的存储；字节数组入口在返回前复制输入，
因此调用方随后可以修改原数组。

## 转成可修改树

```cangjie
let mutable = document.materialize()
mutable.asObject().put("active", JsonNode.boolean(true))
```

无参数 `materialize()` 最多访问 100,000 个节点、256 层。
`materialize(maxNodes)` 只修改节点上限，深度仍为 256。超出节点上限时报
`work_limit_exceeded`，超出深度时报 `max_depth`。

Native 和 yyjson 文档也返回 `JsonValueView`，但它们实现
`BackendJsonDocument <: Resource`，必须关闭。详见 [Backend 使用指南](backends.md)。

