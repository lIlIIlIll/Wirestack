# yjson_native

显式可选的 Custom Native DOM、typed stream 和 scanner package。Pure core 不依赖或自动
启用它。

## Document backend

```toml
[dependencies]
yjson = { path = "../yjson" }
yjson_native = { path = "../yjson/packages/yjson_native" }
```

```cangjie
import yjson.*
import yjson_native.*

let bytes = unsafe { "{\"n\":42}".rawData() }
try (document = YJson.parseDocument(bytes, backend: NativeCompactBackend)) {
    println(document.getRootInt("n").getOrThrow())
}
```

Document 是显式 resource、非线程安全，必须确定性 `close()`。需要 per-node view、storage
统计或 qualification knob 时才直接使用 `NativeCompactJsonDocument`。

## Typed stream

`NativeCompactStreamBackend` 以 whole-document bulk tape 驱动应用的
`JsonCodec<T>`。它不逐节点跨 FFI，不关闭 caller stream，也不静默 fallback。

## Scanner activation

DOM parse 不要求 `enableYJsonNative()`。Full、FloatOnly、NumericOnly activation 控制
process-global scanner/number seam，模式互斥；安装与移除必须发生在并发 decode 之前。

package 与 core 必须版本匹配。完整选择和生命周期见
[Backend 使用指南](../../docs/backends.md)，底层 bridge 见
[Native internals](../../docs/maintainers/native-internals.md)。
