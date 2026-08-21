# 2026-08-21 yjson / cjfast_json result

## Identity and environment

- yjson: `6f2f47c597d4e5141b1efbfaa9cba8e5242e94d3`
- cjfast_json: `eefdedd1e53c93bb5ada11a96b9b81d88b2c6c65`
- CPU: Intel Xeon Gold 6248R, pinned logical CPU 8
- SDK: `1.1.0-alpha.20260803040049`
- Cangjie: `-O2`, `cjHeapSize=128MB`
- execution: separate process, 11 rounds, rotated/reversed workload order, alternating library order

## Result boundary

37 个语义匹配 workload 中，yjson 有 29 项 paired median 更低，25 项为 yjson faster
11/11；cjfast_json 有 5 项一致方向。严格两侧 CV ≤ 3% gate 只有五行通过：

| Workload | Input | yjson median | cjfast_json median | Paired delta | Direction | CV Y/C |
|:--|:--|--:|--:|--:|:--|--:|
| Encode `ArrayList<ProfileRecord>[64]` | string | 101.547 µs | 75.899 µs | -25.24% | cjfast_json faster 11/11 | 2.94% / 1.51% |
| Encode `UInt64Envelope` | bytes | 9.537 µs | 9.561 µs | -0.34% | mixed, yjson faster 4/11 | 2.66% / 2.83% |
| Encode `TemporalStats` | bytes | 20.371 µs | 21.534 µs | +5.10% | yjson faster 11/11 | 0.85% / 2.27% |
| Encode `TemporalStats` | string | 20.879 µs | 21.824 µs | +3.65% | yjson faster 11/11 | 1.09% / 1.49% |
| Encode deep nested profiles | string | 94.368 µs | 74.138 µs | -22.45% | cjfast_json faster 11/11 | 2.03% / 2.72% |

Positive paired delta 表示 cjfast_json 更慢。Large Map focused rerun 为 yjson 119.887 µs、
cjfast_json 132.802 µs、yjson faster 11/11、CV 2.11% / 1.65%。

## Limitations and artifacts

one-minute load 为 3.432–7.111/96 logical CPUs；affinity 固定，但 host load 与 frequency
未隔离。原记录声称 814 raw reports、814 process logs、manifest 与 summary 保存在
Server `<home>/...` 和本地 ignored `target/...`。这些路径没有作为本仓库 immutable
artifact 提交，因此外部读者当前不能仅从 checkout 审计原始样本。

完整 follow-up、profiling 与 rejected evidence 见 [research log](../../performance.md)。
