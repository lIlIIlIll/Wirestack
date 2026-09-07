# 标准符合性测试

本包通过 yjson 公开 API 运行固定版本的 JSON Schema draft 2020-12、JSONPath CTS 和
JSON Patch 测试集。它用于发布前检查，应用无需依赖本包。

测试脚本固定上游版本、生成输入、核对用例数量，并将结果写入发布记录。
可选的 `yjson_schema_formats` 测试单独运行，防止它提供的格式校验掩盖核心包必需词汇的回归。

测试规则和当前基线见[测试指南](../../docs/maintainers/testing.md)。
