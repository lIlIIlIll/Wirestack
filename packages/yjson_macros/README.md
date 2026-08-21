# yjson_macros

`yjson` 的调用方编译期 macro package，提供：

- declaration macro `@JsonCodec`；
- expression macro `@Json({...})`；
- expression macro `@JsonValue({...})`。

多数应用应依赖 `yjson_all`，它组合 runtime 与本 package，且不会启用 Native backend：

`1.0.0-rc.1` 尚未发布到 registry，且当前 cjpm manifest 无法表达 prerelease 后缀；
候选阶段请从仓库 checkout 使用 path dependency。

```toml
[dependencies]
yjson_all = { path = "../yjson/packages/yjson_all" }
```

```cangjie
import yjson_all.*

@JsonCodec
struct Point {
    public let x: Int64
    public let y: Int64
    public init(x: Int64, y: Int64) { this.x = x; this.y = y }
}

let text = @Json({"point": $(Point(3, 4))})
```

Generated fast collection codecs call the public
`JsonFastReader.suggestRawCollectionCapacity()` bridge in the runtime. The
macro package is therefore source-version coupled to `yjson`: use matching
versions (the publish manifests pair `yjson_macros = "1.0.0"` with `yjson = "1.0.0"`). The
repository development manifest uses a path dependency because the core
test/fixture sources also use the macro during repository builds; release manifests pin the exact
central-repository versions. Prefer the checkout `yjson_all` path dependency for applications so
the pair is selected together.

字段、构造器、enum 与多态规则见 [`@JsonCodec` 指南](../../docs/codec-generation.md)；
literal grammar 见 [JSON 字面量](../../docs/json-literals.md)。
