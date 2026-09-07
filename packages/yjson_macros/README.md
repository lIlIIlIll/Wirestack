# yjson_macros

本包在编译调用方代码时生成编解码器，提供以下宏：

- `@JsonCodec`：为声明生成编解码代码。
- `@JsonSubtype[wireName, ConcreteType]`：声明多态子类型。
- `@JsonUsing[codecExpression]`：指定编解码器。

字段和多态配置还会用到 `yjson` 中的注解，例如 `@JsonName`、`@JsonAlias`、
`@JsonIgnore`、`@JsonIncludeNull` 和 `@JsonPolymorphic`。

在与 yjson 仓库同级的项目中，添加以下依赖：

```toml
[dependencies]
yjson = { path = "../yjson" }
yjson_macros = { path = "../yjson/packages/yjson_macros" }
```

声明、字段和多态用法见 [`@JsonCodec` 指南](../../docs/codec-generation.md)。

## 版本要求

`yjson` 与 `yjson_macros` 必须来自同一发布版本。宏在声明所在包中展开，不扫描源码树，
也不生成需要提交到仓库的文件。生成的代码使用 generated-support v1 接口，默认快速路径还引用
`JsonFastReader`、`JsonDirectWriter` 和 `ReadCursor`。这些接口与 generated-support.v1 同步版本。

每次发布使用一个指定日期的 nightly SDK，构建和 CI 缓存同一个完整 SDK，宏也在该版本上展开和测试。
目前不承诺兼容多个 nightly。cjc 的 AST 和 token API 仍在变化，旧 nightly 生成的代码
可能无法在新版本中编译。构建应用时，请使用对应发布版本指定的 nightly。
