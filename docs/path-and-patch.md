# JSON Pointer、Patch 与 JSONPath

## JSON Pointer（RFC 6901）

```cangjie
let root = YJson.parse("{\"a/b\":{\"items\":[1,2]}}")
let value = JsonPointer.parse("/a~1b/items/1").evaluate(root)
let fromFragment = JsonPointer.parseUriFragment("#/a~1b/items/1")
```

空字符串指向根；`~0` 和 `~1` 分别表示 `~` 和 `/`。数组索引严格拒绝多余前导零，URI
fragment 在 Pointer 解码前进行 percent/UTF-8 解码。`find` 返回 `Option`，`evaluate`
在目标不存在时抛出 `JsonPointerException`。

## JSON Patch（RFC 6902）

```cangjie
let patch = JsonPatch.parse("""
[
  {"op":"test", "path":"/version", "value":1},
  {"op":"replace", "path":"/name", "value":"new"},
  {"op":"add", "path":"/tags/-", "value":"stable"}
]
""")

let updated = patch.apply(root)
let committed = patch.applyInPlace(root)
```

支持 `add/remove/replace/move/copy/test`。解析 Patch 时默认拒绝重复 object key。两种 apply
入口都是事务性的：任一操作失败，不会留下部分更新。`test` 采用 JSON 数值相等语义。
当操作替换根节点类型时，`applyInPlace` 无法改变原对象的运行时类型，因此返回新根；调用方
必须使用返回值。

## JSON Merge Patch（RFC 7386）

```cangjie
let updated = JsonMergePatch.apply(root, YJson.parse("{\"obsolete\":null,\"enabled\":true}"))
```

object 中的 `null` 删除目标成员；非 object patch 替换整个目标。`apply` 不修改输入，
`applyInPlace` 与 JSON Patch 具有相同的原子提交和返回根规则。

## JSONPath（RFC 9535）

```cangjie
let path = JsonPath.parse("$.store.book[?(@.price < 10 && match(@.title, '^[A-Z]'))].title")
for (matched in path.query(root)) {
    println("${matched.normalizedPath}: ${matched.value}")
}
```

支持 name、index（含负索引）、wildcard、union、array slice、descendant 和 filter selector；
filter 支持存在性、`!`、`&&`、`||`、JSON 比较，以及 RFC 内建的 `length`、`count`、
`value`、`match`、`search`。结果携带以 `$` 开始的 normalized path。`values` 只返回节点，
`first` 返回第一个 match。

## 官方 conformance gate

仓库内的独立 consumer 只通过 yjson public API 运行固定 revision 的官方测试：

| 标准 | 结果 |
| --- | ---: |
| JSONPath RFC 9535 | **703/703 PASS** |
| JSON Patch RFC 6902 | **108/108 PASS** |

JSON Patch 数量包含启用的基础与规范用例；suite revision 与验收策略由维护者 gate 固定。
