# yjson_all

普通应用推荐的聚合 package，同时导出 `yjson` runtime 与 `yjson_macros` 中的
`@JsonCodec`、`@Json`、`@JsonValue`：

`1.0.0-rc.1` 尚未发布到 registry，候选阶段使用 path dependency：

```toml
[dependencies]
yjson_all = { path = "../yjson/packages/yjson_all" }
```

```cangjie
import yjson_all.*

@JsonCodec
class User {
    public let id: Int64
    public init(id: Int64) { this.id = id }
}

main(): Unit {
    let text = YJson.toJson(User(7))
    println(YJson.fromJson<User>(text).id)
}
```

只需要 parser、AST、Compact DOM 或 built-in codec 时，可以直接依赖 `yjson`；需要
macro 时优先使用本聚合 package。

`yjson_all` keeps runtime and macro versions aligned. It does not build or enable optional Native
DOM backends.

完整指南见仓库的 [文档入口](../../docs/README.md)。
