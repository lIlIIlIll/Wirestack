# yjson / cjfast_json

> **Legacy / unverifiable（2026-09-05 标注）**：本页是历史诊断测量，**不构成 0.1.0
> qualification 证据**。原始样本未作为仓库 artifact 发布，且缺少可复现身份：pinned
> source/SDK/CPU 身份、SDK archive checksum、完整原始样本与内容 checksum 均未随页绑定。
> 数字只反映其记录时刻的 workload 与工具链，无法从仓库内容独立复核。0.1.0 的正式性能
> 声明以 `release/0.1.0/evidence.md` 绑定的完整批次为准。

## 结果范围

37 个语义匹配 workload 中，yjson 有 29 项 paired median 更低。严格稳定性门槛下的结果为：

| Workload | Input | yjson median | cjfast_json median | yjson / peer | Direction | CV Y/C |
|:--|:--|--:|--:|--:|:--|--:|
| Encode `ArrayList<ProfileRecord>[64]` | string | 101.547 µs | 75.899 µs | 1.338x | cjfast_json 11/11 | 2.94% / 1.51% |
| Encode `UInt64Envelope` | bytes | 9.537 µs | 9.561 µs | 0.997x | mixed | 2.66% / 2.83% |
| Encode `TemporalStats` | bytes | 20.371 µs | 21.534 µs | 0.946x | yjson 11/11 | 0.85% / 2.27% |
| Encode `TemporalStats` | string | 20.879 µs | 21.824 µs | 0.957x | yjson 11/11 | 1.09% / 1.49% |
| Encode deep nested profiles | string | 94.368 µs | 74.138 µs | 1.273x | cjfast_json 11/11 | 2.03% / 2.72% |

Large Map 的独立稳定复测为 yjson 119.887 µs、cjfast_json 132.802 µs，ratio 0.903x，
配对方向为 yjson 11/11，CV 为 2.11% / 1.65%。

## 边界

`yjson / peer < 1` 表示 yjson 延迟更低。以上结论只覆盖对应 typed workload；不能推导
其他数据形态、内存占用或跨 runtime 性能。历史原始样本未作为仓库 artifact 发布，因此
本页只保留已审核的聚合结果。
