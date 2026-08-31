# yjson 文档

这套文档按任务组织。先完成一次 typed roundtrip，再根据数据模型、I/O、安全和部署需求进入
对应主题。API/type 名称保留英文，说明以中文为主。

## 第一次使用

1. 在应用的 `cjpm.toml` 中添加 `yjson` 与 `yjson_macros` path dependency。
2. 运行项目 README 中的 `@JsonCodec` 示例。
3. 按 [API 选择指南](choosing-an-api.md)选择 typed codec、`JsonNode`、只读
   `JsonDocument` 或 stream。
4. 接收不可信输入前，设置[资源限制](resource-limits.md)，并按稳定
   `JsonException.code` 处理失败。

仓库内可运行示例见 [`packages/examples`](../packages/examples/README.md)。文档与实现不一致
时，以 package manifest、公开声明和可运行测试为准。

## 推荐阅读路径

| 目标 | 阅读顺序 |
| --- | --- |
| 第一次接入 | [API 选择](choosing-an-api.md) → [`@JsonCodec`](codec-generation.md) → [配置与错误](configuration-and-errors.md) |
| 处理大型或分块输入 | [Stream I/O](streams.md) → [资源限制](resource-limits.md) |
| 使用只读文档或 Native | [AST 与只读 Document](ast-and-compact.md) → [Backend](backends.md) |
| 使用标准算法 | [Pointer、Path 与 Patch](path-and-patch.md) → [Schema](schema.md) |
| 维护和发布 | [仓库布局](maintainers/repository-layout.md) → [测试](maintainers/testing.md) → [发布](maintainers/releasing.md) |

## 常用任务

| 任务 | 文档 |
| --- | --- |
| 为 class、struct、enum 生成 codec | [`@JsonCodec` 生成指南](codec-generation.md) |
| 编写 custom codec | [自定义 Codec](custom-codecs.md) |
| 解析、修改或只读查询 JSON | [AST 与只读 Document](ast-and-compact.md) |
| 从 stream 读取或写出 value | [Stream I/O](streams.md) |
| 启用 Native primitive 或显式 backend | [Backend 使用指南](backends.md) |
| 设置读写策略并处理错误 | [配置与错误](configuration-and-errors.md) |
| 限制输入、输出和算法工作量 | [资源限制](resource-limits.md) |
| 校验 JSON Schema draft 2020-12 | [JSON Schema](schema.md) |
| 使用 Pointer、Path 或 Patch | [JSON Pointer、JSONPath 与 Patch](path-and-patch.md) |

## API reference

仓库用固定 cjdoc 版本为九个发布 package 生成 JSON Doc IR 和 HTML。首次准备工具时运行：

```terminal
cjdoc_path=$(scripts/codex_cangjie_env python3 scripts/prepare_cjdoc.py)
scripts/codex_cangjie_env python3 scripts/generate_api_docs.py \
  --cjdoc "$cjdoc_path" \
  --output /tmp/yjson-api-docs-0.1.0
```

`--output` 目标必须不存在。准备脚本校验 cjdoc source archive、commit、compiler、cjpm、
binary SHA-256 和 qualification evidence；生成脚本随后校验九包身份、Doc IR schema、error
diagnostic 和已知 unsupported 项。CI 把同一输出上传为 Pages artifact，合并到 `main` 后才执行
Pages deployment。

cjdoc 0.6.0 当前不能完整建模三个 public macro declaration，也会把两个 `@Derive` invocation
报告为 unsupported。允许项和精确数量记录在
[`release/cjdoc-policy.toml`](../release/cjdoc-policy.toml)；新增或缺失项都会使生成失败。
宏的精确签名仍以
[`release/public-api-snapshot.txt`](../release/public-api-snapshot.txt)为准。

## 选型与版本

- [库能力对比](library-comparison.md)：比较公开 contract，不把跨批次性能数据拼成排名。
- [性能文档](performance/README.md)：方法、原始结果和适用边界。
- [公开 API 清单](public-api-inventory.md)：九包当前声明与评审变化。
- [Release notes](../RELEASE_NOTES.md)和 [Changelog](../CHANGELOG.md)：用户可见变化。

历史 1.x/2.0 文档和性能证据只用于审计。它们不定义 `0.1.x` API，也不构成兼容承诺。

## 维护者入口

- [当前架构与 package graph](architecture.md)
- [Repository layout 与发布边界](maintainers/repository-layout.md)
- [测试层级、标准套件与 CI mapping](maintainers/testing.md)
- [Native backend 内部契约](maintainers/native-internals.md)
- [发布流程与证据规则](maintainers/releasing.md)
- [公开 API/ABI change inventory](public-api-inventory.md)

`release/` 保存候选清单和一次性证据；`docs/performance/results/` 保存带日期的测量结果；
`docs/archive/` 保存不再代表当前 contract 的计划。

