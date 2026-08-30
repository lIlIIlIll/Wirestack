# yjson examples

该 executable 展示不需要 Native toolchain 的最短用户路径：

1. `@JsonCodec` typed roundtrip；
2. `@Json` runtime interpolation；
3. 显式 `JsonReadConfig`；
4. 可修改 `JsonNode`；
5. Pure Compact 查询；
6. built-in codec roundtrip。

在本目录、准备好仓颉 SDK 环境后运行：

```shell
cjpm run
```

示例显式依赖 `yjson` 与 `yjson_macros`，因此不会构建或启用 Native backend。Stream、Schema 与 Native
分别见 [Stream I/O](../../docs/streams.md)、[JSON Schema](../../docs/schema.md)和
[Backend 使用指南](../../docs/backends.md)。
