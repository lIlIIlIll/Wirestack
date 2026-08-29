# JSON Pointer、JSONPath 与 Patch

这组 API 都操作 `JsonNode`，但解决的问题不同：Pointer 定位一个明确位置，JSONPath 查询
零到多个结果，Patch 描述可验证的变更。

这些类型位于可选 `yjson_algorithms` package：

```cangjie
import yjson.*
import yjson_algorithms.*
```

## JSON Pointer（RFC 6901）

```cangjie
let root = YJson.parse("{\"users\":[{\"name\":\"Alice\"}]}")
let pointer = JsonPointer.parse("/users/0/name")
let name = pointer.evaluate(root).asString().value
```

`~0` 表示 `~`，`~1` 表示 `/`。语法错误使用 `invalid_json_pointer`，路径不存在使用
`json_pointer_not_found`。

## JSONPath（RFC 9535）

```cangjie
let path = JsonPath.parse("$.users[*].name")
let matches = path.query(root)
```

JSONPath 返回零到多个匹配，适合筛选和遍历，不应拿来替代需要唯一位置语义的 Pointer。
无效表达式使用 `invalid_json_path`。

## JSON Patch（RFC 6902）

```cangjie
let patch = JsonPatch.parse("""
[
  {"op":"test","path":"/version","value":1},
  {"op":"replace","path":"/name","value":"Bob"}
]
""")
let updated = patch.apply(root)
```

支持 add、remove、replace、move、copy、test。Patch 文档无效使用
`invalid_json_patch`，test 不成立使用 `json_patch_test_failed`。调用方应把 Patch 应用结果
当作新的文档状态，不依赖失败过程中的局部修改。

## JSON Merge Patch（RFC 7396）

Merge Patch 适合按对象形状表达更新：object 中的 `null` 表示删除对应成员，其他值替换或
递归合并。数组不做逐元素 merge，而是整体替换。

处理不可信 Patch/Path 输入时，除对原始 JSON 设置[解析资源预算](resource-limits.md)外，还要
保留默认 `JsonPathLimits` / `JsonPatchLimits`，或传入更严格的预算。可信离线任务才应显式
使用 `.unlimited`。预算耗尽抛出 `JsonWorkLimitException`，error code 为
`work_limit_exceeded`。标准套件的固定 revision、case 数和 release gate 见
[测试指南](maintainers/testing.md)。
