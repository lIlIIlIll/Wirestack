# 测试 yjson

稳定文档定义测试层和发布期望；某次运行的 commit、SDK、日志、case 数与 checksum 写入
对应 `release/<version>/evidence.md`。

## 测试层

| Layer | 验证内容 | 入口 |
| --- | --- | --- |
| Core | parser、writer、codec、AST、Compact、incremental stream、limits | `cjpm test` |
| External codec consumer | 调用方 macro、enum、多态、fast decoder | `packages/codec_integration` |
| Literal consumer | `@Json`、`@JsonValue`、插值顺序、LastWins | `packages/json_literal_integration` |
| Compile-fail | 无效 literal grammar、静态重复 key | `scripts/check_json_literal_compile_fail.sh` |
| Algorithms / Standards | 有限预算与固定 revision Schema/Path/Patch suites | `packages/yjson_algorithms` / `scripts/run_standards_conformance.py` |
| Optional packages | Native DOM、stream、lifecycle、limits | 各 package test/consumer |
| Native C | warnings、sanitizers、differential fuzz | `scripts/release_native_checks.sh` |
| Packaging | staging、manifest、license、symbols、isolated consumers | release scripts |
| Performance comparison | 同批次完整三库 workload | `scripts/release_performance_compare.sh` |
| Native acceleration | Pure/Native 单引擎广告与普通 workload | `scripts/json_native_accel_perf_run.py` |

Benchmark 不能替代 correctness test；root white-box pass 也不能替代 staged external consumer。

## CI job mapping

GitHub Actions 的 `CI` workflow 在 GitHub-hosted Linux x86_64 runner 上执行每日 correctness
门禁。`scripts/ci_job.sh` 提供 `api-inventory`、`runtime-freeze`、`core`、
`standards-conformance`、`schema-formats-conformance`、`examples`、`macro-consumer`、
`algorithms-consumer`、`registry-rehearsal`、`custom-native`、`yyjson-native`、`native-clang`、
`native-gcc`、`sanitizer`、`fuzz-short` 和 `yyjson-colink` 等 job。

workflow 在每个七天窗口首次运行时解析最新完整 Cangjie nightly，并缓存所选版本。Tests 与
Core Coverage 必须使用同一个版本；窗口内重跑不会切换 SDK。Server performance、50,000-case
扩展 fuzz 与 Windows cross build 仍属于发布资格验证，不进入日常 hosted CI。

若某个已确认的 nightly compiler 只在外部 dependency codegen 阶段崩溃，workflow 可以按完整
SDK 版本对受影响的 dependency-boundary job 设置较低优化级别。例外不得使用版本范围，Core
仍须以 `-O2` 通过；下一个七天窗口选择新 nightly 后会自动恢复 external `-O2`，让问题重新
进入门禁。发布 artifact 的 manifest 和本地 release qualification 不使用该 hosted workaround。

## Core coverage

运行 `scripts/coverage.sh`。脚本在临时 source tree 中以 `-O0` 编译，生成 cjcov HTML、JSON、
XML 与 `coverage/lcov.info`，并在结束时清理临时树。统计范围仅为 root package 的
`src/lib_*.cj`；测试源码、package 源码、build output 与 SDK/runtime 不计入。CI 将同一份
LCOV 以 `core` flag 上传到 Codecov，上传失败会阻断 workflow。

`coverage-baseline.toml` 保存首次完整测量建立的 line/branch 基线，项目允许最多 0.1 个百分点
回退。Pull request 新增或修改的 core 可执行行必须达到 90% line coverage；这些行上的 branch
必须达到 80%。首次引入 baseline 的 bootstrap release 只执行 project gate；baseline 合并到
目标分支后，后续 pull request 才执行 patch gate。

Native acceleration 目前是 release qualification runner，不是 `ci_job.sh` 的短任务。正式执行
固定 11 轮，详细门槛见[性能方法](../performance/methodology.md)。

本地 fresh-source、coverage 与 hosted CI 是三份独立证据。一个 PASS 不能自动填充另一个状态。
当前 release qualification 的阻断平台是 Linux x86_64；未执行的平台必须记录
`NOT RUN / NON-BLOCKING / potentially supported`。

## Feature × backend

| Public behavior | Pure | Custom Native | yyjson | External consumer |
| --- | ---: | ---: | ---: | ---: |
| Parser/serializer semantics | 主实现 | differential | differential | examples |
| Generated class/struct/enum | 主实现 | 同一 semantic SPI | advanced backend 不替换 generated path | codec consumer |
| Generated polymorphism | 主实现 | 同一 semantic SPI | advanced backend 不替换 generated path | codec consumer |
| JSON literals | 是 | n/a | n/a | literal consumer |
| Stream ownership/limits | 是 | 是 | 是 | package consumers |
| Mutable AST | 是 | materialize | materialize | examples |
| Managed Compact query/lifecycle | 是 | primitive 加速；无 `close()` | n/a | release consumers |
| Advanced DOM lifecycle | n/a | 显式 resource | 显式 resource | package consumers |
| Duplicate/number/resource policies | 是 | 是 | 是 | release consumers |
| Schema / Pointer / Patch / Path | 独立 algorithms package | 同一 managed value 语义 | n/a | standards consumer |

Differential 表示对照 portable semantic oracle，不代表 Native DOM API 与 `JsonNode` 相同。

## 单引擎专项证明

- Pure、Native primitive、generated、incremental stream 与高级 backend 复用同一组合法/非法
  semantic vectors，比较 value、UTF-8/escape/number 行为和稳定 error code/path/offset。
- incremental reader 对跨 chunk string、escape、number 与 structural token 做 byte split-point
  测试；一次性 `ByteBuffer` 输入不能替代这项证明。
- String、bytes、分块 stream 与 Native target 做 byte-for-byte writer 对比，并覆盖非法结构
  调用、cycle、`maxBytes` 与非有限浮点数。
- generated external consumer 检查 protocol v1、递归容器、custom codec 与 polymorphic replay，
  同时扫描生成源码，禁止出现具体 reader/writer class 名称。
- acceleration lifecycle 覆盖 Pure freeze、Native freeze、幂等重复、晚初始化、并发竞争、缺库、
  ABI/protocol 错误和 unsupported platform；初始化成功后的 provider 故障不得静默回退。

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
