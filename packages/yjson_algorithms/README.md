# yjson_algorithms

从默认 runtime 拆出的 JSON Pointer、JSON Patch、JSON Merge Patch、JSONPath 与 JSON Schema
draft 2020-12。普通 typed encode/decode、AST 与 Compact document 不需要依赖本包。

```toml
[dependencies]
yjson = { path = "../.." }
yjson_algorithms = { path = "../yjson_algorithms" }
```

```cangjie
import yjson.*
import yjson_algorithms.*

let root = YJson.parse("{\"users\":[{\"name\":\"Alice\"}]}")
let matches = JsonPath.parse("$.users[*].name").query(root)
```

算法对不可信输入使用有限默认预算：

| API | 默认预算 |
| --- | --- |
| `JsonPathLimits` | 100000 visited nodes；100000 filter steps；10000 matches；depth 256 |
| `JsonPatchLimits` | 10000 operations；256 pointer segments；100000 copied nodes |
| `JsonSchemaLimits` | 100000 evaluations；1000 ref resolutions；100 errors；depth 256 |

预算耗尽统一抛出 `JsonWorkLimitException`，稳定 error code 为 `work_limit_exceeded`。可信离线
任务可显式传入对应的 `.unlimited`。Schema resource 只能通过注入的 `UriResolver` 解析；
本包默认不访问网络。

使用示例见 [Pointer、Path 与 Patch](../../docs/path-and-patch.md)和
[JSON Schema](../../docs/schema.md)。
