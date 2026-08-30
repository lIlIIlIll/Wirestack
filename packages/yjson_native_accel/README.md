# yjson_native_accel

Custom Native 对默认 `YJson` semantic engine 的可选 primitive 加速。它只增加一次启动配置，
不增加第二套编码、解析或 document API。

```toml
[dependencies]
yjson = { path = "../yjson" }
yjson_native_accel = { path = "../yjson/packages/yjson_native_accel" }
```

必须在任何 `YJson` 调用前初始化：

```cangjie
import yjson.*
import yjson_native_accel.*

YJsonNativeAccel.initialize()
let text = YJson.toJson(value)
let value = YJson.fromJson<MyType>(text)
let document = YJson.parseDocument(text)
```

首次普通 `YJson` 调用会冻结 Pure；成功初始化会冻结 Native。相同初始化可幂等重复，晚
初始化、provider 竞争或 ABI/protocol 不匹配抛出 `JsonAccelerationException`。不支持
uninstall、运行期切换或故障静默回退。

`YJson.parseDocument` 仍返回 GC 管理的 Compact document，不需要 `close()`。需要显式 Native
DOM 或 WholeDocument stream 时使用 `yjson_backends` 与对应实现包。

当前 Native optional package 仅构建于 Linux x86_64；Pure `yjson` 不受这个平台边界影响。
应用不要直接依赖或导入 `yjson_native_primitives`；它是第一方包间的 closed SPI，并负责闭合
scanner 原生链接依赖。
完整契约见 [Backend 使用指南](../../docs/backends.md)。
