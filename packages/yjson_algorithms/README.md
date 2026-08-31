# yjson_algorithms

JSON Pointer、JSON Patch、JSON Merge Patch、JSONPath 和 JSON Schema draft 2020-12 的可选
package。普通 typed encode/decode、AST 和 managed document 不需要依赖本包。

```toml
[dependencies]
yjson = { path = "../.." }
yjson_algorithms = { path = "../yjson_algorithms" }
```

```cangjie
import yjson.*
import yjson_algorithms.*

let root = JsonNode.parse("{\"users\":[{\"name\":\"Alice\"}]}")
let first = JsonPath.parse("$.users[*].name").first(root).getOrThrow()
println(first.value.asString())
```

算法对不可信输入使用有限默认预算：

| API | 默认预算 |
| --- | --- |
| `JsonPathLimits` | 100,000 visited/filter/regex；10,000 matches；depth 256 |
| `JsonPatchLimits` | 10,000 operations；256 pointer segments；100,000 copied nodes |
| `JsonSchemaLimits` | 100,000 evaluations/regex；1,000 ref resolutions；100 errors；depth 256 |

预算耗尽统一抛出 `JsonException(code: "work_limit_exceeded")`。可信离线任务可显式传入
对应的 `.unlimited`。

JSONPath `matches()` 返回惰性、单线程 cursor。Schema 在构造阶段复制文档、冻结 resolver
图并编译受限 regex；validation 不访问网络或 resolver。

使用示例见 [Pointer、Path 与 Patch](../../docs/path-and-patch.md)和
[JSON Schema](../../docs/schema.md)。

