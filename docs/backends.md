# Native 加速与显式 Backend

普通 `YJson` API 不接受 backend 参数。默认 Pure 引擎由 GC 管理；可选 Native acceleration
只替换同一 semantic engine 的 primitive。需要显式 DOM 或 whole-document I/O 时，再选择命名
backend façade。

## 为普通 `YJson` 启用 Native primitive

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

第一次普通 `YJson` 调用会冻结 Pure；成功初始化会冻结 Native。相同 provider 的重复初始化
幂等。晚初始化、不同 provider 竞争、ABI/protocol 不匹配、CPU 不支持和 activation 失败都抛出
`JsonException`，code 以 `acceleration_` 开头。没有 uninstall、运行期切换或静默回退。

`YJson.parseDocument` 仍返回 managed `JsonDocument`。Native 临时资源在返回前释放，调用方
不需要 `close()`。

## 使用命名 backend façade

只有需要 backend metadata、显式 resource lifetime 或 whole-document I/O 的应用才依赖
`yjson_backends` 和具体实现。

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

façade 提供：

- `metadata()`
- `parseDocument(String|Array<Byte>)`
- `toJson` / `toJsonBytes`
- `fromJson(String|Array<Byte>|InputStream)`
- `writeJson(..., OutputStream)`

typed 方法既支持 generated provider，也支持显式 `codec:`。所有方法使用统一
`JsonReadOptions`、`JsonWriteOptions`、`JsonValueView` 和 `JsonException`。

## 生命周期和并发

`BackendJsonDocument <: Resource` 必须确定性关闭。document 及其 view 在打开期间 immutable，
支持并发读取；与 `close()` 竞争时，每次操作要么完整成功，要么抛出
`JsonException(code: "resource_closed")`。关闭幂等。关闭后，先前取得的 root view 也不能再用。

无参数 `materialize()` 使用 100,000 节点和 256 层边界；`materialize(maxNodes)` 可降低或
提高 node budget。返回的 `JsonNode` 与 backend resource 分离。

对 backend 自己的 root view，façade serialization 和 document materialization 自动在一次
读锁内导出 immutable tape，再在锁外完成转换。调用方不需要选择 fast-path 参数。任意 retained
子 view 继续按操作获取读锁，因此大量逐节点扫描应优先使用 root bulk 操作；早停查询则直接在
view 上执行，避免先 materialize 整棵树。

`metadata()` 公开 engine 名称、版本、是否 Native，以及 decode/encode buffering mode。
Custom Native 和 yyjson façade 的 stream 模式是 `WholeDocument`；它们会读取到 EOF。普通
`YJson` stream 入口仍是 incremental single-document parser。

## Package 边界

`yjson_native_primitives` 拥有 scanner archive 和版本化 provider seam，只供第一方 lockstep
package 使用。应用依赖 `yjson_native_accel`，不要直接安装 primitive provider。

`0.1.0` 的 Native qualification 目标是 Linux x86_64。Pure Windows/macOS gate 不意味着
Native package 已在这些平台受支持。C ABI、symbol isolation 和 vendored yyjson 规则见
[Native backend internals](maintainers/native-internals.md)。
