# yjson benchmarks

本目录保存性能测试用例、对照库适配器和汇总脚本，用于检查性能回退和收集发布证据。
这些代码不属于产品 API；性能测量还需要单独验证结果是否正确。

## 组成

| 路径 | 作用 |
| --- | --- |
| `packages/benchmarks` | yjson、stdx.json 类型编解码测试，以及 JSONPath 与 Schema API 对照 |
| `packages/backend_benchmarks` | AST、GC 管理的文档、Native 与 yyjson 测试 |
| `cjfast_json` | cjfast_json 类型编解码适配器 |
| `java_fastjson2` | fastjson2 适配器 |
| `scripts/json_perf_baseline.py` | 统一采集结果格式 |
| `scripts/json_backend_perf_run.py` | 后端测量脚本 |
| `scripts/json_backend_perf_summary.py` | 后端结果汇总 |
| `stream_protocol/workloads.json` | Stream protocol v1 用例与输入配置 |
| `scripts/json_stream_protocol_run.py` | 旧版 yjson 与候选版本的生命周期配对采集 |
| `scripts/json_stream_peer_run.py` | yjson 与 stdx.json 的增量流处理配对采集 |
| `scripts/json_pure_perf_compare.py` | Pure 基线与候选版本的内部优化配对采集 |
| `full-seven-library/fixture-preflight-overlay.patch` | 七库外部测试程序中对标准输入的编码与解码断言 |
| `results/full-seven-library/<date>` | 当前开发版七库同批次对比的原始证据与校验和 |

类型编解码器、DOM 后端、类型化流编解码和跨运行时适配器的结果必须分别报告，不能将不同
数据表示或生命周期的测量合并排名。

<a id="pure-baselinecandidate-workload"></a>

## 比较 Pure 基线与候选版本

`scripts/json_pure_perf_compare.py` 支持普通 Release 验收和内部优化评估。准备两个独立且没有未提交
修改的源码目录；正式运行通过 `--rebuild --enforce` 在两侧清理并重建 `packages/benchmarks`。
结果目录必须位于两个源码目录之外。两个目录中的性能测试程序必须相同，产品源码可以不同。

语料目录必须包含 `person.json`、`records-64k.json` 和 `records-1m.json`。各用例测量
以下操作：

| 用例名称模式 | 输入与计时边界 |
| --- | --- |
| `yjsonStringEncodePerson` / `DecodePerson` | 使用生成的编解码器，将单个 `Person` 与 `String` 互转 |
| `*LargeProfileArray` | 使用生成的编解码器处理 `ProfileRecord` 大数组；覆盖字段名、字符串和整数 |
| `*DeepNestedProfiles` | `ArrayList<HashMap<String, ArrayList<ProfileRecord>>>`；覆盖递归容器 |
| `*ProfileBundle` | 使用生成的编解码器，将组合类型与字符串或字节数组互转 |
| `*EscapedUnicodeString` | 含控制字符、反斜杠和非 ASCII 文本的编码 |
| `parseStringRecords*` | `YJson.parseDocument(String)`，分别使用 64 KiB 和 1 MiB 文档 |
| `parseBytesRecords*` | `YJson.parseDocument(Array<Byte>)`，使用相同文档 |
| `decode*Chunk4k` | `YJson.fromJson(InputStream)`，输入按 4096 字节分块提供 |
| `encode*Memory` | `YJson.writeJson` 写入调用方持有的内存流 |

同一性能测试类还包含三个 XL 大规模测试，用于观察输入增大后的热点：

| 用例 | 数据形状 | API |
| --- | --- | --- |
| `*XlProfileArray` | 1024 个 `ProfileRecord` | `YJson.toJson/fromJson` + 显式的类型化列表编解码器 |
| `*XlInt64Map` | 一个包含 1024 个键值对的 `HashMap<String, Int64>` | `YJson.toJson/fromJson` + Int64 映射编解码器 |
| `*XlDeepNestedProfiles` | 64 组 × 每组 16 条记录，共 1024 条 | `YJson.toJson/fromJson` + 递归类型编解码器 |

XL 用例在构造阶段解析一次具体的编解码器，不在遍历元素时重复解析。它们是 yjson
内部规模分析用例。只有对照库提供语义相同的数据结构和对应的最优类型编解码 API 时，才能进入
跨库共同结果表。

`AlgorithmOptimizationBenchmarks` 使用同一输入检查三项设计边界：在视图上找到首项后停止、收集
全部匹配后取首项、转成 AST 后再查询；另外比较 Schema 编译一次后重复验证与每次重新
解析 Schema。测试程序在计时前验证结果一致。这组测试用于观察性能回退，不与类型编解码器或 DOM
后端的排名混合。

在 Linux Server 上运行发布验收矩阵：

```terminal
scripts/json_pure_perf_compare.py \
  --baseline /path/to/baseline \
  --candidate /path/to/candidate \
  --corpus /path/to/corpus \
  --output /path/to/result \
  --rounds 11 \
  --gate-mode release \
  --rebuild \
  --enforce
```

`release` 模式只检查完整结果的稳定性和回退：任何用例回退超过 5%，或任一方 CV
超过 5%，命令返回非零状态。它不要求候选版本相对基线提升。

如果正在评估一个明确的内部优化，再显式启用优化模式：

```terminal
scripts/json_pure_perf_compare.py \
  --baseline /path/to/baseline \
  --candidate /path/to/candidate \
  --corpus /path/to/corpus \
  --output /path/to/result \
  --rounds 11 \
  --gate-mode optimization \
  --target-case yjsonStringDecodeLargeProfileArray \
  --target-improvement-percent 5 \
  --rebuild \
  --enforce
```

优化模式在发布模式的基础上，要求每个 `--target-case` 至少提升指定百分比，并在
11 轮中至少胜出 5 轮。`--target-case` 和 `--target-improvement-percent` 只能与
`--gate-mode optimization` 一起使用；目标优化门禁不是普通 Release 的必要条件。

不传 `--cpu` 时，脚本采样物理核心的两个硬件线程，并选择两者利用率都低于 1%
的核心。每次测量固定到其中一个线程，另一个由 `scripts/monitor_cpu_pair.py` 记录。脚本
将堆内存固定为 128 MiB，并在奇偶轮反转基线与候选版本的执行顺序。

成功运行会生成 `provenance.json`、`summary.json`、`summary.md`、`cpu-selection.json`、两侧
构建日志、CPU 监控 CSV，以及每轮原始性能报告和日志。来源记录包含共同测试程序的
摘要、两侧源码和可执行文件的版本与摘要、工具链、语料与调用参数。`--enforce` 固定要求 11 轮、
`--rebuild` 和无未提交修改的源码树。

## 发布结果要求

- 用例语义、API、输入数据和输入形态一致；
- 基线与候选版本或多个库交替、反转顺序执行；
- 完整保留 yjson、stdx.json、cjfast_json 的共同用例；
- 高 CV 行保留并标为 noisy（波动过大）；
- 方向证据与稳定精确比例分开；
- 保存提交、运行时和主机信息、各轮原始结果、测量清单与校验和；
- 不把临时路径、快速测量结果或未同步的跨批次数字写入 README。

统计方法和证据要求见[性能方法](../docs/performance/methodology.md)，可引用结果见
[性能入口](../docs/performance/README.md)。

## 验证 Stream 文档

运行下面的命令，校验归档的校验和、机器汇总和生成的测试输入页面：

```terminal
scripts/ci_job.sh stream-docs
```

命令输出每个文件的 `OK`、`Stream workload documentation is current`，以及三个 JSON
汇总的等价检查。正式性能测量必须在文档规定的 Server 环境运行，不能用这个检查替代。
