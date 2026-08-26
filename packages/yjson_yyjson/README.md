# yjson_yyjson

显式可选的 yyjson Direct DOM 与 typed stream package，vendoring 未修改的 yyjson 0.12.0
source（MIT License）。

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

let bytes = unsafe { "{\"n\":42}".rawData() }
try (document = YJsonAdvanced.parseDocumentWithBackend(bytes, YyjsonDocumentBackend)) {
    println(document.getRootInt("n").getOrThrow())
}
```

Document 是显式 resource、非线程安全。`YyjsonWholeDocumentStreamBackend` 处理完整 document，再以 bulk
tape 驱动同一个 `JsonCodec<T>`；它不关闭 caller stream，也不静默切换到 Pure。

vendored `yyjson_*` symbols 在 Cangjie shared library 中本地化，以允许应用独立链接其他
yyjson 版本。package 与 core 必须版本匹配。完整生命周期见
[Backend 指南](../../docs/backends.md)，第三方许可和 checksum 见
[THIRD_PARTY_NOTICES](../../THIRD_PARTY_NOTICES.md)。
