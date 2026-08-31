# yjson_native_accel

Custom Native 对普通 `YJson` semantic engine 的可选 primitive 加速。它只增加一次启动配置，
不增加第二套编码、解析或 document API。

```toml
[dependencies]
yjson = { path = "../yjson" }
yjson_native_accel = { path = "../yjson/packages/yjson_native_accel" }
```

必须在任何普通 `YJson` 调用前初始化：

```cangjie
import yjson.*
import yjson_native_accel.*

YJsonNativeAccel.initialize()
let text = YJson.toJson(value)
let decoded = YJson.fromJson<MyType>(text)
let document = YJson.parseDocument(text)
```

首次普通调用会冻结 Pure；成功初始化会冻结 Native。相同 provider 的重复初始化幂等。晚
初始化、provider 竞争、ABI/protocol 不匹配或 activation 失败抛出 `JsonException`，code 以
`acceleration_` 开头。没有 uninstall、运行期切换或静默回退。

`YJson.parseDocument` 仍返回 GC 管理的 managed document，不需要 `close()`。显式 Native
resource 使用 `yjson_native` 的 `NativeBackends.customNative`。

`0.1.0` Native qualification 范围是 Linux x86_64。应用不要直接依赖
`yjson_native_primitives`；它是第一方 lockstep package 的 closed SPI。完整契约见
[Backend 使用指南](../../docs/backends.md)。

