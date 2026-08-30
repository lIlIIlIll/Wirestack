# yjson_macros

调用方编译期 macro package，提供：

- declaration macro `@JsonCodec`；
- expression macro `@Json({...})`；
- expression macro `@JsonValue({...})`。

使用 macro 的应用显式依赖 runtime 与 macro package：

```toml
[dependencies]
yjson = { path = "../yjson" }
yjson_macros = { path = "../yjson/packages/yjson_macros" }
```

macro 在声明/表达式所在 package 展开，不扫描源码树，也不生成仓库级文件。生成代码只依赖
版本化 generated-support v1 SPI；协议不匹配会明确失败。`yjson_macros` 自身也声明同版本
`yjson` 依赖，使依赖解析器能够检查真实的生成代码闭包。

声明规则见 [`@JsonCodec` 指南](../../docs/codec-generation.md)，expression grammar 与插值
contract 见 [JSON 字面量](../../docs/json-literals.md)。
