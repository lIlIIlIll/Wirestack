# 2026-09-14 当前 `0.1.0` 候选三库完整对比

本页记录当前候选的 yjson、stdx.json 和 cjfast_json 共同 workload release 测量。结果绑定 runner/source-stage 提交 `4c2432c80688581dd28afa8bc4a7ec0bdf4858cf`；完整 raw samples、RSS sidecar、preflight、metadata、manifest、summary 和 checksum 位于归档路径
`benchmarks/results/release-performance/2026-09-14-4c2432c/yjson-three-library-release-4c2432c-r1.tar.gz`。该归档不是 GitHub Release 上传资产。[发布证据](../../../release/0.1.0/evidence.md)记录整体 gate 状态。

本次运行先用 `cjpm bench --no-run --no-color` 完成两个 Cangjie benchmark package 的构建；随后每个 timed sample 只执行带精确 case filter 的预构建 benchmark executable，并由 GNU `/usr/bin/time -v` 记录独立进程 peak RSS。summary 的 `RSS max KB Y/S/C` 和 raw sidecar 一一对应。完整 36 个 workload 均保留，最大单进程记录为 `195396 kbytes`。稳定性门槛为三库 CV 均不超过 5%；7 行 stable，29 行 noisy，noisy 行不作为稳定的精确性能排名。

## 结果状态

每个 workload/library 组合完成 11 个独立进程轮次；workload 顺序逐轮旋转，偶数轮反转，三库顺序逐轮旋转。runner 为每个 library 传入精确 fully-qualified case filter；summary 只汇总 CSV 中 `Case == manifest.source_case` 的行，因此不会把同前缀的其他 benchmark case 混入。

| 项目 | 值 |
| --- | --- |
| Candidate runner/source-stage commit | `4c2432c80688581dd28afa8bc4a7ec0bdf4858cf` |
| SDK | Cangjie STS `1.1.3`；`cjc` 输出为 `1.1.3`，`cjpm` 输出为 `1.1.3` |
| Host | `ubuntu2223131`；Linux-5.15.0-187-generic-x86_64-with-glibc2.35 |
| CPU / heap | CPU `3`；`128MB` |
| Scope | 36 workloads × 3 libraries × 11 rounds = 1188 library/workload rounds |
| Stable workloads | 7/36（all three libraries CV <= 5%） |
| Noisy workloads retained | 29/36 |
| Timing build policy | `cjpm bench --no-run` before timed samples; GNU time wraps only prebuilt benchmark executables |
| cjfast_json commit | `eefdedd1e53c93bb5ada11a96b9b81d88b2c6c65` |
| stdx dependency | `0.0.3` |
| yjson source SHA-256 | `b15a8c4e6bc7a8f84986bc276a0c6b34616705eda6d48574b8958047562d4b71` |
| cjfast_json source SHA-256 | `201cff8bff763b504e51e2c939bedcdab7ae6372aea69fd88d58b7f4ce6bb2cd` |
| RSS sidecar | `/usr/bin/time -v`; unit `kbytes`; max timed process `195396` |
| Archive SHA-256 | `66aa76fd5fa99058307c3e4d34f031cde1e96045ea58b2ff70c2c626e610482b` |

## 完整汇总

Every matched workload is included. CV changes only the stable/noisy label; it never removes a row.

- Complete workloads: 36
- Stable workloads (all libraries CV <= 5.00%): 7
- Noisy workloads retained: 29

| Scenario | Operation | Payload | Input | Runs | yjson median | stdx median | cjfast median | RSS max KB Y/S/C | Y/S | Y/C | CV Y/S/C | yjson faster pairs S/C | Status |
|:--|:--|:--|:--|--:|--:|--:|--:|--:|--:|--:|--:|--:|:--|
| Pretty JSON | decode | Person | string | 11 | 9149.986 ns | 19795.200 ns | 16517.036 ns | 192384 / 192260 / 164096 | 0.459x | 0.524x | 4.34% / 8.36% / 5.26% | 11/11 / 11/11 | noisy |
| Pretty JSON | encode | Person | string | 11 | 8038.857 ns | 14088.930 ns | 10701.266 ns | 192400 / 192516 / 163356 | 0.571x | 0.753x | 0.58% / 0.48% / 8.11% | 11/11 / 11/11 | noisy |
| 基础对象 | decode | Address | bytes | 11 | 2980.744 ns | 2254.613 ns | 1975.538 ns | 192196 / 193068 / 164128 | 1.342x | 1.491x | 6.87% / 7.91% / 1.02% | 0/11 / 0/11 | noisy |
| 基础对象 | decode | Address | string | 11 | 1283.783 ns | 2391.598 ns | 2025.275 ns | 192452 / 193160 / 164244 | 0.590x | 0.633x | 16.21% / 9.48% / 0.69% | 11/11 / 11/11 | noisy |
| 基础对象 | decode | Person | bytes | 11 | 9096.889 ns | 19232.000 ns | 15249.540 ns | 192544 / 192456 / 163864 | 0.472x | 0.598x | 2.52% / 4.06% / 4.22% | 11/11 / 11/11 | stable |
| 基础对象 | decode | Person | string | 11 | 7939.627 ns | 19427.467 ns | 15314.515 ns | 192000 / 192252 / 163484 | 0.383x | 0.504x | 4.99% / 5.24% / 2.16% | 11/11 / 11/11 | noisy |
| 基础对象 | encode | Address | bytes | 11 | 1427.102 ns | 1646.933 ns | 2463.208 ns | 192408 / 195164 / 166208 | 0.819x | 0.565x | 17.92% / 19.69% / 7.97% | 8/11 / 11/11 | noisy |
| 基础对象 | encode | Address | string | 11 | 846.091 ns | 2039.225 ns | 2440.945 ns | 192292 / 195136 / 166428 | 0.425x | 0.348x | 4.13% / 26.36% / 6.94% | 11/11 / 11/11 | noisy |
| 基础对象 | encode | Person | bytes | 11 | 3556.048 ns | 10916.185 ns | 9768.755 ns | 192552 / 193468 / 163472 | 0.330x | 0.364x | 5.04% / 5.62% / 4.52% | 11/11 / 11/11 | noisy |
| 基础对象 | encode | Person | string | 11 | 1547.801 ns | 10238.696 ns | 9977.320 ns | 192456 / 192804 / 163696 | 0.152x | 0.155x | 5.87% / 4.26% / 9.53% | 11/11 / 11/11 | noisy |
| 大 Map | decode | HashMap<String, Int64>[64] | string | 11 | 26827.228 ns | 239360.000 ns | 224154.667 ns | 192396 / 191896 / 162384 | 0.112x | 0.119x | 1.17% / 2.96% / 3.79% | 11/11 / 11/11 | stable |
| 大 Map | encode | HashMap<String, Int64>[64] | string | 11 | 6712.377 ns | 122837.333 ns | 128907.636 ns | 193336 / 193052 / 163592 | 0.055x | 0.052x | 5.50% / 2.13% / 2.61% | 11/11 / 11/11 | noisy |
| 大数组 | decode | ArrayList<ProfileRecord>[64] | string | 11 | 88303.610 ns | 178234.261 ns | 78236.444 ns | 192400 / 191740 / 163364 | 0.465x | 1.129x | 10.66% / 5.54% / 0.27% | 11/11 / 2/11 | noisy |
| 大数组 | encode | ArrayList<ProfileRecord>[64] | string | 11 | 26043.077 ns | 86998.817 ns | 75596.800 ns | 192452 / 193220 / 164144 | 0.303x | 0.346x | 0.90% / 5.46% / 0.68% | 11/11 / 11/11 | noisy |
| 字段顺序 | decode | Person | string | 11 | 8777.697 ns | 19609.257 ns | 16853.255 ns | 193188 / 192600 / 163868 | 0.448x | 0.502x | 4.42% / 1.60% / 5.76% | 11/11 / 11/11 | noisy |
| 嵌套对象 | decode | ProfileBundle | bytes | 11 | 18865.455 ns | 20136.812 ns | 15673.440 ns | 192484 / 192384 / 163588 | 0.934x | 1.220x | 2.15% / 4.82% / 4.49% | 10/11 / 0/11 | stable |
| 嵌套对象 | decode | ProfileBundle | string | 11 | 16216.850 ns | 20740.923 ns | 15422.482 ns | 192436 / 192512 / 163340 | 0.786x | 1.047x | 4.08% / 5.19% / 4.95% | 11/11 / 2/11 | noisy |
| 嵌套对象 | encode | ProfileBundle | bytes | 11 | 9536.000 ns | 13368.846 ns | 12463.782 ns | 192396 / 192624 / 164048 | 0.716x | 0.766x | 1.03% / 0.95% / 2.73% | 11/11 / 11/11 | stable |
| 嵌套对象 | encode | ProfileBundle | string | 11 | 7282.125 ns | 13358.118 ns | 12318.636 ns | 192328 / 192848 / 164392 | 0.552x | 0.591x | 0.90% / 10.43% / 3.45% | 11/11 / 11/11 | noisy |
| 数值边界 | decode | UInt64Envelope | bytes | 11 | 12532.364 ns | 16650.424 ns | 11918.842 ns | 192392 / 192576 / 163708 | 0.804x | 1.048x | 3.06% / 4.62% / 3.84% | 11/11 / 2/11 | stable |
| 数值边界 | decode | UInt64Envelope | string | 11 | 10858.667 ns | 15657.400 ns | 10455.805 ns | 192504 / 192628 / 164576 | 0.674x | 1.029x | 2.66% / 5.65% / 15.07% | 11/11 / 4/11 | noisy |
| 数值边界 | encode | UInt64Envelope | bytes | 11 | 2311.960 ns | 9834.667 ns | 9390.358 ns | 192376 / 192760 / 163504 | 0.239x | 0.247x | 8.17% / 2.83% / 0.96% | 11/11 / 11/11 | noisy |
| 数值边界 | encode | UInt64Envelope | string | 11 | 1270.531 ns | 10414.769 ns | 9534.544 ns | 191952 / 193108 / 163260 | 0.121x | 0.136x | 3.52% / 1.15% / 6.63% | 11/11 / 11/11 | noisy |
| 时间/大数 | decode | TemporalStats | bytes | 11 | 15538.526 ns | 37977.600 ns | 30728.440 ns | 192192 / 192556 / 163860 | 0.408x | 0.504x | 2.24% / 2.98% / 5.99% | 11/11 / 11/11 | noisy |
| 时间/大数 | decode | TemporalStats | string | 11 | 15292.846 ns | 38616.000 ns | 30879.446 ns | 192472 / 193400 / 163692 | 0.398x | 0.488x | 0.88% / 5.07% / 5.95% | 11/11 / 11/11 | noisy |
| 时间/大数 | encode | TemporalStats | bytes | 11 | 16421.147 ns | 22731.307 ns | 21472.000 ns | 192416 / 193040 / 163856 | 0.726x | 0.763x | 1.37% / 5.71% / 1.56% | 11/11 / 11/11 | noisy |
| 时间/大数 | encode | TemporalStats | string | 11 | 16288.000 ns | 23182.431 ns | 21440.350 ns | 192372 / 192712 / 163776 | 0.706x | 0.762x | 1.48% / 5.82% / 1.63% | 11/11 / 11/11 | noisy |
| 未知字段 | decode | Person | string | 11 | 10275.200 ns | 20645.264 ns | 17043.376 ns | 192344 / 192500 / 164128 | 0.492x | 0.603x | 3.03% / 6.03% / 3.87% | 11/11 / 11/11 | noisy |
| 流式 I/O | decode | Person | stream | 11 | 32860.444 ns | 19184.000 ns | 15305.378 ns | 193516 / 192828 / 163656 | 1.711x | 2.124x | 0.57% / 4.05% / 4.21% | 0/11 / 0/11 | stable |
| 流式 I/O | encode | Person | stream | 11 | 5718.890 ns | 11051.311 ns | 9795.844 ns | 192656 / 193076 / 163740 | 0.519x | 0.582x | 5.03% / 15.25% / 10.40% | 11/11 / 11/11 | noisy |
| 深层嵌套 | decode | ArrayList<HashMap<String, ArrayList<ProfileRecord>>> | string | 11 | 326560.000 ns | 156520.583 ns | 95866.667 ns | 191644 / 191980 / 163504 | 2.091x | 3.399x | 2.04% / 6.57% / 0.37% | 0/11 / 0/11 | noisy |
| 深层嵌套 | encode | ArrayList<HashMap<String, ArrayList<ProfileRecord>>> | string | 11 | 43840.000 ns | 74359.467 ns | 73764.571 ns | 192340 / 192732 / 163528 | 0.584x | 0.594x | 1.12% / 4.63% / 0.60% | 11/11 / 11/11 | stable |
| 转义/Unicode | decode | String | bytes | 11 | 4502.400 ns | 2033.503 ns | 1835.823 ns | 192068 / 193620 / 166228 | 2.129x | 2.448x | 5.82% / 14.53% / 1.05% | 0/11 / 0/11 | noisy |
| 转义/Unicode | decode | String | string | 11 | 4380.768 ns | 2250.561 ns | 2345.367 ns | 192220 / 193720 / 163916 | 1.928x | 1.867x | 4.74% / 8.30% / 0.72% | 0/11 / 0/11 | noisy |
| 转义/Unicode | encode | String | bytes | 11 | 1522.017 ns | 1276.232 ns | 2458.160 ns | 192672 / 195348 / 166192 | 1.084x | 0.595x | 5.78% / 38.82% / 8.93% | 5/11 / 11/11 | noisy |
| 转义/Unicode | encode | String | string | 11 | 1581.426 ns | 2108.496 ns | 3237.751 ns | 192248 / 195396 / 166080 | 0.744x | 0.490x | 1.56% / 25.36% / 4.54% | 9/11 / 11/11 | noisy |

复核时在归档解压目录执行归档内 `checksums.txt` 对应的校验，再用仓库中的 `scripts/json_cjfast_perf_summary.py --min-runs 11 --cv-limit 5` 重新汇总 `run/`。所有 matched workload、summary、manifest、preflight 和 RSS sidecar 均保留；构建日志未纳入 timed RSS。

