# Changelog

本文件记录已发布版本的用户可见变化。`1.0.0-rc.1` release notes 见
[RELEASE_NOTES.md](RELEASE_NOTES.md)，预发布快照迁移步骤见
[pre-1.0 → 1.0](docs/migration/pre-1.0-to-1.0.md)，验证记录见
[release evidence](release/1.0.0-rc.1/evidence.md)。

## [Unreleased]

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
