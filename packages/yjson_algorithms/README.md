# yjson_algorithms

本包提供 JSON Pointer、JSON Patch、JSON Merge Patch、JSONPath 和 JSON Schema draft 2020-12。
仅使用类型编解码、AST 或 GC 管理的文档时，无需添加此依赖。

下面的依赖路径适用于仓库 `packages` 下的示例项目：

```toml
[dependencies]
yjson = { path = "../.." }
yjson_algorithms = { path = "../yjson_algorithms" }
```

用 JSONPath 读取用户名：

```cangjie
import yjson.*
import yjson_algorithms.*

let root = JsonNode.parse("{\"users\":[{\"name\":\"Alice\"}]}")
let first = JsonPath.parse("$.users[*].name").first(root).getOrThrow()
println(first.value.asString())
```

这段代码输出 `Alice`。更多用法见 [Pointer、Path 与 Patch](../../docs/path-and-patch.md)和
[JSON Schema](../../docs/schema.md)。

## 处理限制

各算法默认限制处理量：

| API | 默认限制 |
| --- | --- |
| `JsonPathLimits` | 访问节点、过滤候选和正则步骤各 100,000 次；匹配 10,000 项；遍历深度 256 |
| `JsonPatchLimits` | 10,000 个操作；指针 256 段；复制 100,000 个节点 |
| `JsonSchemaLimits` | 求值和正则步骤各 100,000 次；引用解析 1,000 次；错误 100 个；深度 256 |

JSONPath 还限制单个过滤表达式为 4,096 字节、256 个逻辑运算符和 64 层逻辑嵌套。
一次执行最多计算 200,000 次逻辑运算。过滤候选数与逻辑运算次数分别计数。

JSONPath 解析时超过表达式长度、运算符数量或递归深度限制，抛出 `invalid_json_path`；
执行阶段耗尽预算时，抛出 `JsonException(code: "work_limit_exceeded")`。
解析限制通过 `JsonPath.parse(expression, limits: limits)` 指定。对可信的离线任务，
可显式传入对应的 `.unlimited`。

`JsonPath.matches()` 返回惰性游标，限单线程使用。Schema 在构造时复制文档、
固定 resolver 解析出的资源图，并编译受支持的正则表达式。校验期间不会访问网络或调用 resolver。
