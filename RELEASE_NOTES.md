# Release notes: 2.0.0

yjson 2.0.0 于 2026-08-27 作为稳定版发布。该版本是相对 1.x 的 breaking release，统一了
默认 JSON 引擎，并将高级算法和 Native 能力拆分为显式 package。发布内容见
[GitHub Release](https://github.com/lIlIIlIll/yjson/releases/tag/2.0.0)，验收结果见
[release evidence](release/2.0.0/evidence.md)。

## 默认 API 与 package 边界

- `YJson` 使用 Pure Cangjie semantic engine。普通 API 不接受 backend 参数，也不要求
  `close()`。
- `JsonDocument` 是 GC 管理的只读 Compact representation。resource-owning DOM 和
  WholeDocument stream 位于 `yjson_backends`。
- `yjson_algorithms` 提供 JSON Pointer、JSON Patch、JSON Merge Patch、JSONPath 和
  JSON Schema。
- `yjson_native_accel` 是显式 opt-in package。应用只能在首次 `YJson` 调用前执行一次
  `YJsonNativeAccel.initialize()`。进程冻结后不能卸载或切换 provider。

`yjson_all` 聚合 core 与 macro，但不会自动启用 Native backend。所有 yjson package 必须来自
同一个 release，并一起重新编译。

## Stream、codec 与资源限制

- String、bytes 和 stream 输入共享增量 grammar。writer target 共享一个结构状态机。
- generated codec 使用版本化 `generated_support.v1` SPI。`JsonDirectCodec<T>` 更名为
  `JsonCodec<T>`，不提供 1.x alias。
- `JsonWriteConfig.maxBytes` 限制输出大小。算法 API 默认限制 visited、evaluation、match、
  copy 和 depth 工作量。
- generated polymorphic decode 使用 capture/replay，不再 serialize/reparse。

## 标准与可选能力

2.0.0 增加以下标准 API：

- JSON Pointer（RFC 6901）。
- JSON Patch（RFC 6902）。
- JSON Merge Patch（RFC 7396）。
- JSONPath（RFC 9535）。
- JSON Schema draft 2020-12。

可选 `yjson_schema_formats` package 通过 libidn2 提供 IDNA2008、Punycode、Bidi、ContextJ、
URI、IRI 和 RFC 6570 URI Template assertions。

## 发布与平台状态

2.0.0 已发布 Git tag 和 GitHub Release。仓库的 release evidence 不声明 registry publish。
Linux x86_64 是该版本的 qualified 平台。Windows x86_64 只完成 Pure cross build。macOS
和 ARM64 未验证。

完整测试、coverage、standards、Native、sanitizer、fuzz、package rehearsal 和性能结果均绑定
到 [`release/2.0.0`](release/2.0.0/evidence.md) 中记录的候选源码。后续开发变更见
[Changelog](CHANGELOG.md) 的 Unreleased 部分。

## 从 1.x 升级

2.0 不提供 1.x compatibility shim。请一次升级所有 package，并按
[1.x → 2.0 migration guide](docs/migration/1.x-to-2.0.md) 更新 API、初始化流程和资源限制。
