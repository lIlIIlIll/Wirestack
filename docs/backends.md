# Backend 使用指南

yjson 默认使用 Pure Cangjie 实现。Native backend 是独立 package，只有应用显式声明依赖并调用对应 API 时才会参与构建或运行；core 不会静默启用 Native，也不会在 Native package 构建失败后自动回退。

`1.0.0-rc.1` 尚未发布到 registry，且当前 cjpm manifest 无法表达 prerelease 后缀；
本文统一展示候选阶段可用的 checkout path dependency。

## 如何选择

| 场景 | 建议入口 |
| --- | --- |
| 普通 typed encode/decode | `YJson`，Pure Cangjie |
| 需要修改 JSON 树 | `JsonNode` |
| 可切换 backend 的只读访问 | `YJson.parseDocument` |
| 跨平台、低额外依赖的只读访问 | `PureCompactBackend`（默认） |
| 需要 Native-owned Compact DOM | `NativeCompactBackend` |
| 大文档批量遍历或根对象查询 | `YyjsonBackend` |
| 不希望管理资源生命周期 | Pure Cangjie API |

优先从 Pure Cangjie 开始。只有 profiling 表明 DOM 构建或遍历是瓶颈，并且部署平台可以构建 C11 源码时，再选择 Native package。

## Pure Cangjie

`yjson` 本身没有 Native link dependency：

```toml
[dependencies]
yjson = { path = "../yjson" }
```

typed codec、`JsonNode` 和 `CompactJsonDocument` 都可以在这个边界内使用。完整入口对比见 [API 选择指南](choosing-an-api.md)。

三个 document backend 现在共享同一个入口和生命周期接口：

```cangjie
try (document = YJson.parseDocument("{\"n\":42}")) {
    // 未指定 backend 时使用 PureCompactBackend
    println(document.getRootInt("n").getOrThrow())
}
```

`JsonDocument` 提供 `rootSize`、根对象整数查询、`materialize`、序列化和
`close`。需要任意深度查询时，显式调用 `materialize()` 得到脱离 document
生命周期的 `JsonNode`。统一 facade 不伪造所有 backend 都具备的逐节点零复制
view；需要该能力或 storage stats、遍历 checksum 等调优接口时，继续直接使用
backend 的具体 document 类型。

统一入口拥有输入语义：`parseDocument(bytes)` 返回后，调用方可以修改或复用原数组。
Pure backend 因而会复制输入；明确需要零复制且能保证数组不可变时，直接使用
`CompactJsonDocument.parseBorrowed`。

## Custom Native Compact DOM

依赖必须与 core 使用相同版本：

```toml
[dependencies]
yjson = { path = "../yjson" }
yjson_native = { path = "../yjson/packages/yjson_native" }
```

文档拥有 Native 资源，应使用 `try` 确定性关闭。由文档取得的 value view 不能越过文档生命周期：

```cangjie
import yjson.*
import yjson_native.*

let bytes = unsafe { "{\"n\":42}".rawData() }
try (document = YJson.parseDocument(bytes, backend: NativeCompactBackend)) {
    println(document.getRootInt("n").getOrThrow())
}
```

DOM parse 与全局 scanner activation 相互独立；使用 `NativeCompactJsonDocument` 不需要调用 `enableYJsonNative()`。
需要选择 source ownership 或 duplicate strategy 时，可构造
`NativeCompactJsonBackend(...)` 传给同一个入口。

## yyjson Direct Native DOM

```toml
[dependencies]
yjson = { path = "../yjson" }
yjson_yyjson = { path = "../yjson/packages/yjson_yyjson" }
```

```cangjie
import yjson.*
import yjson_yyjson.*

let bytes = unsafe { "{\"n\":42}".rawData() }
try (document = YJson.parseDocument(bytes, backend: YyjsonBackend)) {
    println(document.getRootInt("n").getOrThrow())
}
```

package vendoring yyjson 0.12.0，并在其 Cangjie 动态库中隐藏实现符号，避免与应用独立链接的其他 yyjson 版本直接冲突。
qualification 参数可通过 `YyjsonCompactJsonBackend(...)` 显式配置；支持的默认路径仍是
Direct、SemanticDispatch、Retained 与 Separate。

## 可选 Float64 fast-parser bridge

`yjson_native` 也可以只安装 generated fast codec 使用的 Float64 token parser。它是进程级状态，应在并发 decode 开始前完成启用，并始终成对恢复：

```cangjie
enableYJsonNativeFloatOnly()
try {
    // typed decode
} finally {
    disableYJsonNativeFloatOnly()
}
```

Full、FloatOnly 与 NumericOnly 模式互斥。Native parser 缺失或拒绝一个已验证 token 时，core 会使用 portable parser；这不等于 Native package 构建失败时的静默回退。

## 生命周期与并发

- `close()` 必须拥有文档的独占访问权；不要与 read 或 serialize 并发。
- 文档及其 value view 不是 thread-safe；跨线程访问需要调用方同步。
- `close()` 后不得继续访问文档或任何派生 view。
- parse 失败会抛出 `JsonException`，并遵循 `JsonReadConfig` 的错误位置与资源限制设置。

重复键、数字策略、错误码和资源限制以 Pure Cangjie 语义为基准。各 backend 的拒绝阶段可能不同，但公开结果必须保持一致；细节见 [资源限制](resource-limits.md)。

## 构建边界

`yjson_native` 和 `yjson_yyjson` 各自通过 package-local `build.cj` 编译 Native 源码。下游应用只有在依赖这些 package 时才需要相应 C11 toolchain；依赖 `yjson` 或 `yjson_all` 不需要 Native build hook。

C ABI、Float64 bridge、symbol isolation、semantic index、随机化 seed 与 sanitizer/fuzz gate 见 [Native backend 内部契约](maintainers/native-internals.md)。
