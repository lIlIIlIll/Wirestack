# yjson examples

这个 executable 展示不依赖 Native toolchain 的普通用户路径：

1. `@JsonCodec` typed roundtrip；
2. `JsonReadOptions` 输入预算；
3. 可修改 `JsonNode`；
4. `JsonWriteOptions.pretty()`；
5. 显式 built-in codec。

准备仓颉 SDK 环境后，在本目录运行：

```terminal
cjpm run
```

示例直接依赖 `yjson` 与 `yjson_macros`，不会构建或启用 Native package。Stream、Schema
和 Native 分别见 [Stream I/O](../../docs/streams.md)、
[JSON Schema](../../docs/schema.md)和
[Backend 使用指南](../../docs/backends.md)。

