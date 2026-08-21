# Contributing to yjson

感谢参与 yjson。提交前请先阅读 [文档导航](docs/README.md) 与
[当前架构](docs/architecture.md)，并保持 Pure Cangjie core、macro 和 optional Native
package 的边界。

## 开发环境

- Cangjie SDK 1.1；
- `cjc`、`cjpm` 在 `PATH`；
- 仅修改 Native package 时需要 C11 compiler 与 archiver。

## 验证

按修改范围运行最小充分验证：

```bash
cjpm test --no-color
scripts/run_cjpm_executable.sh packages/examples
scripts/run_cjpm_executable.sh packages/codec_integration
scripts/run_cjpm_executable.sh packages/json_literal_integration
```

Native、sanitizer、fuzz、release job 与 external consumer 命令见
[测试指南](docs/maintainers/testing.md)。不要用 benchmark 代替 correctness test。

## 变更要求

- public declaration 变化同步更新 `release/public-api-inventory.toml` 与当前 RC delta 文档；
- generated-code bridge 变化必须验证 matching macro consumer，并说明版本耦合；
- backend 变化保持 Pure Cangjie 语义基准、显式 opt-in 与 deterministic `close()`；
- 性能 claim 提交同环境 baseline/candidate raw evidence，并遵循
  [methodology](docs/performance/methodology.md)；
- 文档示例应来自当前 public API，并能由 example 或 external consumer 覆盖。

提交应保持单一意图，不包含 build output、ignored benchmark corpus、凭据或开发机绝对路径。
