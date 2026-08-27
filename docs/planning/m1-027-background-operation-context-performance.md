# M1-027：background OperationContext 每调用成本

## 状态

- 规划状态：**COMPLETE**
- 责任域：Transport 内部性能
- 证据目录：`docs/evidence/M1-027/`
- Linux 结论：Wirestack 内部 background fast path 将 empty `readSome` P50
  从 297.042 ns 降至 92.110 ns；正式 GATE-NET-05 五个 payload 全部满足
  吞吐和 P95 门槛，staging copy 为 0；详见
  [Linux 证据](../evidence/M1-027/README.md)。

## 触发证据

M0-010 已在 Linux x86_64 上使用同一 `-O2` unittest binary、一次预热和
11 轮交替顺序测量完成 GATE-NET-05。适配器 staging copy 已降为 0，但
1 KiB、16 KiB 和 64 KiB 仍未达到 PRD 门槛；1 MiB 和 100 MiB 已通过。
该结果证明需要分析短操作上的固定增量成本，但不预设具体代码根因。

## 范围

1. 建立可重复的每调用成本剖析，分别量化 `OperationContext.background()`、
   取消 registration、Deadline/timer、lifecycle claim/release、同方向
   operation gate、exactly-once cleanup 和 native `std.net` I/O 的成本。
2. 对比 raw `std.net`、当前 `StdNetTransport` 和候选实现；保留环境、提交、
   编译参数、原始样本、统计方法和剖析产物。
3. 仅当剖析证据支持时，为“无取消、无 Deadline、无 trace/event sink”的
   background context 增加 Wirestack 内部 fast path。
4. 不修改 runtime、`stdx` 或 sibling repository，不调用私有 runtime ABI，
   不把 `UP-004` 作为本任务的默认实现路径。

## 语义护栏

- 已取消 token 仍须在网络副作用前失败。
- Deadline 仍使用单调绝对预算，内部循环不得重置预算。
- cancellation registration、timer 和 waiter 在终态后仍须 exactly-once 清理。
- 一读一写可并行；同方向并发仍须稳定拒绝。
- close、abort、成功、EOF、取消和 Deadline 竞态不得合并终态或重复完成。
- 不以 exception message 作为 fast-path 控制流，不新增 timeout owner。
- 公共 `OperationContext` 和 Transport API 语义不得为性能门禁而弱化。

## 验收条件

1. 在优化前提交剖析报告，明确每一层的时间、分配和调用次数；无法独立测量的
   项目须标注边界，不能用推测替代数据。
2. 新增确定性测试，证明 background fast path 与通用路径的数据、EOF、错误、
   生命周期和并发语义等价；保留 pre-cancel、Deadline、close/abort race、
   同方向并发拒绝和 exactly-once regression。
3. 使用与 M0-010 相同的公平进程形状：同一 `-O2` binary、1 次预热、
   11 个 measured rounds、交替执行顺序，覆盖 1 KiB、16 KiB、64 KiB、
   1 MiB 和 100 MiB。
4. 每个 payload 的 raw TCP 吞吐比均不低于 95%，P95 延迟比均不高于 1.10；
   `StdNetTransport.stagingCopiedBytes` 在 whole-array profile 中保持 0。
5. 保留原始样本、P50/P95/P99、read count、分配/copy、RSS、线程、环境和
   PASS/FAIL 判定，并运行 canonical `scripts/check`。
6. 若 Wirestack 内部优化不能满足门槛，本任务保持 **BLOCKED** 并记录剩余成本；
   启动 `UP-004` 仍须另行证明上游 span I/O 能解决该成本，并批准最小接口。

## 非目标

- 不专门优化带取消、Deadline、trace 或 event sink 的路径，除非剖析证明可在
  不增加竞态风险的前提下共享同一内部改进。
- 不通过减少正式 payload、轮次或统计指标来改变 GATE-NET-05 判定。
- 不以大 payload 已通过替代短操作验收。
