# 性能证据

yjson 的性能取决于 API、representation、payload、输入形态和主机。typed codec、mutable
AST、Pure Compact、Native DOM 与 typed stream 是不同问题，不能拼成一个“最快库”排名。

## 当前 release 结果

- [yjson 2.0.0 性能验收](results/2026-08-27-yjson-2.0.0.md)：最终候选源码的三库
  36-workload 表与 Native 单引擎 7-workload 门禁。两组结果都使用固定 CPU、128 MiB heap
  和 11 轮交替测量，并保留完整 release artifact。

## 当前开发结果

- [2026-08-28 Stream protocol v1](results/2026-08-28-stream-protocol-v1.md)：typed
  incremental encode/decode、三种 payload、三种 chunk、两种 sink 和内部 scratch 生命周期。
  结果包含 previous-yjson A/B 与 yjson/stdx.json peer 表，并保留完整 Server 原始数据。
  A/B 稳定性与生命周期门槛未通过，因此不能作为发布性能声明。

## 历史结果

- [2026-08-26 Native 单引擎加速门禁](results/2026-08-26-native-acceleration.md)：2.0.0
  最终候选之前的固定源码批次。
- [2026-08-25 Linux rc.2 三库表](results/2026-08-25-linux-rc2-three-library.md)：
  `1.0.0-rc.2` 的 36 个共同 workload。
- [2026-08-25 Linux release baseline](results/2026-08-25-linux-release-three-library.md)：
  后续 correctness 修改之前的固定源码批次。
- [yjson / cjfast_json](results/2026-08-21-cjfast-json.md)：typed codec 对比。
- [Go yyjson DOM](results/2026-08-22-go-yyjson.md)：跨 runtime mutable DOM 对比，不代表
  generated typed codec。
- [Typed stream backend](results/2026-08-24-stream-backends.md)：同一 codec 下 Pure、Custom
  Native 和 yyjson stream。

带日期页面是固定源码和环境的结果，不会因为后续优化而改写。release 原始轮次、manifest、
日志和 checksum 位于对应 `release/<version>/artifacts`。

未进入 release 的开发结果保存在 `benchmarks/results/<protocol>/<date>/`。这些结果可以解释
设计取舍，但只有结果页明确写为通过时才能用于发布声明。

## 如何读表

- ratio 统一为 `yjson median / peer median`；小于 1 表示 yjson 延迟更低。
- `stable` 允许讨论精确比例；`noisy` 只提供方向或不确定结论。
- 高 CV 行仍然保留，不能借稳定性门槛隐藏不利 workload。
- 不同日期、runtime、SDK、输入或 API 的数字不能合并。
- latency 不能推导 allocation、RSS、峰值内存或吞吐。

每个 release 必须给出 yjson、stdx.json、cjfast_json 的同批次完整共同 workload 表。README
和选型指南不复制会快速过期的绝对数字，只链接可审计结果。

采集、稳定性和回滚规则见[性能方法](methodology.md)；已采纳和拒绝的设计方向见
[性能研究结论](../performance.md)。
