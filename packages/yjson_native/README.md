# yjson_native

Custom Native 实现包。普通应用应依赖 `yjson_native_accel` 并在启动时调用一次
`YJsonNativeAccel.initialize()`；本包中的 DOM 与 whole-document stream 仅供高级 API 使用。

## Document backend

```toml
[dependencies]
yjson = { path = "../yjson" }
yjson_backends = { path = "../yjson/packages/yjson_backends" }
yjson_native = { path = "../yjson/packages/yjson_native" }
```

```cangjie
import yjson.*
import yjson_backends.*
import yjson_native.*

let bytes = unsafe { "{\"n\":42}".rawData() }
try (document = YJsonAdvanced.parseDocumentWithBackend(bytes, NativeCompactDocumentBackend)) {
    println(document.getRootInt("n").getOrThrow())
}
```

Document 是显式 resource、非线程安全，必须确定性 `close()`。需要 per-node view、storage
统计或 qualification knob 时才直接使用 `NativeCompactJsonDocument`。

## Typed stream

`NativeCompactWholeDocumentStreamBackend` 以 whole-document bulk tape 驱动应用的
`JsonCodec<T>`。它不逐节点跨 FFI，不关闭 caller stream，也不静默 fallback。

## 普通 API 加速

普通应用不直接安装或移除 scanner seam。`YJsonNativeAccel.initialize()` 在首次 `YJson`
调用前一次性冻结 Native profile；之后仍使用 `YJson.toJson/fromJson/parseDocument`。

package 与 core 必须版本匹配。完整选择和生命周期见
[Backend 使用指南](../../docs/backends.md)，底层 bridge 见
[Native internals](../../docs/maintainers/native-internals.md)。
