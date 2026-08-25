# Benchmarks

本目录保存 yjson 的性能 workload 与对比 adapter。它们服务于回归分析，不构成产品 API。

## 覆盖范围

- `packages/benchmarks/`：yjson 与 stdx.json 的 typed workload；
- `packages/backend_benchmarks/`：Pure AST、Pure Compact、Custom Native 与 yyjson Direct
  的 DOM backend workload；
- `cjfast_json/`：cjfast_json typed adapter；
- `java_fastjson2/`：fastjson2 adapter；
- `scripts/json_perf_baseline.py`：统一结果 schema；
- `scripts/json_backend_perf_run.py` 与 `json_backend_perf_summary.py`：backend 采集与汇总。

不同 runner 可能跨越 runtime，不能把输出直接解释成统一排名。DOM backend、typed codec
与 typed stream 也必须分别报告。

## 结果要求

公开结论必须：

- 使用等语义 workload，并明确 API、representation 与输入形态；
- 分开报告方向证据和通过稳定性门槛的精确比例；
- 每个 release 输出 yjson、stdx.json、cjfast_json 的全部共同 workload；
- 保留高 CV 行，并明确标记 `noisy`；
- 保留 baseline/candidate 身份和可审计的聚合结果；
- 不把机器本地路径、临时日志或一次 quick run 写入用户文档。

统计口径和现有结果见[性能文档](../docs/performance/README.md)。
