# Changelog

本文件记录已发布版本和后续开发的用户可见变化。最新稳定版说明见
[RELEASE_NOTES.md](RELEASE_NOTES.md)。历史 `1.0.0-rc.1` 的迁移步骤和验收记录分别保存在
[pre-1.0 → 1.0](docs/migration/pre-1.0-to-1.0.md) 与
`release/1.0.0-rc.1/evidence.md`。后者是历史仓库路径，不进入 `0.1.0` source archive。

## [Unreleased]

- 当前成熟度版本线重置为 `0.1.0`；既有 1.x/2.0 tag 与 evidence 只作为不可变历史保留。
- 发布图固定为九个 lockstep package；删除 `yjson_all`，新增第一方 closed SPI
  `yjson_native_primitives`，并将依赖方向改为 `yjson_macros → yjson`。
- 全部同包测试改用 cjpm 的 `*_test.cj` 约定；release staging 复制 graph 声明的完整 source
  root，不再用 `lib_*`/`test_*` 文件名前缀决定产品源码。
- mutable `JsonNode` 的序列化、复制和等价比较现在检测祖先环，并允许共享 DAG 节点。
- direct writer 现在强制单一 root、统一 semantic/raw depth 预算，并在 stream sink 写出前检查
  `maxBytes`。
- Rune codec 只接受一个 Unicode scalar。legacy AST codec 对无法执行的非默认配置返回
  `unsupported_config`。
- JSONPath singularity 使用解析后的 selector 类型判定，不再根据表达式中的标点猜测。
- JSONPath cursor 改为惰性遍历，`first()` 在首个匹配后停止；Schema resolver graph 和 regex
  在构造阶段冻结，重复 validation 不再解析相同 schema。
- generated polymorphic codec 通过 concrete subtype 的 typed object provider 读写字段，不再
  复用从 open base 继承的 provider。
- generated codec lookup 改为全类型化
  `GeneratedCodecProviderV1<T> -> JsonCodec<T>`；删除 `GeneratedAnyCodecV1`、erase/reify
  adapter 和运行时类型转换。零状态 `GeneratedCodecTokenV1<T>` 支持父/子 provider 重载，
  concrete subtype codec 以类型化方式组合继承字段。
- 冻结后的普通 `YJson` 调用使用 atomic fast path，避免每次 encode/decode 获取全局 Mutex。
- Custom Native 与 yyjson 的 root serialization 和 document materialization 使用单次读锁
  bulk tape 路径；任意 retained 子 view 继续逐操作与 `close()` 线性化。
- formal performance runner 记录源码、工具链、语料与最终 binary 身份，并要求 clean、隔离的
  baseline 与 candidate rebuild。

## [2.0.0] - 2026-08-27

- 2.0 默认产品面收敛为单一 semantic engine；普通应用只使用 `YJson`，默认
  `JsonDocument` 为 GC 管理的只读 Compact representation，不再暴露 backend、资源生命周期
  或 `close()`。
- 新增真正增量的 `InputCursor`/`StreamInputCursor` 与共享 grammar；String、bytes 和 stream
  writer target 统一由一个结构状态机驱动。
- generated codec 改用版本化 generated-support v1 窄 SPI；宏生成源码不依赖具体
  reader/writer class，protocol 不变时允许跨 patch 版本。
- 新增 `yjson_native_accel`，应用只在首次 `YJson` 调用前执行一次
  `YJsonNativeAccel.initialize()`；进程冻结后不支持卸载、切换或故障静默回退。
- 将 resource-owning DOM/WholeDocument stream 移到 `yjson_backends` 高级 API，将 Schema、
  Pointer、Patch、Merge Patch 与 JSONPath 移到 `yjson_algorithms`；不提供 1.x 兼容 shim。
- 算法默认启用 visited/evaluation/match/copy/depth 等有限预算，耗尽统一抛出
  `JsonWorkLimitException(code: "work_limit_exceeded")`；Schema URI 只由注入的
  `UriResolver` 解析。
- release performance gate 固定输出 yjson、stdx.json、cjfast_json 的完整共同 workload 表；
  高 CV 行保留并标记为 noisy，不再被稳定性筛选隐藏。
- 新增 JSON Pointer（RFC 6901）、JSON Patch（RFC 6902）、JSON Merge Patch（RFC 7396）
  与 JSONPath（RFC 9535）API；Patch 的 copy 和 in-place 入口均为原子操作。
- JSON Schema 固定为 draft 2020-12，扩展 validation/applicator keyword，新增无网络
  `UriResolver` / `JsonSchemaRegistry`、format registry/provider，以及
  `Annotation` / `Assertion` / `StrictAssertion` 三种模式。
- 新增可选 `yjson_schema_formats` package，通过 libidn2 提供 IDNA2008/Punycode/Bidi/ContextJ，
  并提供 URI、IRI 与 RFC 6570 URI Template assertions；适用 optional suite 为 964/964。
- 新增固定 revision 的官方 standards conformance gate；JSON Schema required suite、
  JSONPath CTS 与 JSON Patch tests 当前分别为 1299/1299、703/703、108/108。
- 高级 `JsonStreamBackend` 仅保留显式 optional Custom Native / yyjson WholeDocument 实现；
  默认 `YJson.toStream/fromStream` 固定使用统一 incremental engine。
- typed codec contract 改为 backend-neutral `JsonCodecReader` / `JsonCodecWriter`；
  `JsonDirectCodec<T>` 直接更名为 `JsonCodec<T>`，不保留兼容 alias。
- `JsonWriteConfig` 新增 `maxBytes`，`0` 表示 unlimited，超限错误码为
  `output_too_large`。
- generated polymorphic decode 改为 capture/replay，不再 serialize/reparse。

## [1.0.0-rc.1] - 2026-08-22

- 首个 1.0 release candidate：compile-time generated codec、JSON literal、`JsonNode`、显式资源预算、
  Pure Compact DOM 与显式 opt-in Native packages。
