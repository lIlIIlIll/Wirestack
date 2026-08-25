# yjson_all

普通应用推荐的 aggregate package。它同时导出 `yjson` runtime 与 `yjson_macros` 的
`@JsonCodec`、`@Json`、`@JsonValue`，但不会引入任何 Native backend。

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

当前示例使用 path dependency，不假定 registry 包已发布。aggregate、runtime 和 macro 必须
来自同一 checkout 或 release。只需要 parser/AST/built-in codec 时可直接依赖 `yjson`；
需要 Native 时由应用额外声明对应 optional package。

完整采用路径见[文档入口](../../docs/README.md)。
