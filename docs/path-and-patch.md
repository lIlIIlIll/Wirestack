# JSON Pointer、JSONPath 与 Patch

这些 API 位于可选包 `yjson_algorithms`，统一读取 `JsonValueView`。Pointer 定位一个
明确位置，JSONPath 按需查询零到多个结果，Patch 描述对文档的修改。

```cangjie
import yjson.*
import yjson_algorithms.*
```

## JSON Pointer（RFC 6901）

```cangjie
let root = JsonNode.parse("{\"users\":[{\"name\":\"Alice\"}]}")
let pointer = JsonPointer.parse("/users/0/name")
let name = pointer.evaluate(root).asString()
```

`evaluate` 在目标不存在时抛出 `json_pointer_not_found`；`find` 返回
`Option<JsonValueView>`。`~0` 表示 `~`，`~1` 表示 `/`。也可以使用
`parseUriFragment` 和 `toUriFragment`。

## JSONPath（RFC 9535）

```cangjie
let path = JsonPath.parse("$.users[*].name")
let cursor = path.matches(root)

while (let Some(match) <- cursor.next()) {
    println(match.normalizedPath)
    println(match.value.asString())
}
```

`matches` 只创建游标，调用 `next()` 时才遍历数据并消耗预算。游标保存遍历状态，不要
由多个线程并发消费。也可以使用以下方法获取结果：

- `first`：找到第一个匹配后停止；
- `collect`：收集 `JsonPathMatch`；
- `collectValues`：只收集 `JsonValueView`。

无效表达式使用 `invalid_json_path`。过滤条件中的正则表达式使用内部非回溯引擎和
`maxRegexSteps` 预算；反向引用等非正则特性以 `invalid_regex` 拒绝。

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

`apply(JsonValueView)` 先复制目标并返回新 `JsonNode`；原值不变。只有明确接受修改现有 AST
时才调用 `applyInPlace(JsonNode)`。支持 add、remove、replace、move、copy 和 test。

Patch 文档无效使用 `invalid_json_patch`，路径不存在使用 `json_pointer_not_found`，test
失败使用 `json_patch_test_failed`。

## JSON Merge Patch（RFC 7396）

```cangjie
let result = JsonMergePatch.apply(target, patchValue)
```

对象中的 `null` 删除对应成员；其他值替换或递归合并。数组整体替换，不逐元素合并。`apply` 返回新树，`applyInPlace` 修改传入的 `JsonNode`。

## 工作预算

`JsonPathLimits` 和 `JsonPatchLimits` 默认有限。执行预算耗尽时抛出
`JsonException(code: "work_limit_exceeded")`。JSONPath 解析阶段超过表达式复杂度限制时，
错误码为 `invalid_json_path`。`.unlimited` 只适合可信离线任务。默认值和
每个维度的语义见[资源限制](resource-limits.md)。

固定标准语料的版本、预期用例数和执行入口见[测试指南](maintainers/testing.md)。

