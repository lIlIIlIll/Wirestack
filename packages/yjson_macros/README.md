# yjson_macros

调用方编译期 macro package，提供：

- declaration macro `@JsonCodec`；
- wrapper macro `@JsonSubtype[wireName, ConcreteType]`；
- wrapper macro `@JsonUsing[codecExpression]`。

字段和多态配置还使用 `yjson` runtime 中的 metadata annotation，例如 `@JsonName`、
`@JsonAlias`、`@JsonIgnore`、`@JsonIncludeNull` 和 `@JsonPolymorphic`。

使用 generated codec 的应用直接依赖 runtime 与 macro package：

```toml
[dependencies]
yjson = { path = "../yjson" }
yjson_macros = { path = "../yjson/packages/yjson_macros" }
```

macro 在声明所在 package 展开，不扫描源码树，也不生成 checked-in 文件。生成代码只依赖
versioned generated-support v1 bridge；runtime 与 macro 必须来自同一 lockstep release。

声明、字段和多态规则见
[`@JsonCodec` 指南](../../docs/codec-generation.md)。

