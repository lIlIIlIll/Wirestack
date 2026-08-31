# Contributing to yjson

开始修改前阅读[文档导航](docs/README.md)、[架构](docs/architecture.md)和
[仓库布局](docs/maintainers/repository-layout.md)。

## 选择最小范围

- Pure runtime 修改留在 `src/lib_*.cj`，不要无意引入 Native 依赖。
- macro 变化同时检查调用方展开代码与 matching runtime bridge。
- algorithms 通过 `JsonValueView` 工作，不按 backend storage 分叉。
- optional backend 保持命名 façade、显式 resource lifetime 和统一 options/error 语义。
- 文档只描述当前 public API、manifest、测试或可审计 evidence。

不要提交 target、cache、临时 benchmark corpus、凭据、开发机绝对路径或无关格式化。测试文件
统一使用 `*_test.cj` 后缀。

## 验证

按变更面选择 core、external consumer、standards、Native、packaging、docs、coverage 或性能
gate。完整矩阵见[测试指南](docs/maintainers/testing.md)。成功退出不总等于应用成功；检查输出
中是否存在未处理异常。

只修改文档、API inventory 或发布 staging 时，至少运行：

```terminal
python3 scripts/check_api_inventory.py
python3 scripts/test_stage_source_tree.py
python3 scripts/test_release_temp_tree.py
```

修改 API docs pipeline 时还要运行 cjdoc qualification/generator 单元测试和真实九包生成。修改
runtime 或 codec 时运行 `cjpm test --no-color`，并按受影响 package 增加 external consumer。
修改 Markdown 链接时，把全部改动文件传给 `scripts/check_local_markdown_links.py`。

## Public API、文档与性能

- public declaration、C ABI 或 package pairing 变化必须同步 machine-readable inventory。
- generated bridge 变化必须由独立 consumer 证明。
- 用户文档的 API 示例要以当前声明或可运行 probe 验证。
- 性能 claim 必须提供等语义、同环境、固定 CPU、交替/反转 A/B、checksum、RSS 和跨 profile
  证据，并遵循[性能方法](docs/performance/methodology.md)。
- benchmark improvement 不能替代 correctness、coverage 或 compatibility test。

## 提交质量

一个提交保持一个可解释意图，测试与行为修改放在一起。文档、generated artifact 或机械整理
只有在各自能独立解释时才拆分。提交前复查最终 diff，确保没有包含其他人的并行修改。

