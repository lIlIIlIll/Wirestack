# yjson_macros

调用方编译期 macro package，提供：

- declaration macro `@JsonCodec`；
- expression macro `@Json({...})`；
- expression macro `@JsonValue({...})`。

普通应用优先依赖 `yjson_all`：

```toml
[dependencies]
yjson_all = { path = "../yjson/packages/yjson_all" }
```

macro 在声明/表达式所在 package 展开，不扫描源码树，也不生成仓库级文件。生成代码只依赖
版本化 generated-support v1 SPI；SPI 不变时允许跨 patch 版本，协议不匹配会明确失败。
普通应用通过 `yjson_all` 获取由发行单元配套的 runtime 与 macro。

声明规则见 [`@JsonCodec` 指南](../../docs/codec-generation.md)，expression grammar 与插值
contract 见 [JSON 字面量](../../docs/json-literals.md)。
