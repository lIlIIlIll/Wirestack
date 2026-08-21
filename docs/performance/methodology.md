# Performance methodology

## Claim scope

每项结论必须记录 library/backend、API/representation、operation、payload、String/bytes/
stream 输入形态和语义差异。跨 runtime 数字只能作为 context，不能直接声明产品总排名。

## Environment

公开结果至少固定并记录：

- yjson 与对比库 commit；
- Cangjie SDK/JDK、compiler flags、heap configuration；
- CPU 型号、logical CPU affinity、OS/libc；
- host load 与已知共享机器干扰；
- corpus/fixture revision；
- runner/analyzer revision。

## Execution

- 每个 workload/library 以独立进程运行；
- baseline/candidate 使用 paired、interleaved order，轮次反转以降低顺序偏差；
- 先 warmup，再保留每轮 raw batch；
- 正式 yjson/cjfast_json snapshot 使用 11 rounds；
- 不从一次本地 quick run 生成 README claim。

## Acceptance

方向计数与精确 ratio 分开报告：

- 全仓库 latency ratio 统一为 `yjson median / peer median`；小于 1 表示 yjson 更快；
- paired median 和 11/11 direction 可作为方向证据；
- 精确绝对延迟比较要求两侧 process-median CV ≤ 3%；
- README 代表表允许两侧 CV ≤ 5%，必须显示绝对时间并注明它是较宽的展示门槛；
- 同时检查 p95、CV、MAD 和异常轮次；门槛失败时只报告 inconclusive 或方向性结果；
- latency 不得推导 allocation、RSS 或峰值内存。

## Artifacts

可审计结果应提交 immutable directory，至少包含 `manifest.json`、`environment.json`、
raw/paired summary、CSV schema 和 checksums。仅存在开发机绝对路径的 log 不算公开 artifact。
