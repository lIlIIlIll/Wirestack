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
- Native parse/roundtrip 必须计入 deterministic `close()`。
- 跨 runtime 结果只描述该 API/workload，不代表产品整体。
- latency、throughput、allocation、RSS 和 peak memory 分别测量和陈述。

## 候选处置

优化候选必须在目标 workload 外检查邻近 workload 和总表。确认 regression 且没有被明确
接受时回滚候选，并记录“未采用”而不是只保留最佳局部结果。固定-local quick run 只能决定
是否继续正式测量。

用户结果页只保留理解结论所需的统计和限制。原始样本、日志、manifest、checksum 与环境
细节进入不可变 release artifact；开发机绝对路径和临时排障过程不进入稳定文档。
