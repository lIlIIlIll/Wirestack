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
