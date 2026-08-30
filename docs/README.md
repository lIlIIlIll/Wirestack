# yjson 文档

这套文档按任务组织：先让应用成功完成一次 typed roundtrip，再根据数据模型、I/O、
安全和部署需求进入对应主题。API/type 名称保持英文，说明以中文为主。

## 第一次使用

1. 在应用的 `cjpm.toml` 中添加 `yjson` 与 `yjson_macros` path dependency。
2. 复制项目 README 中的 `@JsonCodec` 示例，确认 `YJson.toJson` 与
   `YJson.fromJson<T>` 完成 roundtrip。
3. 根据 [API 选择指南](choosing-an-api.md)判断后续使用 typed codec、AST、Compact DOM
   还是 Stream。
4. 在接收不可信输入前，配置[资源限制](resource-limits.md)并按稳定 `error.code` 处理失败。

仓库内可运行示例见 [`packages/examples`](../packages/examples/README.md)。如果示例与文档
冲突，以 package manifest、公开声明和可运行测试为准。

## 推荐阅读路径

| 你的目标 | 阅读顺序 |
| --- | --- |
| 第一次接入 | [API 选择](choosing-an-api.md) → [`@JsonCodec`](codec-generation.md) → [配置与错误](configuration-and-errors.md) |
| 处理大型或分块输入 | [Stream I/O](streams.md) → [资源限制](resource-limits.md) → [Stream 性能](performance/stream.md) |
| 启用可选能力 | [Backend](backends.md) 或 [Schema](schema.md) → 对应 package 示例 |
| 维护和发布 | [仓库布局](maintainers/repository-layout.md) → [测试](maintainers/testing.md) → [发布](maintainers/releasing.md) |

## 常用任务

| 任务 | 入口文档 |
| --- | --- |
| 为 class、struct、enum 生成 codec | [`@JsonCodec` 生成指南](codec-generation.md) |
| 编写 custom codec | [自定义 Codec](custom-codecs.md) |
| 使用 `@Json` / `@JsonValue` | [JSON 字面量](json-literals.md) |
| 解析、修改或只读查询 JSON | [AST 与 Compact DOM](ast-and-compact.md) |
| 从 stream 读取或写出 typed value | [Stream I/O](streams.md) |
| 查看 incremental stream 性能边界 | [Stream 性能](performance/stream.md) |
| 启用 Native 加速或显式高级 backend | [Backend 使用指南](backends.md) |
| 设置读取/写出策略并处理错误 | [配置与错误](configuration-and-errors.md) |
| 限制深度、文档和字符串大小 | [资源限制](resource-limits.md) |
| 校验 JSON Schema draft 2020-12 | [JSON Schema](schema.md) |
| 使用 Pointer、Path 或 Patch | [标准路径与 Patch](path-and-patch.md) |

## 选型与迁移

- [库能力对比](library-comparison.md)：比较公开 contract；不把跨批次性能数据拼成排名。
- [历史 1.x → 2.0 迁移记录](migration/1.x-to-2.0.md)：旧版本的单引擎、启动冻结、limits
  与算法包拆分；不代表当前 `0.1.x` 兼容承诺。
- [pre-1.0 → 1.0 迁移](migration/pre-1.0-to-1.0.md)：类型改名、配置变化、codec 和
  package 配套要求。
- [性能文档](performance/README.md)：当前可引用结论、方法、原始结果入口与适用边界。
- [Release notes](../RELEASE_NOTES.md)和 [Changelog](../CHANGELOG.md)：用户可见变化。

## 维护者入口

- [当前架构与 package graph](architecture.md)
- [Repository layout 与发布边界](maintainers/repository-layout.md)
- [测试层级、标准套件与 CI mapping](maintainers/testing.md)
- [Native backend 内部契约](maintainers/native-internals.md)
- [发布流程与证据规则](maintainers/releasing.md)
- [公开 API/ABI change inventory](public-api-inventory.md)

`release/` 保存一次性候选证据；`docs/performance/results/` 保存带日期的测量结果；
`docs/archive/` 保存不再代表当前 contract 的历史计划。它们不能替代上面的稳定用户指南。

当前仍没有逐符号 API reference。需要精确签名时，请查看 `src/lib_*.cj` 的 public
声明与 `release/public-api-snapshot.txt`；需要下游采用示例时，优先查看独立 consumer
package，而不是根 package 的 white-box tests。
