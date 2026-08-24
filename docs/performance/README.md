# Performance

yjson 的性能结论必须限定 backend、representation、workload 与输入形态。typed codec、
`JsonNode`、Pure Compact、Custom Native DOM 与 yyjson Direct DOM 不能互换比较。

## 当前可公开摘要

2026-08-21 的同 runtime、同 SDK、CPU-pinned yjson/cjfast_json 测量覆盖 37 个语义匹配
workload：yjson 在 29 项 paired median 更低，其中 25 项在 11/11 pair 中方向一致；
cjfast_json 有 5 项方向一致。这个计数是方向证据，不是每一行都达到稳定绝对 ratio 的证据。

README 只选取五个两侧 CV ≤ 5% 的代表 workload，并同时展示 yjson 的领先与落后。严格
绝对延迟 gate 使用两侧 process-median CV ≤ 3%，完整 37-workload run 只有五行通过；
Large Map 的稳定数字来自同环境独立 focused rerun。

| Workload | yjson | cjfast_json | Latency ratio Y/C | Direction |
| --- | ---: | ---: | ---: | --- |
| Large Map encode / string | 119.887 µs | 132.802 µs | 0.903x | yjson faster 11/11 |
| Large Array encode / string | 101.547 µs | 75.899 µs | 1.338x | cjfast_json faster 11/11 |
| `TemporalStats` encode / string | 20.879 µs | 21.824 µs | 0.957x | yjson faster 11/11 |

所有性能页面的 latency ratio 均按 `yjson median / peer median` 计算；小于 1 表示
yjson 耗时更低。`Direction` 单独记录配对轮次的一致性，不再用反向 delta 表示。

绝对时间只代表 Intel Xeon Gold 6248R、CPU 8、对应 SDK/commit 的快照。完整 commit、环境、
表格与 follow-up 见 [2026-08-21 result](results/2026-08-21-cjfast-json.md)。

2026-08-22 另行测量了 yjson `JsonNode` 与纯 Go `dwisiswant0/yyjson` DOM。相同 fixture、
11 轮交替顺序下，Go yyjson 在 Read、Write、RoundTrip 的 12 项 paired median 中全部较低；
11 个两侧 CV ≤ 5% 的稳定行，其 `yjson / Go yyjson` latency ratio 几何均值为 5.45x。
16 MiB Read 的 yjson CV 为 9.60%，因此该行只提供方向证据。完整身份、表格和限制见
[2026-08-22 Go yyjson result](results/2026-08-22-go-yyjson.md)。

2026-08-24 对同一个 `JsonCodec<T>` 的 Pure、Custom Native 与 yyjson typed stream backend
进行了 11 轮、132 独立进程的 CPU-pinned 对比。80 B Small encode 是唯一三侧都通过
CV ≤ 5% 的 operation group：Pure 为 11.420 µs，Custom Native 为 13.700 µs，yyjson
为 13.500 µs。56,101 B Large decode 中 Native/yyjson 均有 10/11 pair 快于 Pure，但
三侧 CV 为 6.70%–8.32%，所以只保留方向，不发布观察到的比例为精确 claim。Large
workload 是 `Array<HashMap<String,String>>[512]`，不是 cjfast_json 对比中的单个 Large
Map。完整 contract、表格、环境 workaround 与 artifact 边界见
[2026-08-24 typed stream backend result](results/2026-08-24-stream-backends.md)。

## 其他库

功能覆盖范围另见[库能力对比](../library-comparison.md)。能力矩阵不代表性能排名，也不能
用于拼接下面这些不同日期、runtime 与 benchmark batch 的数据。

stdx.json 与 Java fastjson2 数据来自 2026-08-20 的另一批测量；cjfast_json 来自
2026-08-21。Java/Cangjie 也不是同 runtime。这些数据只提供 workload context，不能形成
同步四库排名。Go yyjson 同样是独立的跨 runtime DOM 测量，不应与这些批次拼接排名。
原四库表保留在 [research log](../performance.md#cross-library-workload-context-2026-08-2021)。

## 复现与证据状态

- [Methodology](methodology.md)：公开 claim 的测量与接受门槛。
- [Benchmark guide](../../benchmarks/README.md)：adapter、依赖、命令、输出 schema。
- [Research log](../performance.md)：JSON literal、fast decoder、profiling 与 rejected experiment。

历史原始报告目前主要保存在 ignored target 目录或特定 Server 路径，没有全部提交为仓库
artifact。当前公开内容只包括摘要、稳定行、方法与实验限制；完整历史 raw samples、p95、
MAD 和 machine-readable summaries 尚未全部随仓库发布。因此这里区分“脚本可运行”和
“历史结果可外部审计”；后者尚未完全满足。
