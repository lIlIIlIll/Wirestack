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

Typed codec、DOM backend、typed stream 和跨 runtime adapter 必须分别报告，不能把不同
representation 或 lifecycle 拼成统一排名。

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
