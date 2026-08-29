# yjson benchmarks

本目录保存性能 workload、peer adapter 和汇总脚本。它们用于回归与发布证据，不是产品
API，也不能单独证明语义正确。

## 组成

| 路径 | 作用 |
| --- | --- |
| `packages/benchmarks` | yjson、stdx.json typed workload |
| `packages/backend_benchmarks` | AST / Compact / Native DOM workload |
| `cjfast_json` | cjfast_json typed adapter |
| `java_fastjson2` | fastjson2 adapter |
| `scripts/json_perf_baseline.py` | 统一采集 schema |
| `scripts/json_backend_perf_run.py` | backend runner |
| `scripts/json_backend_perf_summary.py` | backend 汇总 |
| `stream_protocol/workloads.json` | Stream protocol v1 workload 与输入 profile |
| `scripts/json_stream_protocol_run.py` | previous-yjson 与候选的生命周期配对采集 |
| `scripts/json_stream_peer_run.py` | yjson 与 stdx.json 的 incremental Stream 配对采集 |
| `scripts/json_pure_perf_compare.py` | Pure baseline/candidate 内部优化配对采集 |

Typed codec、DOM backend、typed stream 和跨 runtime adapter 必须分别报告，不能把不同
representation 或 lifecycle 拼成统一排名。

## Pure baseline/candidate workload

`scripts/json_pure_perf_compare.py` 用于判断内部优化是否值得保留。准备两个独立、clean 的
源码目录；正式运行通过 `--rebuild --enforce` 在两侧清理并重建 `packages/benchmarks`。结果
目录必须位于两个源码目录之外。两个目录中的 benchmark harness 必须相同，产品源码可以不同。

语料目录必须包含 `person.json`、`records-64k.json` 和 `records-1m.json`。各 workload 测量
以下操作：

| Case 模式 | 输入与计时边界 |
| --- | --- |
| `yjsonStringEncodePerson` / `DecodePerson` | 单个 generated `Person` 与 `String` 互转 |
| `*LargeProfileArray` | generated `ProfileRecord` 大数组；覆盖字段名、字符串和整数 |
| `*DeepNestedProfiles` | `ArrayList<HashMap<String, ArrayList<ProfileRecord>>>`；覆盖递归容器 |
| `*ProfileBundle` | generated bundle 的 String 或 bytes encode/decode |
| `*EscapedUnicodeString` | 含控制字符、反斜杠和非 ASCII 文本的 encode |
| `parseStringRecords*` | `YJson.parseDocument(String)`，分别使用 64 KiB 和 1 MiB 文档 |
| `parseBytesRecords*` | `YJson.parseDocument(Array<Byte>)`，使用相同文档 |
| `decode*Chunk4k` | `YJson.fromStream`，输入由 4096-byte chunk 提供 |
| `encode*Memory` | `YJson.toStream` 写入 caller-owned memory stream |

同一 benchmark class 还包含三个 XL scale workload，用于观察输入规模扩大后的热点：

| Case | 数据形状 | API |
| --- | --- | --- |
| `*XlProfileArray` | 1024 个 `ProfileRecord` | `encodeStringWith` / `decodeStringWith` 与一次解析的 typed list codec |
| `*XlInt64Map` | 一个包含 1024 个 entry 的 `HashMap<String, Int64>` | `encodeStringWith` / `decodeStringWith` 与专用 Int64 map codec |
| `*XlDeepNestedProfiles` | 64 组 × 每组 16 条记录，共 1024 条 | `encodeStringWith` / `decodeStringWith` 与递归 typed codec |

XL case 使用构造阶段解析一次的具体 codec，元素循环内不做 codec resolution。它们是 yjson
内部规模分析 workload。只有 peer 提供等语义数据形状和对应最优 typed API 时，才能进入
跨库共同结果表。

在 Linux Server 上运行完整矩阵：

```terminal
scripts/json_pure_perf_compare.py \
  --baseline /path/to/baseline \
  --candidate /path/to/candidate \
  --corpus /path/to/corpus \
  --output /path/to/result \
  --rounds 11 \
  --target-case yjsonStringDecodeLargeProfileArray \
  --rebuild \
  --enforce
```

不传 `--cpu` 时，runner 采样物理 core 的两个 hardware thread，并选择两者利用率都低于 1%
的 core。每次测量固定到其中一个 thread，另一个由 `scripts/monitor_cpu_pair.py` 记录。runner
把 heap 固定为 128 MiB，并在奇偶轮反转 baseline/candidate 顺序。

成功运行会生成 `provenance.json`、`summary.json`、`summary.md`、`cpu-selection.json`、两侧
build log、CPU 监控 CSV，以及每轮原始 benchmark report 和日志。provenance 包含共同 harness
摘要、两侧源码和 executable 身份、工具链、语料与调用参数。`--enforce` 固定要求 11 轮、
`--rebuild` 和 clean 源码树；任一 case 回退超过 5%、任一方 CV 超过 5%，或
`--target-case` 指定的目标未提升 5% 或少于 5/11 轮胜出时，命令返回非零状态。

## 发布结果要求

- workload 语义、API、payload 和输入形态一致；
- baseline/candidate 或多库交替、反转顺序执行；
- 完整保留 yjson、stdx.json、cjfast_json 的共同 workload；
- 高 CV 行保留并标为 noisy；
- 方向证据与稳定精确比例分开；
- 保存 commit/runtime/host identity、raw rounds、manifest 与 checksum；
- 不把临时路径、quick run 或未同步的跨批次数字写入 README。

统计和证据政策见[性能方法](../docs/performance/methodology.md)，可引用结果见
[性能入口](../docs/performance/README.md)。

## 验证 Stream 文档

运行下面的命令，校验归档 checksum、机器汇总和生成的 workload 页面：

```terminal
scripts/ci_job.sh stream-docs
```

命令输出每个文件的 `OK`、`Stream workload documentation is current`，以及三个 JSON
汇总的等价检查。正式 benchmark 必须在文档规定的 Server 环境运行，不能用这个检查替代。
