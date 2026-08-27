# Contributing to yjson

感谢参与 yjson。开始修改前先阅读[文档导航](docs/README.md)、
[架构](docs/architecture.md)与[仓库布局](docs/maintainers/repository-layout.md)。

## 选择最小范围

- Pure runtime 修改留在 `src/lib_*.cj`，不要无意引入 Native 依赖。
- macro 变化同时考虑调用方展开代码与 matching runtime bridge。
- optional backend 变化保持显式 opt-in、确定性 `close()` 和 Pure 语义基准。
- 文档只描述当前 public API、manifest、测试或可审计 evidence。

不要提交 target、临时 benchmark corpus、凭据、开发机绝对路径或无关格式化。

## 验证

按变更面选择 core、external consumer、compile-fail、standards、Native、packaging 或性能 gate。
完整矩阵见[测试指南](docs/maintainers/testing.md)。成功退出不总等于应用成功；检查输出中
是否存在未处理异常。

## Public API 与性能

- public declaration、C ABI 或 package pairing 变化必须同步 machine-readable inventory
  和评审说明。
- generated-code bridge 变化必须由独立 consumer 证明。
- 性能 claim 必须提供等语义、同环境、配对且顺序反转的原始 evidence，并遵循
  [性能方法](docs/performance/methodology.md)。
- benchmark improvement 不能替代 correctness/compatibility test。

## 提交质量

一个提交保持一个可解释意图，测试与其行为修改放在一起。文档、generated artifact 或纯
机械整理只有在各自能独立解释时才拆分。提交前复查最终 diff，确保没有包含其他人的并行
修改。
