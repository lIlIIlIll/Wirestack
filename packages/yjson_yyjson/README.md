# yjson_yyjson

显式可选的 yyjson backend façade，vendoring 未修改的 yyjson 0.12.0 source（MIT License）。

```toml
[dependencies]
yjson = { path = "../yjson" }
yjson_backends = { path = "../yjson/packages/yjson_backends" }
yjson_yyjson = { path = "../yjson/packages/yjson_yyjson" }
```

```cangjie
import yjson.*
import yjson_backends.*
import yjson_yyjson.*

let json = YyjsonBackends.yyjson
try (document = json.parseDocument("{\"n\":42}")) {
    println(document.root().member("n").getOrThrow().asInt64())
}
```

`YyjsonBackendFacade` 提供 document、typed String/bytes 和 whole-document stream 方法。
document immutable，可并发读取，但必须关闭；关闭后访问使用 `resource_closed`。
root serialization 和 document materialization 自动使用单次读锁 bulk 路径；retained 子
view 保留逐操作读锁。

vendored `yyjson_*` symbols 在 Cangjie shared library 中本地化，以允许应用独立链接其他
yyjson 版本。package 与 core 必须版本匹配。完整生命周期见
[Backend 指南](../../docs/backends.md)，第三方许可和 checksum 见
[THIRD_PARTY_NOTICES](../../THIRD_PARTY_NOTICES.md)。
