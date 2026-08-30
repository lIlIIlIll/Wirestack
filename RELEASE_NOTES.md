# Release notes: 0.1.0

`0.1.0` 开启 yjson 当前的实验版本线。版本号降低是有意的成熟度重置：仓库没有已知的 package
registry 用户，项目将在 `0.x` 阶段继续简化 API，再冻结未来的稳定 `1.0.0` 契约。

既有 `1.0.0-rc.1`、`2.0.0` tag、GitHub Release、带日期的性能报告和 evidence 保持不可变，
作为历史原型保留；它们不定义 `0.1.x` 的兼容性。[2.0.0 release evidence](release/2.0.0/evidence.md)
继续用于审计和性能基线。

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

## 发布证据

manifest 版本号本身不能证明发布。只有 annotated tag、GitHub Release、九个 artifact、checksum、
SBOM、API diff、迁移指南、平台矩阵、API 文档和 digest-bound evidence 全部指向同一 clean commit
时，`0.1.0` 才算发布。若 evidence 没有记录 registry publish，本版本只能声明为 GitHub artifacts
可用。
