# Backend 使用指南

yjson 默认使用 Pure Cangjie。Native backend 是独立 package，只有应用显式声明依赖并选择
对应 API 时才参与构建或运行；构建或执行失败不会被静默 fallback 隐藏。

## 先从 Pure 开始

| 场景 | 推荐入口 |
| --- | --- |
| 普通 typed encode/decode | `YJson` + Pure codec path |
| 需要修改 JSON | `JsonNode` |
| Portable 只读查询 | `YJson.parseDocument`，默认 `PureCompactBackend` |
| Native-owned Compact DOM | `NativeCompactBackend` |
| yyjson Direct DOM | `YyjsonBackend` |
| Typed caller-owned stream | 默认 Pure；profiling 后显式选 Native stream backend |

Native 只有在 profiling 显示 DOM parse、遍历或较大 typed decode 是瓶颈，并且部署平台能
构建 C11 source 时才值得引入。当前阻断 qualification 平台是 Linux x86_64；其他平台只能
描述为未验证、可能支持。

## 添加依赖

Custom Native：

```toml
[dependencies]
yjson = { path = "../yjson" }
yjson_native = { path = "../yjson/packages/yjson_native" }
```

yyjson Direct：

```toml
[dependencies]
yjson = { path = "../yjson" }
yjson_yyjson = { path = "../yjson/packages/yjson_yyjson" }
```

示例不假定 registry 包已发布。core 与 optional package 必须来自同一 checkout 或 release。

## 统一 document facade

```cangjie
let bytes = unsafe { "{\"n\":42}".rawData() }

try (document = YJson.parseDocument(bytes, backend: NativeCompactBackend)) {
    println(document.getRootInt("n").getOrThrow())
}
```

同一入口还接受默认 `PureCompactBackend` 和 `YyjsonBackend`。需要后端专有 view、统计或
qualification knob 时，才直接使用 `NativeCompactJsonDocument` 或
`YyjsonCompactJsonDocument`。

## 生命周期与并发

- Pure Compact 由 GC 管理，不需要 `close()`。
- Native document 必须用 `try (document = ...)` 或 `finally` 确定性关闭。
- Native document 不是线程安全对象；并发 read/read 也需要外部同步。
- read/close、serialize/close race 禁止；`close()` 需要独占所有权。
- `close()` 幂等；close 后操作抛出 `IllegalStateException`。
- view 会保持 owner 可达，但 owner 关闭后 view 也失效。

析构器只是泄漏兜底，不是生命周期 API。

## Typed stream backend

`NativeCompactStreamBackend` 与 `YyjsonStreamBackend` 以 whole-document 模式驱动同一个
backend-neutral `JsonCodec<T>`。它们跨 ABI 执行 bulk parse/export 或 encode/copy，不做
per-node FFI，不关闭 caller stream，也不静默回退。

所有 backend 保持相同的公开配置语义；错误 message 和 Native 内部分类不要求逐字一致，
资源预算的 `JsonException.code` 必须一致。

## Scanner activation 不是 DOM 依赖

`NativeCompactJsonDocument` 不要求调用 `enableYJsonNative()`。后者安装 process-global
scanner/number seam，必须在并发 decode 开始前完成；Full、FloatOnly、NumericOnly 模式
互斥，切换前应使用匹配的 disable 函数。

底层 ABI、symbol isolation 与安全契约见
[Native backend internals](maintainers/native-internals.md)。
