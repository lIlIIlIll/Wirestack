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

macro 在声明所在 package 展开，不扫描源码树，也不生成 checked-in 文件。生成代码依赖
versioned generated-support v1 bridge，并在 default fast path 引用具体
`JsonFastReader` / `JsonDirectWriter` / `ReadCursor`（与 generated-support.v1 同版本锁定）；
runtime 与 macro 必须来自同一 lockstep release。

### cjc 构建范围

每个 release 锁定单一 nightly：构建与 CI 解析并缓存同一个完整 dated nightly，宏在该
nightly 上展开、测试和发布。多 nightly 构建矩阵不在承诺范围内，也不保证跨 nightly 的
宏展开行为一致。cjc 的 AST/token API 仍在演进，不同 nightly 之间可能改变 decl macro 可观察
到的 AST 形态、token 序列或展开时机；锁定的 release 之外请使用 release 指定的 nightly
重新构建消费方，而不是假定旧 nightly 生成的代码可以在新 nightly 上原样编译。

声明、字段和多态规则见
[`@JsonCodec` 指南](../../docs/codec-generation.md)。

