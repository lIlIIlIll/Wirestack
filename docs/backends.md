# Native 加速与后端选择

普通 `YJson` API 默认使用 Pure 引擎，不接受后端参数。启用 Native 加速后，JSON 的解析和
编码规则不变，只由 Native 实现部分底层操作。需要自行管理 DOM 的生命周期，或一次读入
整份文档时，可以使用独立的后端 API。

## 为普通 `YJson` 启用 Native 加速

```toml
[dependencies]
yjson = { path = "../yjson" }
yjson_native_accel = { path = "../yjson/packages/yjson_native_accel" }
```

在任何普通 `YJson` 调用之前初始化一次：

```cangjie
import yjson.*
import yjson_native_accel.*

YJsonNativeAccel.initialize()

let text = YJson.toJson(value)
let decoded = YJson.fromJson<MyType>(text)
let document = YJson.parseDocument(text)
```

第一次普通 `YJson` 调用会固定使用 Pure；在此之前成功初始化，则固定使用 Native。
重复初始化同一个 provider 不会改变结果。初始化过晚、不同 provider 竞争、ABI 或协议
不匹配、CPU 不支持，以及激活失败，都会抛出 `JsonException`，错误码以 `acceleration_`
开头。初始化后不能卸载或切换实现，发生故障也不会静默回退。

`YJson.parseDocument` 仍返回由 GC 管理的 `JsonDocument`。Native 临时资源在返回前释放，调用方
不需要 `close()`。

## 使用独立的后端 API

需要查询后端信息、自行关闭文档资源，或一次读入整份文档时，依赖 `yjson_backends`
和具体后端包。

Custom Native：

```cangjie
import yjson.*
import yjson_backends.*
import yjson_native.*

let json = NativeBackends.customNative
try (document = json.parseDocument("{\"n\":42}")) {
    println(document.root().member("n").getOrThrow().asInt64())
}
```

yyjson：

```cangjie
import yjson.*
import yjson_backends.*
import yjson_yyjson.*

let json = YyjsonBackends.yyjson
try (document = json.parseDocument("{\"n\":42}")) {
    println(document.root().member("n").getOrThrow().asInt64())
}
```

两种后端提供相同的方法：

- `metadata()`
- `parseDocument(String|Array<Byte>)`
- `toJson` / `toJsonBytes`
- `fromJson(String|Array<Byte>|InputStream)`
- `writeJson(..., OutputStream)`

类型化读写方法既支持宏生成的 provider，也支持显式传入 `codec:`。所有方法使用统一的
`JsonReadOptions`、`JsonWriteOptions`、`JsonValueView` 和 `JsonException`。

## 生命周期和并发

`BackendJsonDocument <: Resource` 必须在使用后关闭。文档及其视图在打开期间不可变，
支持并发读取。读取与 `close()` 同时发生时，每次操作要么完整成功，要么抛出
`JsonException(code: "resource_closed")`。重复关闭没有影响。关闭后，先前取得的根视图也不能再用。

无参数 `materialize()` 最多转换 100,000 个节点、256 层。`materialize(maxNodes)` 可调整
节点上限。返回的 `JsonNode` 不依赖原后端资源。

序列化后端自己的根视图，或将文档转换为 `JsonNode` 时，后端会在一次读锁内导出不可变的
tape，再在锁外完成转换。这项优化自动生效。对子视图的操作则各自获取读锁，因此需要
扫描大量节点时，优先从根视图批量处理。找到结果就停止的查询可以直接读取视图，避免先
转换整棵树。

`metadata()` 提供引擎名称、版本、是否为 Native，以及解码和编码的缓冲方式。
Custom Native 和 yyjson 的流模式是 `WholeDocument`，会读取到 EOF。普通 `YJson` 的流接口
仍然增量解析单份文档。

## 包的职责与平台支持

`yjson_native_primitives` 提供扫描器静态库和带版本的 provider 接口，只供同步发布的
第一方包使用。应用依赖 `yjson_native_accel`，不要直接安装底层 provider。

`0.1.0` 的 Native 发布验证目标是 Linux x86_64。Windows 和 macOS 的检查只覆盖 Pure。
C ABI、符号隔离和仓库内置 yyjson 的维护规则见
[Native 内部实现](maintainers/native-internals.md)。
