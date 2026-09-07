# yjson_backends

本包定义显式后端共用的接口。普通应用使用由 GC 管理的 `YJson` API，无需依赖本包。

本包提供以下类型：

- `BackendJsonDocument <: Resource`：需要关闭的文档资源。
- `JsonBackendMetadata`：后端信息。
- `JsonStreamBufferingMode`：流式接口的缓冲方式。

应用通过各实现包提供的入口选择后端，不支持注入任意实现：

```cangjie
let native = NativeBackends.customNative
let yyjson = YyjsonBackends.yyjson
```

`BackendJsonDocument.root()` 返回统一的 `JsonValueView`。文档不可修改，支持并发读取，
使用后必须关闭。关闭后访问视图会抛出 `JsonException(code: "resource_closed")`。

资源管理、I/O 行为和后端选择见[后端使用指南](../../docs/backends.md)。
