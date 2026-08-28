# 性能测量方法

公开结论必须能回答：测了什么 API、在什么源码和环境、与谁比较、怎样处理顺序偏差与波动。

## 身份冻结

每次测量记录：

- yjson 与 peer 的 commit/tag/checksum；
- Cangjie SDK 或其他 runtime 版本；
- OS、architecture、CPU 和必要的编译/link 选项；
- workload、payload checksum、operation 与输入形态；
- warmup、轮次、执行顺序和结果 schema。

没有这些身份信息的本地数字只能用于探索，不能进入用户-facing 结论。

## 配对执行

baseline/candidate 或多库比较使用等语义 workload，并交替或反转执行顺序以降低热状态、
频率和后台负载偏差。先验证输出/checksum，再记录时间；错误结果即使更快也不计入性能。

## 统计与展示

- 以 process median 为主要延迟统计。
- ratio 为 `yjson median / peer median`。
- README/代表行要求双方 CV ≤ 5%。
- 更严格的绝对延迟声明要求 CV ≤ 3%。
- 未过门槛的行保留并标记 noisy，不发布精确比例。
- 配对胜负方向可作为探索证据，但必须与稳定比例分开。

CV 门槛只控制可陈述精度，不是筛选 workload 的工具。

## 比较边界

- typed codec 只与等语义 typed codec 比较。
- DOM parse/query/serialize 按 representation 和 lifecycle 分开。
- 默认 `YJson.parseDocument` 返回 managed Compact document，不存在 `close()`；Native 临时
  资源必须在计时操作返回前释放。
- 只有高级 `BackendJsonDocument` parse/roundtrip 才必须在计时范围内包含 deterministic
  `close()`。
- 跨 runtime 结果只描述该 API/workload，不代表产品整体。
- latency、throughput、allocation、RSS 和 peak memory 分别测量和陈述。

## 候选处置

优化候选必须在目标 workload 外检查邻近 workload 和总表。确认 regression 且没有被明确
接受时回滚候选，并记录“未采用”而不是只保留最佳局部结果。固定-local quick run 只能决定
是否继续正式测量。

用户结果页只保留理解结论所需的统计和限制。原始样本、日志、manifest、checksum 与环境
细节进入不可变 release artifact；开发机绝对路径和临时排障过程不进入稳定文档。

## Native acceleration gate

Pure 与 Native 必须在独立进程中运行，因为首次 `YJson` 调用会冻结引擎。正式 gate 固定
11 轮、同一 CPU affinity、128 MiB heap，并在每轮交替 Pure/Native 顺序：

- 广告 read/write workload：双方 CV ≤ 5%、`Native/Pure ≤ 0.95`，且 Native 至少赢 6/11；
- 普通稳定 workload：双方 CV ≤ 5%、`Native/Pure ≤ 1.05`；
- 任一行超过 CV 门槛时，丢弃该批次并完整重跑一次，不按单行挑选样本；
- immediate rerun 只有在 build-source digest 未变化时才能复用可执行文件。

这个 gate 证明的是列出的 workload，不自动证明所有 typed container、stream 或 DOM 调用都被
加速。

## Stream protocol v1

Stream 比较只接受 caller-owned `InputStream` 或 `OutputStream`。Decode 的 stream 和 chunk
plan 在计时区外创建。Encode 的 sink 在计时区外创建，最终 snapshot 不计入 materializing
sink 的时间。必须预聚合为 `String` 或 `ByteBuffer`，或必须创建 DOM/tape 的 peer 标为
`N/A`。

正式采集固定 CPU 8 和 128 MiB heap。每个 workload、实现和生命周期的单元格使用独立
进程，运行 11 轮。case 顺序轮转并反转，配对顺序交替。核心矩阵使用 64-byte、4096-byte
和确定性 1 到 8192-byte chunk，以及 memory 和 counting sink。1-byte chunk 只用于正确性
验证。

候选必须同时满足以下条件：

- 稳定核心行相对冻结 baseline 不回退超过 5%；
- 至少两个 canonical Decode workload 提升 5%，且候选赢至少 6/11；
- 内部 scratch 复用在至少两个 canonical payload 上快于关闭复用；
- 所有阻断行双方 CV 不超过 5%。

完整重跑一次后仍超过 CV 门槛的批次必须保留并标为未通过。方向一致的 noisy 行可以说明
观察方向，不能发布精确比例。
