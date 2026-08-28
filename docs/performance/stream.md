# Stream 性能

本页只讨论 typed stream API。它不把 `String`、`ByteBuffer`、DOM 或 whole-document tape
结果标成 stream 性能，也不代表 yjson 在所有 JSON workload 上的总排名。

## 测量什么

Decode 的计时区从 `YJson.fromStream<T>(stream)` 开始，到完整 typed value 返回为止。stream
对象和确定性 chunk plan 在计时区外创建。Encode 的计时区只包含
`YJson.toStream(value, output)`；sink 创建或 reset 在计时区外，最终 byte snapshot 不计入
materializing sink 的时间。

核心矩阵有 30 行：

- Decode：3 个 payload × 3 个 chunk profile × 2 个生命周期，共 18 行。
- Encode：3 个 payload × 2 个 sink profile × 2 个生命周期，共 12 行。

具体 JSON、实际 UTF-8 大小、SHA-256、首尾记录和生成参数见
[Stream workload 参考](stream-workloads.md)。

## 生命周期

protocol v1 的生命周期实验比较 `Unpooled one-shot` 与 `Pooled steady-state`。前者每次调用
分配 4 KiB scratch。后者允许实验候选从每线程单槽取得 4 KiB managed scratch。reader、
writer、config 和 caller-owned stream 都按调用创建，不进入池。

实验池在同线程重入时为内层调用分配临时 scratch，线程之间不共享 scratch。池中不保留
stream 或 Native resource。这个实验未达到生命周期门槛，最终候选已撤回它。public API
仍不承诺 reusable reader 或 writer，后续实现可以在不修改 API 的情况下重新验证内部复用。

## 正确性资格

性能数字只在以下条件通过后有效：

- 在每个 byte split point 验证 string、escape、number、UTF-8 和递归容器；
- success→failure、failure→success、config 隔离和同线程 custom codec 重入；
- 多线程并行调用、large→small scratch、错误 code/offset/line/column/path 一致；
- 普通 stream 路径不得预聚合输入、read-to-EOF 或先建 DOM/tape。

1-byte chunk 只用于正确性和诊断，不进入核心性能表。

## 统计和发布门槛

正式结果在可信 Server 上固定 CPU 8 和 128 MiB heap。每个 workload、实现和生命周期的
单元格各运行一个独立进程，共运行 11 轮。workload 顺序轮转，偶数轮反转；实现和生命周期
顺序交替。表中报告 process median、p95、CV、配对胜场，以及配对 improvement 的 bootstrap
95% CI。不删除单点 outlier。

候选必须满足：稳定核心行相对冻结的 previous-yjson baseline 不回退超过 5%；至少两个
canonical Decode workload 提升 5% 且赢至少 6/11；pooled steady-state 在至少两个 payload
上快于 unpooled；双方 CV 不超过 5%。噪声超限时只允许完整重跑一次，第二批仍 noisy 就原样
保留并阻断精确结论。

stdx.json、cjfast_json 和跨 runtime peer 只有在通过相同 incremental eligibility 检查时才进入
对应单元格。不支持真正增量输入、必须预聚合或必须构建 DOM/tape 的实现标为 `N/A`，不会用
内存 ByteBuffer 数字替代。

## 当前结果

[2026-08-28 Stream protocol v1 结果](results/2026-08-28-stream-protocol-v1.md)未通过发布
门槛。previous-yjson A/B 的 9 个 Decode workload 中位数都改善 41% 到 63%，但 11 行的
baseline 或 candidate CV 超过 5%。scratch 复用也只在一个 canonical payload 上方向更快，
没有达到两个 payload 的门槛，因此没有进入最终实现。

旧的 Person Stream 行包含 stream 或 sink 构造、最终字符串物化，或不等价的 peer 输入形态。
这些行只保留为历史记录，不用于当前 Stream 性能结论。
