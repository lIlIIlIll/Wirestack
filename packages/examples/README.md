# yjson 示例

本包展示常用 API，不需要 Native 构建工具：

1. 用 `@JsonCodec` 完成类型编解码。
2. 用 `JsonReadOptions` 限制输入。
3. 修改 `JsonNode`。
4. 用 `JsonWriteOptions.pretty()` 格式化输出。
5. 显式使用内置编解码器。

准备仓颉 SDK 环境后，在本目录运行：

```terminal
cjpm run
```

示例直接依赖 `yjson` 与 `yjson_macros`，不会构建或启用 Native 包。
流式处理、Schema 校验和后端用法分别见 [Stream I/O](../../docs/streams.md)、
[JSON Schema](../../docs/schema.md)和[后端使用指南](../../docs/backends.md)。
