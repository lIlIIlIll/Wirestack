# Standards conformance consumer

该 executable 通过 yjson public API 适配固定 revision 的 JSON Schema draft 2020-12、
JSONPath CTS 与 JSON Patch suites。它是 release gate，不是普通应用依赖。

Runner 负责固定 upstream revision、生成输入、检查预期 cardinality，并把实际结果写入
release evidence。optional `yjson_schema_formats` 测试与默认 core gate 分开，避免 Native
format provider 掩盖 core required vocabulary 回归。

稳定测试政策和当前 baseline 见[测试指南](../../docs/maintainers/testing.md)。
