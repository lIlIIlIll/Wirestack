# 性能

yjson 的性能取决于 API、数据表示、输入形态和 workload。typed codec、`JsonNode`、
Pure Compact、Custom Native DOM 与 yyjson Direct DOM 不是等价路径，不能混为一张排名表。

## 结果摘要

### Linux release 三库全量表

rc.2 候选 `15d264c34123ff2624572d946c55c7395ccd7fe9` 的 yjson、stdx.json、
cjfast_json 同批次结果包含全部 36 个共同 workload；13 行为 `stable`，23 行为 `noisy`，
没有因 CV 超过 5% 删除任何行。见 [完整表与环境边界](results/2026-08-25-linux-rc2-three-library.md)
和 [machine-readable CSV](results/2026-08-25-linux-rc2-three-library.csv)。完整原始轮次、日志、
manifest 与 checksum 随 [rc.2 evidence](../../release/1.0.0-rc.2/evidence.md) 发布。

### yjson 与 cjfast_json

37 项同语义 workload 中，yjson 有 29 项 paired median 更低。以下是通过展示稳定性门槛的
代表行：

| Workload | yjson | cjfast_json | yjson / peer | 结论 |
| --- | ---: | ---: | ---: | --- |
| Large Map encode / string | 119.887 µs | 132.802 µs | 0.903x | yjson 更快 |
| Large Array encode / string | 101.547 µs | 75.899 µs | 1.338x | cjfast_json 更快 |
| `TemporalStats` encode / string | 20.879 µs | 21.824 µs | 0.957x | yjson 更快 |

完整稳定行见 [yjson / cjfast_json](results/2026-08-21-cjfast-json.md)。

### yjson 与 Go yyjson

该对比测量 mutable Cangjie `JsonNode` 与 Go yyjson DOM，不代表 typed codec 性能。Go
yyjson 在 Read、Write、RoundTrip 的 12 项 paired median 中均更低；稳定行的 latency
ratio 几何均值为 **5.45x**。完整表格见 [Go yyjson DOM](results/2026-08-22-go-yyjson.md)。

### Stream backend

相同 `JsonCodec<T>` 下，Small encode 的 Pure backend 延迟最低。Large decode 的配对方向
更偏向 Custom Native 与 yyjson，但波动未达到精确比例的发布门槛。详见
[typed stream backend](results/2026-08-24-stream-backends.md)。

## 如何解读

- `yjson / peer < 1` 表示 yjson 延迟更低。
- 精确比例只展示通过稳定性门槛的行；其余结果只描述方向或标记为不确定。
- 跨 runtime、不同日期或不同 workload 的数字不能拼接为统一排名。
- 延迟数据不能推导 allocation、RSS 或峰值内存。

每个 release 都必须附带 yjson、stdx.json 与 cjfast_json 的同批次完整表。高 CV 行仍然
展示，只标记为 `noisy`；稳定性门槛不会用于筛除 workload。

统计口径见[性能方法](methodology.md)，历史设计取舍见[性能研究摘要](../performance.md)。
