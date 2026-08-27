# yjson_backends

高级 backend 的窄接口包。普通应用不依赖本包，直接使用增量、GC 管理的 `YJson` API；只有
明确需要 Custom Native/yyjson DOM 或 WholeDocument stream 时才使用 `YJsonAdvanced`。

`BackendJsonDocument <: Resource` 暴露 backend identity 和显式生命周期，必须确定性
`close()`。`JsonStreamBackend` 通过 `JsonStreamBufferingMode` 声明 Incremental 或
WholeDocument buffering；高级 adapter 不会改变默认 `YJson.toStream/fromStream` 的增量语义。

```cangjie
import yjson_backends.*
import yjson_yyjson.*

try (document = YJsonAdvanced.parseDocumentWithBackend(bytes, YyjsonDocumentBackend)) {
    println(document.getRootInt("n").getOrThrow())
}
```

本包只定义 SPI 与 `YJsonAdvanced`；具体实现由 `yjson_native` 或 `yjson_yyjson` 提供。选型与
完整 lifecycle contract 见 [Backend 使用指南](../../docs/backends.md)。
