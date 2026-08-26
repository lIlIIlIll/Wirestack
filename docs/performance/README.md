# 性能证据

yjson 的性能取决于 API、representation、payload、输入形态和主机。typed codec、mutable
AST、Pure Compact、Native DOM 与 typed stream 是不同问题，不能拼成一个“最快库”排名。

## 当前结果入口

- [Native 单引擎加速门禁](results/2026-08-26-native-acceleration.md)：同一 `YJson` API 下
  Pure/Native 的固定 CPU、128 MiB、11 轮交替测量。
- [Linux 三库 release 表](results/2026-08-25-linux-rc2-three-library.md)：yjson、stdx.json、
  cjfast_json 同批次的 36 个共同 workload。
- [yjson / cjfast_json](results/2026-08-21-cjfast-json.md)：typed codec 对比。
- [Go yyjson DOM](results/2026-08-22-go-yyjson.md)：跨 runtime mutable DOM 对比，不代表
  generated typed codec。
- [Typed stream backend](results/2026-08-24-stream-backends.md)：同一 codec 下 Pure、Custom
  Native 和 yyjson stream。

带日期页面是固定源码和环境的结果，不会因为后续优化而改写。release 原始轮次、manifest、
日志和 checksum 位于对应 `release/<version>/artifacts`。

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
