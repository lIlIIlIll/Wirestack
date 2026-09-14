# 2026-09-14 当前 `0.1.0` 候选三库完整对比

本页记录当前候选的 yjson、stdx.json 和 cjfast_json 共同 workload release 测量。结果绑定
runner/source-stage 提交 `774e89e577028b2daf2632c965ee35ebe49b10b4`；完整 raw samples、RSS sidecar、preflight、metadata、manifest、summary
和 checksum 位于归档路径
`benchmarks/results/release-performance/2026-09-14-774e89e/yjson-three-library-release-774e89e-r1.tar.gz`。
该归档不是 GitHub Release 上传资产。[发布证据](../../../release/0.1.0/evidence.md)记录整体 gate 状态。

本次运行先用 `cjpm bench --no-run --no-color` 完成两个 Cangjie benchmark package 的构建；随后每个 timed
sample 只执行带精确 case filter 的 `cjpm bench --skip-build`，并由 GNU `/usr/bin/time -v` 记录独立进程
peak RSS。summary 的 `RSS max KB Y/S/C` 和 raw sidecar 一一对应。完整 36 个 workload 均保留，
最大单进程记录为 `339188 kbytes`。由于只有 1 行满足三库 CV <= 5% 稳定性门槛，其余 noisy 行只保留方向和复核数据，
不作为稳定的精确性能排名。

## 结果状态

每个 workload/library 组合完成 11 个独立进程轮次；workload 顺序逐轮旋转，偶数轮反转，
三库顺序逐轮旋转。runner 为每个 library 传入 `suite.source_case` 的精确过滤条件；summary
只汇总 CSV 中 `Case == manifest.source_case` 的行，因此不会把同前缀的 `*BatchGuard` 等额外 case 混入。
完整 36 个 workload 均保留。

| 项目 | 值 |
| --- | --- |
| Candidate runner/source-stage commit | `774e89e577028b2daf2632c965ee35ebe49b10b4` |
| SDK | Cangjie STS `1.1.3`；`cjc` 输出为 `1.1.3`，`cjpm` 输出为 `1.1.3` |
| Host | `ubuntu2223131`；Linux-5.15.0-187-generic-x86_64-with-glibc2.35 |
| CPU / heap | CPU `3`；`128MB` |
| Scope | 36 workloads × 3 libraries × 11 rounds = 1188 library/workload rounds |
| Stable workloads | 1/36（all three libraries CV <= 5%） |
| Noisy workloads retained | 35/36 |
| Timing build policy | `cjpm bench --no-run` before timed `cjpm bench --skip-build` samples |
| cjfast_json commit | `eefdedd1e53c93bb5ada11a96b9b81d88b2c6c65` |
| stdx dependency | `0.0.3` |
| yjson source SHA-256 | `205157f10ae343085ff4fcb1ccc388245fbebe9036f148841aff56cae2f15de4` |
| cjfast_json source SHA-256 | `201cff8bff763b504e51e2c939bedcdab7ae6372aea69fd88d58b7f4ce6bb2cd` |
| RSS sidecar | `/usr/bin/time -v`; unit `kbytes` |
| Archive SHA-256 | `c3e3dca387bd4869c1f183fef000427dce95cb5433b07c97510a86dd69ffd490` |

## 完整汇总

Every matched workload is included. CV changes only the stable/noisy label; it never removes a row.

- Complete workloads: 36
- Stable workloads (all libraries CV <= 5.00%): 1
- Noisy workloads retained: 35

| Scenario | Operation | Payload | Input | Runs | yjson median | stdx median | cjfast median | RSS max KB Y/S/C | Y/S | Y/C | CV Y/S/C | yjson faster pairs S/C | Status |
|:--|:--|:--|:--|--:|--:|--:|--:|--:|--:|--:|--:|--:|:--|
| Pretty JSON | decode | Person | string | 11 | 7875.334 ns | 21904.254 ns | 16728.855 ns | 339112 / 339180 / 339184 | 0.356x | 0.473x | 10.62% / 9.64% / 6.69% | 11/11 / 11/11 | noisy |
| Pretty JSON | encode | Person | string | 11 | 8327.131 ns | 10827.960 ns | 10069.634 ns | 339180 / 339180 / 339176 | 0.770x | 0.831x | 4.49% / 11.51% / 13.88% | 11/11 / 9/11 | noisy |
| 基础对象 | decode | Address | bytes | 11 | 3163.173 ns | 2325.998 ns | 1979.063 ns | 339180 / 339116 / 339180 | 1.376x | 1.593x | 3.55% / 7.35% / 0.46% | 0/11 / 0/11 | noisy |
| 基础对象 | decode | Address | string | 11 | 1522.496 ns | 2482.216 ns | 2072.743 ns | 339180 / 339128 / 339108 | 0.592x | 0.720x | 6.92% / 11.03% / 10.28% | 11/11 / 11/11 | noisy |
| 基础对象 | decode | Person | bytes | 11 | 10468.978 ns | 21385.035 ns | 15442.285 ns | 339176 / 339104 / 339116 | 0.495x | 0.678x | 5.62% / 4.20% / 6.44% | 11/11 / 11/11 | noisy |
| 基础对象 | decode | Person | string | 11 | 7226.568 ns | 21792.323 ns | 15789.962 ns | 339180 / 339180 / 339180 | 0.330x | 0.450x | 15.45% / 1.09% / 6.29% | 11/11 / 11/11 | noisy |
| 基础对象 | encode | Address | bytes | 11 | 1634.310 ns | 3177.269 ns | 2459.803 ns | 339128 / 339124 / 339128 | 0.522x | 0.660x | 1.90% / 9.87% / 14.54% | 11/11 / 11/11 | noisy |
| 基础对象 | encode | Address | string | 11 | 986.889 ns | 3022.160 ns | 2994.122 ns | 339180 / 339124 / 339180 | 0.328x | 0.340x | 9.86% / 15.93% / 11.24% | 11/11 / 11/11 | noisy |
| 基础对象 | encode | Person | bytes | 11 | 4072.939 ns | 10410.763 ns | 9997.402 ns | 339136 / 339124 / 339180 | 0.386x | 0.407x | 1.04% / 14.71% / 9.88% | 11/11 / 11/11 | noisy |
| 基础对象 | encode | Person | string | 11 | 1659.106 ns | 13203.911 ns | 10767.663 ns | 339128 / 339180 / 339180 | 0.129x | 0.153x | 5.24% / 10.47% / 14.54% | 11/11 / 11/11 | noisy |
| 大 Map | decode | HashMap<String, Int64>[64] | string | 11 | 29689.600 ns | 249269.333 ns | 239495.111 ns | 339112 / 339128 / 339176 | 0.119x | 0.127x | 11.33% / 3.95% / 4.15% | 11/11 / 11/11 | noisy |
| 大 Map | encode | HashMap<String, Int64>[64] | string | 11 | 6080.561 ns | 129824.000 ns | 129962.667 ns | 339176 / 339116 / 339180 | 0.047x | 0.047x | 5.00% / 3.28% / 2.65% | 11/11 / 11/11 | noisy |
| 大数组 | decode | ArrayList<ProfileRecord>[64] | string | 11 | 107120.321 ns | 187899.482 ns | 78182.400 ns | 339176 / 339180 / 339128 | 0.559x | 1.367x | 4.71% / 5.91% / 2.50% | 11/11 / 0/11 | noisy |
| 大数组 | encode | ArrayList<ProfileRecord>[64] | string | 11 | 28672.000 ns | 101148.338 ns | 75633.778 ns | 339176 / 339124 / 339116 | 0.286x | 0.380x | 0.47% / 9.12% / 1.46% | 11/11 / 11/11 | noisy |
| 字段顺序 | decode | Person | string | 11 | 8657.518 ns | 21735.016 ns | 17845.314 ns | 339188 / 339116 / 339136 | 0.396x | 0.484x | 4.88% / 3.88% / 5.92% | 11/11 / 11/11 | noisy |
| 嵌套对象 | decode | ProfileBundle | bytes | 11 | 20520.324 ns | 22677.333 ns | 15394.682 ns | 339180 / 339188 / 339112 | 0.906x | 1.321x | 5.75% / 2.86% / 5.25% | 10/11 / 0/11 | noisy |
| 嵌套对象 | decode | ProfileBundle | string | 11 | 17463.924 ns | 22814.711 ns | 15919.642 ns | 339112 / 339176 / 339128 | 0.765x | 1.092x | 0.88% / 1.49% / 5.32% | 11/11 / 1/11 | noisy |
| 嵌套对象 | encode | ProfileBundle | bytes | 11 | 11267.132 ns | 13056.000 ns | 12778.667 ns | 339112 / 339180 / 339180 | 0.871x | 0.881x | 3.44% / 10.36% / 1.69% | 9/11 / 11/11 | noisy |
| 嵌套对象 | encode | ProfileBundle | string | 11 | 8046.545 ns | 13274.764 ns | 12567.893 ns | 339108 / 339188 / 339180 | 0.680x | 0.663x | 15.53% / 7.81% / 4.95% | 11/11 / 11/11 | noisy |
| 数值边界 | decode | UInt64Envelope | bytes | 11 | 14051.823 ns | 16896.000 ns | 12425.582 ns | 339176 / 339112 / 339176 | 0.839x | 1.133x | 2.03% / 3.77% / 5.95% | 11/11 / 0/11 | noisy |
| 数值边界 | decode | UInt64Envelope | string | 11 | 11973.441 ns | 17152.000 ns | 12076.405 ns | 339180 / 339180 / 339180 | 0.693x | 1.004x | 1.35% / 3.53% / 15.77% | 11/11 / 5/11 | noisy |
| 数值边界 | encode | UInt64Envelope | bytes | 11 | 2647.476 ns | 10154.667 ns | 9531.764 ns | 339112 / 339112 / 339176 | 0.264x | 0.277x | 6.24% / 3.48% / 2.66% | 11/11 / 11/11 | noisy |
| 数值边界 | encode | UInt64Envelope | string | 11 | 1370.797 ns | 8307.451 ns | 9794.135 ns | 339124 / 339184 / 339124 | 0.176x | 0.143x | 22.12% / 10.80% / 3.40% | 11/11 / 11/11 | noisy |
| 时间/大数 | decode | TemporalStats | bytes | 11 | 17509.744 ns | 37888.000 ns | 31060.800 ns | 339176 / 339128 / 339124 | 0.513x | 0.563x | 6.20% / 7.43% / 4.65% | 11/11 / 11/11 | noisy |
| 时间/大数 | decode | TemporalStats | string | 11 | 17513.600 ns | 38555.022 ns | 31089.507 ns | 339176 / 339184 / 339180 | 0.453x | 0.566x | 5.23% / 1.06% / 6.71% | 11/11 / 11/11 | noisy |
| 时间/大数 | encode | TemporalStats | bytes | 11 | 18907.429 ns | 22887.564 ns | 21332.423 ns | 339180 / 339128 / 339124 | 0.845x | 0.887x | 7.30% / 9.09% / 1.29% | 10/11 / 10/11 | noisy |
| 时间/大数 | encode | TemporalStats | string | 11 | 18560.000 ns | 22990.400 ns | 21744.552 ns | 339116 / 339176 / 339124 | 0.805x | 0.853x | 4.32% / 1.48% / 1.67% | 11/11 / 11/11 | stable |
| 未知字段 | decode | Person | string | 11 | 11054.277 ns | 22837.060 ns | 16998.140 ns | 339124 / 339112 / 339180 | 0.538x | 0.653x | 7.28% / 12.74% / 6.91% | 11/11 / 11/11 | noisy |
| 流式 I/O | decode | Person | stream | 11 | 36933.818 ns | 21490.759 ns | 15312.262 ns | 339180 / 339120 / 339108 | 1.731x | 2.303x | 5.72% / 3.37% / 4.35% | 0/11 / 0/11 | noisy |
| 流式 I/O | encode | Person | stream | 11 | 5890.305 ns | 11886.050 ns | 10035.090 ns | 339108 / 339128 / 339176 | 0.494x | 0.603x | 11.53% / 12.09% / 6.92% | 11/11 / 11/11 | noisy |
| 深层嵌套 | decode | ArrayList<HashMap<String, ArrayList<ProfileRecord>>> | string | 11 | 299207.529 ns | 166350.748 ns | 96000.000 ns | 339176 / 339116 / 339180 | 1.816x | 3.117x | 7.99% / 4.02% / 0.86% | 0/11 / 0/11 | noisy |
| 深层嵌套 | encode | ArrayList<HashMap<String, ArrayList<ProfileRecord>>> | string | 11 | 46165.333 ns | 82533.218 ns | 73625.600 ns | 339180 / 339180 / 339128 | 0.604x | 0.626x | 15.37% / 11.88% / 0.30% | 11/11 / 11/11 | noisy |
| 转义/Unicode | decode | String | bytes | 11 | 4741.428 ns | 2265.376 ns | 1817.180 ns | 339128 / 339124 / 339176 | 2.101x | 2.609x | 7.23% / 7.98% / 0.39% | 0/11 / 0/11 | noisy |
| 转义/Unicode | decode | String | string | 11 | 4858.717 ns | 2433.344 ns | 2373.548 ns | 339152 / 339180 / 339176 | 1.999x | 1.997x | 6.94% / 3.58% / 8.44% | 0/11 / 0/11 | noisy |
| 转义/Unicode | encode | String | bytes | 11 | 1723.601 ns | 2689.809 ns | 2454.512 ns | 339116 / 339116 / 339180 | 0.630x | 0.697x | 11.97% / 9.83% / 2.07% | 11/11 / 11/11 | noisy |
| 转义/Unicode | encode | String | string | 11 | 1824.778 ns | 3287.646 ns | 3254.660 ns | 339128 / 339180 / 339180 | 0.585x | 0.599x | 5.42% / 7.02% / 11.76% | 11/11 / 11/11 | noisy |

## 复核

在归档解压目录执行 `sha256sum -c checksums.txt`，再用仓库中的
`scripts/json_cjfast_perf_summary.py --min-runs 11 --cv-limit 5` 重新汇总 `run/`。
summary loader 要求每条 manifest 的 `source_case` 与 CSV `Case` 完全相等；前缀相同的其他 benchmark case
不会进入统计。`build-yjson.log` 和 `build-cjfast_json.log` 保留未计时的 `cjpm bench --no-run` 构建输出；
每个 timed RSS sidecar 对应 `--skip-build` 进程。归档、summary、manifest、metadata、preflight 和 RSS
sidecar 均保留供复核。
