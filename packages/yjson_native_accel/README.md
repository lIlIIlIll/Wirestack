# yjson_native_accel

本包用 Custom Native 加速普通 `YJson` 调用中的底层操作。启动时初始化一次，
之后继续使用原有的编码、解析和文档 API。

在与 yjson 仓库同级的项目中，添加以下依赖：

```toml
[dependencies]
yjson = { path = "../yjson" }
yjson_native_accel = { path = "../yjson/packages/yjson_native_accel" }
```

必须在任何普通 `YJson` 调用前初始化。下面展示调用顺序，其中 `value` 和 `MyType` 是应用自己的值和类型：

```cangjie
import yjson.*
import yjson_native_accel.*

YJsonNativeAccel.initialize()
let text = YJson.toJson(value)
let decoded = YJson.fromJson<MyType>(text)
let document = YJson.parseDocument(text)
```

首次普通调用会固定使用 Pure 引擎；初始化成功则固定使用 Native。
重复初始化同一 provider 是幂等的。初始化过晚、provider 竞争、ABI 或协议不匹配、
激活失败时，会抛出错误码以 `acceleration_` 开头的 `JsonException`。
初始化后不能卸载或切换引擎，失败时也不会静默回退。

`YJson.parseDocument` 仍返回由 GC 管理的文档，不需要 `close()`。
需要显式管理 Native 文档资源时，使用 `yjson_native` 的 `NativeBackends.customNative`。

## 构建要求

`0.1.0` 的 Native 发布验证范围是 Linux x86_64。构建前置脚本会编译扫描器静态库，需要以下工具：

- Python 3。
- C11 编译器，默认使用 `clang`，可通过 `CC` 指定。
- `ar`，可通过 `AR` 指定。

缺少工具时，`yjson_native_primitives` 的构建脚本会在编译前报错，不会静默回退到 Pure。
应用不要直接依赖 `yjson_native_primitives`，它提供内部接口，须与第一方包使用同一发布版本。
更多用法见[后端使用指南](../../docs/backends.md)。
