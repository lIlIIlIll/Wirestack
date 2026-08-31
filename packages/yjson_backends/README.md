# yjson_backends

高级 backend 的窄接口 package。普通应用直接使用 GC 管理的 `YJson` API，不依赖本包。

本包定义：

- `BackendJsonDocument <: Resource`；
- `JsonBackendMetadata`；
- `JsonStreamBufferingMode`。

具体 engine 不通过任意 strategy 注入。应用从对应实现 package 取得命名 façade：

```cangjie
let native = NativeBackends.customNative
let yyjson = YyjsonBackends.yyjson
```

`BackendJsonDocument` 的 root 使用统一 `JsonValueView`。document immutable，可并发读取，
但必须关闭；关闭后访问 view 会抛出 `JsonException(code: "resource_closed")`。

完整 lifecycle、I/O 和选型 contract 见
[Backend 使用指南](../../docs/backends.md)。

