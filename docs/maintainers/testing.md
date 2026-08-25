# 测试 yjson

稳定文档定义测试层和发布期望；某次运行的 commit、SDK、日志、case 数与 checksum 写入
对应 `release/<version>/evidence.md`。

## 测试层

| Layer | 验证内容 | 入口 |
| --- | --- | --- |
| Core | parser、writer、codec、AST、Compact、stream、Schema、limits | `cjpm test` |
| External codec consumer | 调用方 macro、enum、多态、fast decoder | `packages/codec_integration` |
| Literal consumer | `@Json`、`@JsonValue`、插值顺序、LastWins | `packages/json_literal_integration` |
| Compile-fail | 无效 literal grammar、静态重复 key | `scripts/check_json_literal_compile_fail.sh` |
| Standards | 固定 revision Schema/Path/Patch suites | `scripts/run_standards_conformance.py` |
| Optional packages | Native DOM、stream、lifecycle、limits | 各 package test/consumer |
| Native C | warnings、sanitizers、differential fuzz | `scripts/release_native_checks.sh` |
| Packaging | staging、manifest、license、symbols、isolated consumers | release scripts |
| Performance | 同批次完整三库 workload | `scripts/release_performance_compare.sh` |

Benchmark 不能替代 correctness test；root white-box pass 也不能替代 staged external consumer。

## CI job mapping

`scripts/ci_job.sh` 提供 `api-inventory`、`core`、`standards-conformance`、
`schema-formats-conformance`、`performance-comparison`、`examples`、`macro-consumer`、
`custom-native`、`yyjson-native`、`native-clang`、`native-gcc`、`sanitizer`、`fuzz-short`、
`fuzz-extended` 和 `yyjson-colink` 等 job。

本地 fresh-source 与 hosted CI 是两份独立证据。一个 PASS 不能自动填充另一个状态。
当前 release qualification 的阻断平台是 Linux x86_64；未执行的平台必须记录
`NOT RUN / NON-BLOCKING / potentially supported`。

## Feature × backend

| Public behavior | Pure | Custom Native | yyjson | External consumer |
| --- | ---: | ---: | ---: | ---: |
| Parser/serializer semantics | 主实现 | differential | differential | examples |
| Generated class/struct/enum | 是 | n/a | n/a | codec consumer |
| Generated polymorphism | 是 | n/a | n/a | codec consumer |
| JSON literals | 是 | n/a | n/a | literal consumer |
| Stream ownership/limits | 是 | 是 | 是 | package consumers |
| Mutable AST | 是 | materialize | materialize | examples |
| Compact query/lifecycle | 是 | 是 | 是 | release consumers |
| Duplicate/number/resource policies | 是 | 是 | 是 | release consumers |
| Schema / Pointer / Patch / Path | 是 | n/a | n/a | standards consumer |

Differential 表示对照 portable semantic oracle，不代表 Native DOM API 与 `JsonNode` 相同。

## 测试政策

- 一个 case 只写一个确定预期；“接受或拒绝均可”不是 contract。
- 优先验证 public result、error code、lifecycle、package boundary 和 compatibility。
- 只有 public API 无法安全暴露 regression 时才使用 white-box test。
- 外部 corpus 固定 revision 和预期 cardinality，不依赖浮动 upstream checkout。
- executable 必须传播应用异常；shell exit 0 但输出含未处理异常仍是失败。
- 性能只提供性能证据，不证明语义正确。

固定 standards baseline 当前为 Schema required 1299、JSONPath CTS 703、JSON Patch 108；
optional format provider 增加 964 个适用 cases。具体 PASS 结果属于 release evidence。

早期 parser gap 计划保存在
[`docs/archive/initial-parser-test-plan.md`](../archive/initial-parser-test-plan.md)，不代表当前 gate。
