# Typed stream backend

> **Legacy / unverifiable（2026-09-05 标注）**：本页是历史诊断测量，**不构成 0.1.0
> qualification 证据**。原始样本未作为仓库 artifact 发布，且缺少可复现身份：pinned
> source/SDK/CPU 身份、SDK archive checksum、完整原始样本与内容 checksum 均未随页绑定。
> 数字只反映其记录时刻的 workload 与工具链，无法从仓库内容独立复核。0.1.0 的正式性能
> 声明以 `release/0.1.0/evidence.md` 绑定的完整批次为准。

## Workload

本测量比较同一 `JsonCodec<T>` 的 Pure、Custom Native 与 yyjson stream backend：

| Label | Typed value | JSON size |
| --- | --- | ---: |
| Small | 四字段 `HashMap<String, String>` | 80 B |
| Large | 512 个四字段 Map 组成的数组 | 56,101 B |

Encode 包含 stream 创建、typed encode、backend finalization 和 byte array 输出。Decode
读取相同 JSON 并物化完整 typed value。它不比较 DOM、framing、RSS 或 allocation。

## 结果

| Workload | Backend | Median | p95 | CV | Backend/Pure | Faster pairs | Status |
|:--|:--|--:|--:|--:|--:|--:|:--|
| Small encode | Pure | 11.420 µs | 12.375 µs | 4.14% | 1.000x | — | stable |
| Small encode | Custom Native | 13.700 µs | 14.110 µs | 4.96% | 1.200x | 0/11 | stable |
| Small encode | yyjson | 13.500 µs | 14.205 µs | 4.55% | 1.182x | 0/11 | stable |
| Small decode | Pure | 14.620 µs | 15.010 µs | 3.73% | 1.000x | — | stable baseline |
| Small decode | Custom Native | 18.100 µs | 18.725 µs | 10.94% | 1.238x | 2/11 | noisy |
| Small decode | yyjson | 17.840 µs | 19.650 µs | 5.14% | 1.220x | 0/11 | noisy |
| Large encode | Pure | 2.628 ms | 2.931 ms | 7.13% | 1.000x | — | noisy |
| Large encode | Custom Native | 3.110 ms | 3.417 ms | 7.71% | 1.183x | 0/11 | noisy |
| Large encode | yyjson | 2.922 ms | 3.144 ms | 5.05% | 1.112x | 2/11 | noisy |
| Large decode | Pure | 4.361 ms | 4.641 ms | 8.32% | 1.000x | — | noisy |
| Large decode | Custom Native | 3.665 ms | 4.215 ms | 8.16% | 0.840x | 10/11 | noisy |
| Large decode | yyjson | 3.537 ms | 3.828 ms | 6.70% | 0.811x | 10/11 | noisy |

Small encode 是唯一三个 backend 都通过 CV ≤ 5% 的 operation group，Pure 延迟最低。
Large decode 在 10/11 配对轮次中偏向两个 Native backend，但波动超出门槛，因此不发布
观察比例为精确结论。历史 harness 与原始样本未作为仓库 artifact 发布。
