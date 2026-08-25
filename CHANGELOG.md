# Changelog

本文件记录已发布版本的用户可见变化。`1.0.0-rc.1` release notes 见
[RELEASE_NOTES.md](RELEASE_NOTES.md)，预发布快照迁移步骤见
[pre-1.0 → 1.0](docs/migration/pre-1.0-to-1.0.md)，验证记录见
[release evidence](release/1.0.0-rc.1/evidence.md)。

## [Unreleased]

- release performance gate 固定输出 yjson、stdx.json、cjfast_json 的完整共同 workload 表；
  高 CV 行保留并标记为 noisy，不再被稳定性筛选隐藏。
- 新增 JSON Pointer（RFC 6901）、JSON Patch（RFC 6902）、JSON Merge Patch（RFC 7386）
  与 JSONPath（RFC 9535）API；Patch 的 copy 和 in-place 入口均为原子操作。
- JSON Schema 固定为 draft 2020-12，扩展 validation/applicator keyword，新增无网络
  `JsonSchemaResolver` / `JsonSchemaRegistry`、format registry/provider，以及
  `Annotation` / `Assertion` / `StrictAssertion` 三种模式。
- 新增可选 `yjson_schema_formats` package，通过 libidn2 提供 IDNA2008/Punycode/Bidi/ContextJ，
  并提供 URI、IRI 与 RFC 6570 URI Template assertions；适用 optional suite 为 964/964。
- 新增固定 revision 的官方 standards conformance gate；JSON Schema required suite、
  JSONPath CTS 与 JSON Patch tests 当前分别为 1299/1299、703/703、108/108。
- 新增可显式选择的 `JsonStreamBackend`：Pure incremental 默认实现，以及 optional
  Custom Native / yyjson Direct whole-document 双向实现。
- typed codec contract 改为 backend-neutral `JsonCodecReader` / `JsonCodecWriter`；
  `JsonDirectCodec<T>` 直接更名为 `JsonCodec<T>`，不保留兼容 alias。
- `JsonWriteConfig` 新增 `maxBytes`，`0` 表示 unlimited，超限错误码为
  `output_too_large`。
- generated polymorphic decode 改为 capture/replay，不再 serialize/reparse。

## [1.0.0-rc.1] - 2026-08-22

- 首个 1.0 release candidate：compile-time generated codec、JSON literal、`JsonNode`、显式资源预算、
  Pure Compact DOM 与显式 opt-in Native packages。
