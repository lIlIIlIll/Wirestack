# 测试 yjson

本页列出测试分类和发布要求。每次运行的提交、SDK、运行器、日志、用例数和校验和写入
对应 `release/<version>/evidence.md`，不能回填到通用说明。

## 测试分类

| 分类 | 验证内容 | 入口 |
| --- | --- | --- |
| 核心包 | 解析器、写入器、codec、AST、GC 管理的文档、增量流处理、预算 | `cjpm test` |
| 外部 codec 使用方测试 | 调用方宏、enum、多态、显式 codec | `packages/codec_integration` |
| 算法与标准 | Pointer、Patch、Path、Schema、固定语料 | `packages/yjson_algorithms` / 标准运行器 |
| 可选格式 | libidn2 provider 和可选 Schema 语料 | `packages/yjson_schema_formats` |
| 后端 | 命名入口、视图、关闭和读取并发、整份文档读写 | Native/yyjson 包测试 |
| 加速 | Pure/Native 实现选择、ABI、并发、故障和性能验证 | `runtime-freeze` 和发布性能脚本 |
| Native C | 编译警告、ASan、UBSan、LSan、差分模糊测试、符号隔离 | Native 发布脚本 |
| 打包 | 仅含源码的暂存目录、九包发布图、隔离的使用方测试、许可证 | 发布脚本 |
| API 文档 | cjdoc 源码验证、九包 Doc IR/HTML、已知限制清单 | `api-docs` |
| 覆盖率 | 项目及改动的行和分支覆盖率 | `scripts/coverage.sh` + 改动覆盖率检查器 |
| 性能 | 固定 CPU 的交替/反转 A/B、校验和、RSS、跨性能配置 | 发布性能脚本 |

基准测试不能替代正确性测试；根包白盒测试通过也不能替代暂存发布版的外部使用方测试。

## 快速结构检查

不依赖 Cangjie 编译的检查包括：

```terminal
python3 scripts/check_api_inventory.py
python3 scripts/test_stage_source_tree.py
python3 scripts/test_release_temp_tree.py
python3 scripts/test_check_cjdoc_qualification.py
python3 scripts/test_generate_api_docs.py
```

这些命令验证 API 快照、仅含源码的暂存、发布文件清单完整性和 cjdoc 限制清单，但
不能替代核心包、使用方测试、标准或 Native 测试。

## 工具链选择

托管 CI 固定使用 Cangjie STS `1.1.0`，所有需要 Cangjie 的任务使用同一
解析结果。`workflow_dispatch` 可以显式指定一个 STS 版本，以便重跑一个候选。
cjdoc 从固定源码版本构建，但编译时使用同一个 STS SDK；验证证据
记录实际 `cjc` 和 `cjpm` 输出，并拒绝与统一版本不一致的编译器。

checkout、setup、Codecov 和 Pages Action 使用完整 commit SHA。发布证据还要记录 SDK
归档校验和、运行器镜像、工作流运行 ID 和产物校验和。

## CI 任务对应关系

GitHub Actions `CI` 工作流在推送到 `main` 或 `dev`、提交目标为 `main` 的 PR，
以及定时和手工触发时运行。

Linux x86_64 的 `tests` 矩阵包含：

- `api-inventory`、`cjdoc-qualification`、`runtime-freeze`、`core`；
- `standards-conformance`、`schema-formats-conformance`；
- `examples`、`macro-consumer`、`algorithms-consumer`、`registry-rehearsal`；
- `custom-native`、`yyjson-native`、Clang/GCC、sanitizer、short fuzz、yyjson co-link。

`pure-platforms` 在 Windows Server 2022 和 macOS 14 上运行核心包与算法的 Pure 检查。
它们不构建 Native 包。`api-docs` 生成 Pages 产物；只有推送到 `main` 后才部署。
`coverage`、七库性能证据检查和流性能证据检查各自独立运行。

`generated-change-risk` 是独立的源码变更检查。PR 或推送修改
`packages/yjson_macros/`、`generated_support.v1` 或直接读写接口或 codec 时，同一变更集
必须增加 `packages/codec_integration/src/*_test.cj` 外部运行时测试。`macro-consumer` 随后同时
执行该包的 `cjpm test` 和可执行程序冒烟测试。宏源码不纳入核心包行覆盖率分母；
生成代码能否编译、运行和往返转换由外部使用方行为测试证明。

在本地 Linux 上验证新候选副本：

```terminal
scripts/ci_fresh_checkout.sh
```

本地结果不能代表 Windows 或 macOS 的托管 CI 结果。托管工作流未执行时，平台状态必须写
`NOT RUN`，不能从源码可移植性推断 PASS。

## 覆盖率

`scripts/coverage.sh` 在临时源码目录中以 `-O0` 编译，合并根包测试、运行时实现选择
和 Native 加速场景，生成 HTML、JSON、XML 与 `coverage/lcov.info`。覆盖率检查只统计
`src/lib_*.cj` 产品源码。

[`coverage-baseline.toml`](../../coverage-baseline.toml) 固定：

| 范围 | 行 | 分支 |
| --- | ---: | ---: |
| 项目 | 80% | 70% |
| 改动 | 90% | 80% |

项目覆盖率检查始终阻止不达标的改动。PR 只有在基线分支已包含覆盖率配置时，才检查改动
覆盖率；首次引入配置也不能跳过项目检查。LCOV 以 `core` flag 上传 Codecov，上传失败阻断工作流。

### Codecov flags

`codecov.yml` 为五组源码定义独立 flag，每组都有项目检查（自动目标，0.1% 容差）
与改动检查（90% 行覆盖率）：

| Flag | 路径 | 说明 |
| --- | --- | --- |
| `core` | `src/lib_*.cj` | 根包产品源码，沿用原有规则 |
| `algorithms` | `packages/yjson_algorithms/src/` | Pointer/Patch/Path/Schema |
| `native` | `packages/yjson_native{,_primitives,_accel}/src/` | 扫描器、第一方 provider 接口与后端入口 |
| `yyjson` | `packages/yjson_yyjson/src/` | yyjson Compact 后端 |
| `schema-formats` | `packages/yjson_schema_formats/src/` | 可选国际化格式扩展 |

每个 flag 的 lcov 文件由覆盖收集器按包生成（`coverage/lcov.<flag>.info`），CI 上传步骤在
文件不存在时跳过，避免未收集阶段误报失败。宏源码（`packages/yjson_macros/`）继续排除在
所有 flag 之外：声明宏的展开产物由外部使用方行为测试验证
（`packages/codec_integration`），编译期代码无法用行覆盖率有意义地衡量。

## 功能与执行方式

| 公开行为 | Pure | Native 加速 | Native/yyjson 独立入口 | 验证方式 |
| --- | ---: | ---: | ---: | ---: |
| 生成的 class/struct/enum | 主实现 | 同一 codec/语义实现 | 同一 `JsonCodec<T>` 约定 | codec 使用方测试 |
| 字符串、字节数组和流 | 主实现 | 替换底层操作 | 整份文档缓冲 | 使用方测试和包测试 |
| 可变 `JsonNode` | 是 | 不改变 | 转换为 AST 后 | 核心包和示例 |
| GC 管理的 `JsonDocument` | 是 | 临时 Native 资源已释放 | n/a | 核心包和运行时实现选择测试 |
| `BackendJsonDocument` 生命周期 | n/a | n/a | 显式资源 | 关闭与读取竞争测试 |
| 选项和错误语义 | 主实现 | 相同 | 相同 | 差分测试用例 |
| Pointer/Patch/Path/Schema | `JsonValueView` | 相同视图 | 相同视图 | 算法和标准测试 |
| API 参考文档 | 九包 cjdoc | 第一方接口标记 | 高级包文档 | API 文档检查 |

## 专项测试

- 字符串、字节数组、分块流和后端 tape 复用合法和非法的语义测试用例，比较值、
  UTF-8、转义、数字、错误码、路径和位置。
- 流读取器覆盖跨块字符串、转义、数字和结构 token；一次性字节输入
  不能替代这项证明。
- 写入器对比字符串、字节数组、流和视图，并覆盖非法状态、循环引用、深度、输出预算和
  非有限浮点。
- 生成代码的外部使用方测试检查协议 v1、递归容器、自定义 codec、枚举和多态重放。
  集合字段矩阵覆盖顶层与字段、空与非空、compact 与 pretty，以及 Array、ArrayList、
  HashMap 的嵌套组合。
- 加速实现的生命周期覆盖 Pure 和 Native 的实现选择、幂等、晚初始化、并发竞争、缺库、
  ABI/协议错误和重入调用；故障不得静默回退。
- 后端文档覆盖打开期并发读、与关闭的并发执行顺序，以及关闭后的根视图。
- Schema 证明 resolver 只在构造时调用，格式注册表和正则表达式在已编译的 Schema 中固定。
- JSONPath 证明创建游标时不遍历，预算在 `next()` 时消耗，`first()` 提前停止。

## 测试要求

- 每个用例必须有确定的预期，不能将“接受或拒绝均可”作为通过条件。
- 优先验证公开结果、错误码、生命周期、包边界和兼容性。
- 外部语料固定版本与预期用例数，不依赖未固定版本的检出目录。
- 可执行程序必须传播应用异常；shell 退出码为 0 但输出含未处理异常仍是失败。
- 性能只提供性能证据，不证明语义正确。

标准运行器的预期用例数为必测 Schema 1299、JSONPath CTS 703、JSON Patch
108；可选格式扩展增加 964 个适用用例。每次 PASS 都应记录对应的提交、工具链和运行条件。

CI 对 `standards-conformance` 和 `schema-formats-conformance` 任务先执行一次 `--prefetch`（下载并 SHA-256 校验固定
版本的官方测试集归档），结果作为缓存产物复用；运行检查时显式传
`--offline`（`YJSON_STANDARDS_OFFLINE=1`），只使用缓存，缓存缺失即失败并打印预取命令。
本地开发者无网络时可预先 `python3 scripts/run_standards_conformance.py --prefetch
--cache /tmp/yjson-standards-suites`，之后加 `--offline` 运行。
