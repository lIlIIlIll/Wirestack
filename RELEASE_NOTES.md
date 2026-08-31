# Release notes: 0.1.0

`0.1.0` 开启 yjson 当前的实验版本线。版本号降低是有意的成熟度重置：仓库没有已知的 package
registry 用户，项目将在 `0.x` 阶段继续简化 API，再冻结未来的稳定 `1.0.0` 契约。

既有 `1.0.0-rc.1`、`2.0.0` tag、GitHub Release、带日期的性能报告和 evidence 保持不可变，
作为历史原型保留；它们不定义 `0.1.x` 的兼容性。历史仓库路径
`release/2.0.0/evidence.md` 继续用于审计和性能基线，但不进入 `0.1.0` source archive。

## Package graph

本版本包含九个使用同一版本号和候选 SHA 的 lockstep package：

| Package | 职责 |
| --- | --- |
| `yjson` | Pure runtime、typed API、mutable AST 与 managed document |
| `yjson_macros` | 编译期 codec 生成 |
| `yjson_algorithms` | Pointer、Path、Patch 与 Schema 算法 |
| `yjson_backends` | 高级 backend API |
| `yjson_native_primitives` | 第一方 closed Native primitives SPI |
| `yjson_native_accel` | 默认 façade 的一次性加速初始化 |
| `yjson_native` | Custom Native 高级 backend |
| `yjson_yyjson` | vendored yyjson 高级 backend |
| `yjson_schema_formats` | 可选的国际化 Schema formats |

`yjson_all` 已删除。使用 generated codec 的应用显式声明 runtime 与 macros：

```toml
[dependencies]
yjson = { path = "../yjson" }
yjson_macros = { path = "../yjson/packages/yjson_macros" }
```

有序依赖图由 [`release/release-graph.toml`](release/release-graph.toml) 唯一定义。examples、
benchmarks、conformance package 和 consumer fixture 都是仓库测试资产，不进入发布包。

## 兼容规则

- `0.1.y` patch 保持已记录的 stable、advanced 和 experimental 应用 API 兼容。
- 后续 `0.x.0` minor 可以破坏 API，但必须提供 API diff、迁移指南和版本化行为变更。
- generated/native closed SPI 是第一方 lockstep 契约，不是应用扩展点；protocol 或 ABI 不匹配
  必须明确失败。

## API 与实现边界

- 普通应用只使用 `YJson`、`JsonCodec<T>`、`JsonNode` 和 GC 管理的 `JsonDocument`。普通入口
  不接受 backend 参数，也不暴露 `close()`。
- `JsonReadOptions` 和 `JsonWriteOptions` 直接承载有限资源预算；所有 JSON 失败统一为
  `JsonException`，调用方匹配稳定的 `code`。
- `@JsonCodec` 生成 provider-backed codec。`YJson.toJson(value)` 和
  `YJson.fromJson<T>(text)` 是 generated 类型的最短入口；custom codec 继续使用同一方法并传
  `codec:`。多态 subtype 的字段读写使用宏生成的 typed object bridge，不会解析到继承自
  open base 的 provider。普通 generated provider 直接返回 `JsonCodec<T>`，不经过 `Any`
  装箱、erase/reify adapter 或运行时类型转换。零状态 type token 区分继承链上的父/子
  provider，直接 concrete subtype codec 会组合 base 和 subtype 字段。
- JSONPath cursor 惰性产出匹配；`first()` 早停。Schema 在构造阶段冻结 resolver graph 并
  编译受限 regex，重复 validation 不再执行 resolver I/O 或重新编译表达式。
- process runtime 在首次调用或 Native 初始化时线性化；冻结后的普通 `YJson` 调用只读取
  atomic flag，不再获取 process-wide Mutex。
- Custom Native 与 yyjson document 的逐节点 view 操作继续通过读锁与 `close()` 线性化；
  root serialization 和 document materialization 自动使用单次读锁 bulk 路径。

完整迁移面见[公开 API 清单](docs/public-api-inventory.md)，API 选择见
[API 选择指南](docs/choosing-an-api.md)。

## 资格范围

Pure runtime 的本地正式验证平台是 Linux；Windows 与 macOS 使用 GitHub runner。`0.1.0`
Native qualification 仅覆盖 Linux x86_64。API reference 由固定版本的 cjdoc 为九个发布包生成。

本版本不会把开发机 quick run 或高波动测量写成性能倍数。任何公开性能结论必须绑定候选 SHA、
固定 SDK、等语义 workload、交替/反转轮次、checksum、RSS 和跨 profile 复验。

## 发布证据

manifest 版本号本身不能证明发布。只有 annotated tag、GitHub Release、九个 artifact、checksum、
SBOM、API diff、迁移指南、平台矩阵、API 文档和 digest-bound evidence 全部指向同一 clean commit
时，`0.1.0` 才算发布。若 evidence 没有记录 registry publish，本版本只能声明为 GitHub artifacts
可用。
