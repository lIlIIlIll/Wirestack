# yjson_native

通过 `NativeBackends.customNative` 显式使用 Custom Native 后端。需要查看后端信息、
自行管理文档资源，或使用整份文档缓冲的 I/O 接口时，依赖本包。
若只想加速普通 `YJson` 调用，使用 `yjson_native_accel`。

在与 yjson 仓库同级的项目中，添加以下依赖：

```toml
[dependencies]
yjson = { path = "../yjson" }
yjson_backends = { path = "../yjson/packages/yjson_backends" }
yjson_native = { path = "../yjson/packages/yjson_native" }
```

用 `try` 在读取完成后关闭文档：

```cangjie
import yjson.*
import yjson_backends.*
import yjson_native.*

let json = NativeBackends.customNative
try (document = json.parseDocument("{\"n\":42}")) {
    println(document.root().member("n").getOrThrow().asInt64())
}
```

示例输出 `42`。`NativeBackendFacade` 还提供类型编解码方法 `toJson`、`fromJson`、
`toJsonBytes` 和 `writeJson`。流式接口使用 `WholeDocument` 缓冲，不会关闭调用方传入的流。

文档不可修改，支持并发读取。读取与 `close()` 按确定的先后顺序执行，关闭后访问返回
`resource_closed`。序列化根视图、将整份文档转换为 AST 时，只获取一次读锁；
保留的子视图则在每次操作时获取读锁。转换得到的 `JsonNode` 独立于原文档资源。

`0.1.0` 的 Native 发布验证范围是 Linux x86_64。使用约定见
[后端使用指南](../../docs/backends.md)，底层实现见
[Native 实现说明](../../docs/maintainers/native-internals.md)。
