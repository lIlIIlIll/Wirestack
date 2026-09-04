# 测试 yjson

稳定文档定义测试层和发布期望。某次运行的 commit、SDK、runner、日志、case 数和 checksum 写入
对应 `release/<version>/evidence.md`，不能回填到通用说明。

## 测试层

| Layer | 验证内容 | 入口 |
| --- | --- | --- |
| Core | parser、writer、codec、AST、managed document、incremental stream、预算 | `cjpm test` |
| External codec consumer | 调用方 macro、enum、多态、显式 codec | `packages/codec_integration` |
| Algorithms / standards | Pointer、Patch、Path、Schema、固定 corpus | `packages/yjson_algorithms` / standards runner |
| Optional formats | libidn2 provider 和 optional Schema corpus | `packages/yjson_schema_formats` |
| Backend | named façade、view、close/read concurrency、whole-document I/O | Native/yyjson package tests |
| Acceleration | Pure/Native freeze、ABI、并发、故障和性能资格 | runtime-freeze / release perf runner |
| Native C | warnings、ASan、UBSan、LSan、differential fuzz、symbol isolation | release native scripts |
| Packaging | source-only stage、九包 graph、isolated consumers、license | release scripts |
| API docs | cjdoc source qualification、九包 Doc IR/HTML、known-gap policy | `api-docs` |
| Coverage | project 和 patch line/branch | `scripts/coverage.sh` + patch checker |
| Performance | 固定 CPU 的交替/反转 A/B、checksum、RSS、跨 profile | release performance scripts |

benchmark 不能替代 correctness test；root white-box pass 也不能替代 staged external consumer。

## 快速结构检查

不依赖 Cangjie 编译的检查包括：

```terminal
python3 scripts/check_api_inventory.py
python3 scripts/test_stage_source_tree.py
python3 scripts/test_release_temp_tree.py
python3 scripts/test_check_cjdoc_qualification.py
python3 scripts/test_generate_api_docs.py
```

这些命令验证 API snapshot、source-only staging、release manifest closure 和 cjdoc policy，但
不能替代 core、consumer、standards 或 Native 测试。

## 工具链选择

Hosted CI 每七天解析一次最新的完整 dated nightly，并缓存这个精确版本。所有需要 Cangjie 的
job 使用同一解析结果。`workflow_dispatch` 可以显式指定一个完整 nightly，以便重跑一个候选。
cjdoc 从固定 source revision 构建，但编译时使用同一个 weekly SDK；qualification evidence
记录实际 `cjc` 和 `cjpm` 输出，并拒绝与 shared weekly version 不一致的编译器。

checkout、setup、Codecov 和 Pages actions 使用完整 commit SHA。发布 evidence 还要记录 SDK
archive checksum、runner image、workflow run id 和 artifact checksum。

## CI job mapping

GitHub Actions `CI` workflow 在 `main` / `dev` push、目标为 `main` 的 pull request、
schedule 和手工触发时运行。

Linux x86_64 的 `tests` matrix 包含：

- `api-inventory`、`cjdoc-qualification`、`runtime-freeze`、`core`；
- `standards-conformance`、`schema-formats-conformance`；
- `examples`、`macro-consumer`、`algorithms-consumer`、`registry-rehearsal`；
- `custom-native`、`yyjson-native`、Clang/GCC、sanitizer、short fuzz、yyjson co-link。

`pure-platforms` 在 Windows Server 2022 和 macOS 14 上运行 core 与 algorithms 的 Pure gate。
它们不构建 Native package。`api-docs` 生成 Pages artifact；只有 `main` push 执行部署。
`coverage`、七库 evidence drift 和 stream evidence drift 是独立 job。

`generated-change-risk` 是独立的源码变更门禁。pull request 或 push 修改
`packages/yjson_macros/`、`generated_support.v1` 或 direct reader/writer/codec 时，同一变更集
必须增加 `packages/codec_integration/src/*_test.cj` 外部运行时测试。`macro-consumer` 随后同时
执行该 package 的 `cjpm test` 和 executable smoke check。宏源码不纳入 core 行覆盖率分母；
生成代码能否编译、运行和 round-trip 由外部消费者行为测试证明。

本地 Linux fresh candidate 使用：

```terminal
scripts/ci_fresh_checkout.sh
```

本地结果不能代表 Windows/macOS hosted result。hosted workflow 未执行时，平台状态必须写
`NOT RUN`，不能从源码可移植性推断 PASS。

## Coverage

`scripts/coverage.sh` 在临时 source tree 中以 `-O0` 编译，合并 root tests、runtime freeze
和 Native acceleration 场景，生成 HTML、JSON、XML 与 `coverage/lcov.info`。门禁只统计
`src/lib_*.cj` 产品源码。

[`coverage-baseline.toml`](../../coverage-baseline.toml) 固定：

| Gate | Line | Branch |
| --- | ---: | ---: |
| Project | 80% | 70% |
| Patch | 90% | 80% |

project gate 每次阻断。PR 只有在 base 已包含 baseline 时执行 patch gate；bootstrap 不能跳过
project gate。LCOV 以 `core` flag 上传 Codecov，上传失败阻断 workflow。

### Codecov flags

`codecov.yml` 为五组源码定义独立 flag，每组都有 project gate（auto target，0.1% threshold）
与 patch gate（90% line）：

| Flag | 路径 | 说明 |
| --- | --- | --- |
| `core` | `src/lib_*.cj` | 既有 root 产品源码，行为不变 |
| `algorithms` | `packages/yjson_algorithms/src/` | Pointer/Patch/Path/Schema |
| `native` | `packages/yjson_native{,_primitives,_accel}/src/` | scanner/provider closed SPI 与 facade |
| `yyjson` | `packages/yjson_yyjson/src/` | yyjson Compact backend |
| `schema-formats` | `packages/yjson_schema_formats/src/` | 可选国际化 format provider |

每个 flag 的 lcov 文件由覆盖收集器按包生成（`coverage/lcov.<flag>.info`），CI 上传步骤在
文件不存在时跳过，避免未收集阶段误报失败。宏源码（`packages/yjson_macros/`）继续排除在
所有 flag 之外：declaration macro 的展开产物由外部 consumer 行为测试证明
（`packages/codec_integration`），编译期代码无法用行覆盖率有意义地衡量。

## Feature × execution path

| Public behavior | Pure | Native acceleration | Named Native/yyjson façade | External proof |
| --- | ---: | ---: | ---: | ---: |
| Generated class/struct/enum | 主实现 | 同一 codec/semantic engine | 同一 `JsonCodec<T>` contract | codec consumer |
| String/bytes/stream | 主实现 | primitive replacement | whole-document buffering | consumer/package tests |
| Mutable `JsonNode` | 是 | 不改变 | materialize 后 | core/examples |
| Managed `JsonDocument` | 是 | 临时 Native resource 已释放 | n/a | core/runtime-freeze |
| `BackendJsonDocument` lifecycle | n/a | n/a | 显式 resource | close/read race tests |
| Options/error semantics | 主实现 | 相同 | 相同 | differential vectors |
| Pointer/Patch/Path/Schema | `JsonValueView` | 相同 view | 相同 view | algorithms/standards |
| API reference | 九包 cjdoc | closed SPI 标记 | advanced package pages | api-docs gate |

## 专项证明

- String、bytes、分块 stream 和 backend tape 复用合法/非法 semantic vectors，比较 value、
  UTF-8、escape、number、error code、path 和 location。
- stream reader 覆盖跨 chunk string、escape、number 和 structural token；一次性 byte input
  不能替代这项证明。
- writer 对比 String、bytes、stream 和 view，并覆盖非法状态、cycle、depth、output budget 和
  非有限浮点。
- generated external consumer 检查 protocol v1、递归容器、custom codec、enum 和多态 replay。
  collection 字段矩阵覆盖顶层与字段、空与非空、compact 与 pretty，以及 Array、ArrayList、
  HashMap 的嵌套组合。
- acceleration lifecycle 覆盖 Pure freeze、Native freeze、幂等、晚初始化、并发竞争、缺库、
  ABI/protocol 错误和 reentrant use；故障不得静默 fallback。
- backend document 覆盖打开期并发读、与 close 的线性化竞争和关闭后的 root view。
- Schema 证明 resolver 只在构造时调用，format registry 和 regex 在 compiled schema 中冻结。
- JSONPath 证明 cursor 创建不遍历，预算在 `next()` 时消耗，`first()` 提前停止。

## 测试政策

- 一个 case 只有一个确定预期；“接受或拒绝均可”不是 contract。
- 优先验证 public result、error code、lifecycle、package boundary 和 compatibility。
- 外部 corpus 固定 revision 与预期 cardinality，不依赖浮动 checkout。
- executable 必须传播应用异常；shell exit 0 但输出含未处理异常仍是失败。
- 性能只提供性能证据，不证明语义正确。

standards runner 的预期 cardinality 为 Schema required 1299、JSONPath CTS 703、JSON Patch
108；optional format provider 增加 964 个适用 cases。某次 PASS 只属于绑定身份的 release
evidence。

CI 对 standards/schema-formats job 先执行一次 `--prefetch`（下载并 SHA-256 校验固定
revision 的官方 suite archive），结果作为 cache artifact 复用；运行 gate 时显式传
`--offline`（`YJSON_STANDARDS_OFFLINE=1`），只使用缓存，miss 即失败并打印预取命令。
本地开发者无网络时可预先 `python3 scripts/run_standards_conformance.py --prefetch
--cache /tmp/yjson-standards-suites`，之后加 `--offline` 运行。
