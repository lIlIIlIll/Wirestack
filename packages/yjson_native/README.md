# yjson_native

Custom Native 的显式 backend façade。普通 `YJson` primitive 加速使用
`yjson_native_accel`；只有需要 backend metadata、resource lifetime 或 whole-document I/O
时才直接依赖本 package。

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

let json = NativeBackends.customNative
try (document = json.parseDocument("{\"n\":42}")) {
    println(document.root().member("n").getOrThrow().asInt64())
}
```

`NativeBackendFacade` 还提供 typed `toJson`、`fromJson`、`toJsonBytes` 和
`writeJson`。stream 路径按 `WholeDocument` buffering 工作，不关闭 caller-owned stream。

document immutable，可并发读取，并以线性化方式与 `close()` 竞争。关闭后访问返回
`resource_closed`。root serialization 和 document materialization 自动使用单次读锁 bulk
路径；retained 子 view 保留逐操作读锁。materialization 返回与 resource 分离的 `JsonNode`。

`0.1.0` Native qualification 范围是 Linux x86_64。完整契约见
[Backend 使用指南](../../docs/backends.md)，底层 bridge 见
[Native internals](../../docs/maintainers/native-internals.md)。
