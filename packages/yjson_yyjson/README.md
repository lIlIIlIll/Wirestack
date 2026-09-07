# yjson_yyjson

通过 `YyjsonBackends.yyjson` 显式使用 yyjson 后端。本包内置未经修改的 yyjson 0.12.0 源码，
采用 MIT 许可证。

在与 yjson 仓库同级的项目中，添加以下依赖：

```toml
[dependencies]
yjson = { path = "../yjson" }
yjson_backends = { path = "../yjson/packages/yjson_backends" }
yjson_yyjson = { path = "../yjson/packages/yjson_yyjson" }
```

用 `try` 在读取完成后关闭文档：

```cangjie
import yjson.*
import yjson_backends.*
import yjson_yyjson.*

let json = YyjsonBackends.yyjson
try (document = json.parseDocument("{\"n\":42}")) {
    println(document.root().member("n").getOrThrow().asInt64())
}
```

示例输出 `42`。`YyjsonBackendFacade` 提供文档解析、类型与字符串或字节数组之间的编解码，
以及整份文档缓冲的流式接口。

文档不可修改，支持并发读取，使用后必须关闭。关闭后访问返回 `resource_closed`。
序列化根视图、将整份文档转换为 AST 时，只获取一次读锁；保留的子视图则在每次操作时获取读锁。

内置的 `yyjson_*` 符号在仓颉共享库中不可见，因此应用可以独立链接另一个 yyjson 版本。
本包必须与核心包使用匹配的版本。资源管理见[后端指南](../../docs/backends.md)，
第三方许可证和校验和见 [THIRD_PARTY_NOTICES](../../THIRD_PARTY_NOTICES.md)。
