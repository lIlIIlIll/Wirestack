# yjson 文档

第一次使用 yjson，从项目 [README 的快速开始](../README.md#快速开始)运行一个
`@JsonCodec` 示例。已有项目需要接入时，先看 [API 选择指南](choosing-an-api.md)。

接收外部输入前，请检查[资源限制](resource-limits.md)，并按 `JsonException.code`
处理 JSON 错误。完整示例见 [`packages/examples`](../packages/examples/README.md)。

## 常用任务

| 任务 | 文档 |
| --- | --- |
| 为 class、struct、enum 生成 codec | [`@JsonCodec` 生成指南](codec-generation.md) |
| 编写自定义编解码器 | [自定义 Codec](custom-codecs.md) |
| 解析、修改或只读查询 JSON | [AST 与只读 Document](ast-and-compact.md) |
| 通过流读写 JSON | [Stream I/O](streams.md) |
| 启用原生加速或使用可选后端 | [Backend 使用指南](backends.md) |
| 设置读写策略并处理错误 | [配置与错误](configuration-and-errors.md) |
| 限制输入、输出和算法工作量 | [资源限制](resource-limits.md) |
| 校验 JSON Schema draft 2020-12 | [JSON Schema](schema.md) |
| 使用 Pointer、Path 或 Patch | [JSON Pointer、JSONPath 与 Patch](path-and-patch.md) |

## API 参考

API 参考由 cjdoc 从九个发布包的源码生成。运行下面的命令准备工具，并生成 JSON Doc IR 和 HTML：

```terminal
cjdoc_path=$(scripts/codex_cangjie_env python3 scripts/prepare_cjdoc.py)
scripts/codex_cangjie_env python3 scripts/generate_api_docs.py \
  --cjdoc "$cjdoc_path" \
  --output /tmp/yjson-api-docs-0.1.0
```

`--output` 指定的目录必须不存在。脚本会校验工具来源、版本和校验和，再检查生成结果中的
包信息、Doc IR 格式、错误和不支持的声明。CI 上传生成的页面，合并到 `main` 后发布到 GitHub Pages。

当前固定使用 cjdoc 0.7.2。三个公开宏声明和两个 `@Derive` 调用在生成结果中标记为不支持。
允许出现的条目和数量记录在
[`release/cjdoc-policy.toml`](../release/cjdoc-policy.toml)；新增或缺失项都会使生成失败。
宏的精确签名仍以
[`release/public-api-snapshot.txt`](../release/public-api-snapshot.txt)为准。

## 选型与版本

- [库能力对比](library-comparison.md)：比较接口能力和使用限制。
- [性能文档](performance/README.md)：方法、原始结果和适用边界。
- [公开 API 清单](public-api-inventory.md)：九包当前声明与评审变化。
- [Release notes](../RELEASE_NOTES.md)和 [Changelog](../CHANGELOG.md)：用户可见变化。

历史 1.x、2.0 文档和测量记录保留备查；使用 `0.1.x` 时请以当前 API 文档为准。

## 维护者入口

- [架构与包依赖](architecture.md)
- [仓库布局与发布文件](maintainers/repository-layout.md)
- [测试、标准套件与 CI](maintainers/testing.md)
- [Native 后端实现](maintainers/native-internals.md)
- [发布流程](maintainers/releasing.md)
- [公开 API 与 ABI 变化清单](public-api-inventory.md)

`release/` 保存候选清单和一次性证据；`docs/performance/results/` 保存带日期的测量结果；
`docs/archive/` 保存已经归档的计划。

