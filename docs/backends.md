# Native 加速与高级 Backend

yjson 2.0 的普通 API 没有 backend 参数。默认 Pure 引擎跨平台、GC 管理；可选 Native
加速只改变同一 semantic engine 的 primitive，不改变应用调用方式。

## 启动时启用 Custom Native

```toml
[dependencies]
yjson_all = { path = "../yjson/packages/yjson_all" }
yjson_native_accel = { path = "../yjson/packages/yjson_native_accel" }
```

在任何 `YJson` 调用前初始化一次：

```cangjie
YJsonNativeAccel.initialize()

let text = YJson.toJson(value)
let value = YJson.fromJson<MyType>(text)
let document = YJson.parseDocument(text)
```

第一次普通 `YJson` 调用会冻结 Pure；成功初始化会冻结 Native。相同 Native 初始化可幂等
重复。晚初始化、不同 provider 竞争、ABI/protocol 不匹配或缺少 Native 能力都会抛出
`JsonAccelerationException`。不支持 uninstall、运行期切换或静默回退。

默认 `JsonDocument` 始终是 managed Compact representation；Native 临时资源在
`parseDocument` 返回前释放，调用方不需要 `close()`。

## 高级显式 Backend

只有确实需要 Native/yyjson DOM 或 whole-document stream 的应用才依赖
`yjson_backends` 以及对应实现包：

```cangjie
import yjson_backends.*
import yjson_yyjson.*

try (document = YJsonAdvanced.parseDocumentWithBackend(bytes, YyjsonDocumentBackend)) {
    println(document.getRootInt("n").getOrThrow())
}
```

高级 document 类型为 `BackendJsonDocument <: Resource`，必须确定性关闭；它不是线程
安全对象。高级 stream 使用名称明确的 `NativeCompactWholeDocumentStreamBackend` 或
`YyjsonWholeDocumentStreamBackend`：

```cangjie
YJsonAdvanced.encodeToStreamWithBackend(
    UserJson, user, output, NativeCompactWholeDocumentStreamBackend)
```

WholeDocument backend 会读取到 EOF；普通 `YJson.toStream/fromStream` 不会，它们始终使用
增量 reader/writer。所有 target 仍共享相同的配置、错误码和 writer 结构状态机。

底层 ABI、symbol isolation 与安全契约见
[Native backend internals](maintainers/native-internals.md)。
