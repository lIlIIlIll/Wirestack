# 2026-09-14 当前 `0.1.0` 候选三库完整对比

本页记录当前候选的 yjson、stdx.json 和 cjfast_json 共同 workload release 测量。结果绑定提交
`7436598b6cd22084ea990832b07d972aeae26e1b`；完整 raw samples、RSS sidecar、preflight、metadata、manifest、summary
和 checksum 位于归档路径
`benchmarks/results/release-performance/2026-09-14-7436598/yjson-three-library-release-7436598-r1.tar.gz`。
该归档不是 GitHub Release 上传资产。[发布证据](../../../release/0.1.0/evidence.md)记录整体 gate 状态。

本次运行使用 GNU `/usr/bin/time -v` 为每个独立进程记录 peak RSS；summary 的 `RSS max KB Y/S/C`
和 raw sidecar 一一对应。完整 36 个 workload 均保留，最大单进程记录为 `1049728 kbytes`。
CV 超过 5% 的行标记为 noisy；noisy 行只保留方向和复核数据，不作为稳定的精确性能排名。

## 结果状态

每个 workload/library 组合完成 11 个独立进程轮次；workload 顺序逐轮旋转，偶数轮反转，
三库顺序逐轮旋转。完整 36 个 workload 均保留。

| 项目 | 值 |
| --- | --- |
| Candidate | `7436598b6cd22084ea990832b07d972aeae26e1b` |
| Candidate measured tree | `00d9629474c5b5a850bc427aca6f84046dc7ffd5` |
| SDK | Cangjie STS `1.1.3`；`cjc` 输出为 `1.1.3`，`cjpm` 输出为 `1.1.3` |
| Host | `ubuntu2223131`；Linux-5.15.0-187-generic-x86_64-with-glibc2.35 |
| CPU / heap | CPU `3`；`128MB` |
| Scope | 36 workloads × 3 libraries × 11 rounds = 1188 library/workload rounds |
| Stable workloads | 0/36（all three libraries CV <= 5%） |
| Noisy workloads retained | 36/36 |
| cjfast_json commit | `eefdedd1e53c93bb5ada11a96b9b81d88b2c6c65` |
| stdx dependency | `0.0.3` |
| yjson source SHA-256 | `4ea46d335b16dae81addeecc76e1b46406cd58531cdd8d0b01357cade9990c2a` |
| cjfast_json source SHA-256 | `201cff8bff763b504e51e2c939bedcdab7ae6372aea69fd88d58b7f4ce6bb2cd` |
| RSS sidecar | `/usr/bin/time -v`; unit `kbytes` |
| Archive SHA-256 | `2233f1b9be0339e99886703a3684d14dd0a8d641cc80639250c3d3af404a0eef` |

`00d9629474c5b5a850bc427aca6f84046dc7ffd5` 是提交 `7436598b6cd22084ea990832b07d972aeae26e1b` 的 measured source tree；
当前七库 marker 另以 candidate identity 绑定 release graph、root manifest、root lock 和九包 lockstep manifests。

## 完整汇总


Every matched workload is included. CV changes only the stable/noisy label; it never removes a row.

- Complete workloads: 36
- Stable workloads (all libraries CV <= 5.00%): 0
- Noisy workloads retained: 36

| Scenario | Operation | Payload | Input | Runs | yjson median | stdx median | cjfast median | RSS max KB Y/S/C | Y/S | Y/C | CV Y/S/C | yjson faster pairs S/C | Status |
|:--|:--|:--|:--|--:|--:|--:|--:|--:|--:|--:|--:|--:|:--|
| Pretty JSON | decode | Person | string | 11 | 14202.243 ns | 22081.017 ns | 15875.787 ns | 550440 / 339180 / 1049728 | 0.642x | 0.891x | 4.96% / 9.91% / 5.18% | 11/11 / 11/11 | noisy |
| Pretty JSON | encode | Person | string | 11 | 8767.330 ns | 13138.949 ns | 10383.828 ns | 339180 / 339180 / 339124 | 0.674x | 0.872x | 17.18% / 7.36% / 11.34% | 11/11 / 10/11 | noisy |
| 基础对象 | decode | Address | bytes | 11 | 3507.635 ns | 2228.178 ns | 2018.331 ns | 339176 / 339128 / 339128 | 1.594x | 1.738x | 8.70% / 4.55% / 8.61% | 0/11 / 0/11 | noisy |
| 基础对象 | decode | Address | string | 11 | 1551.529 ns | 2419.068 ns | 2009.160 ns | 339128 / 339112 / 339176 | 0.635x | 0.758x | 6.82% / 5.28% / 4.78% | 11/11 / 11/11 | noisy |
| 基础对象 | decode | Person | bytes | 11 | 17905.718 ns | 21243.367 ns | 14867.075 ns | 339128 / 339148 / 339128 | 0.870x | 1.238x | 6.35% / 5.88% / 1.80% | 10/11 / 0/11 | noisy |
| 基础对象 | decode | Person | string | 11 | 16053.850 ns | 19070.836 ns | 14875.313 ns | 339128 / 339180 / 339176 | 0.851x | 1.144x | 7.15% / 13.44% / 8.13% | 10/11 / 3/11 | noisy |
| 基础对象 | encode | Address | bytes | 11 | 1703.650 ns | 2879.718 ns | 2992.333 ns | 339176 / 339116 / 339124 | 0.566x | 0.570x | 13.70% / 5.78% / 0.62% | 11/11 / 11/11 | noisy |
| 基础对象 | encode | Address | string | 11 | 1262.723 ns | 3293.544 ns | 2982.583 ns | 339180 / 339176 / 339180 | 0.383x | 0.416x | 15.63% / 7.16% / 5.16% | 11/11 / 11/11 | noisy |
| 基础对象 | encode | Person | bytes | 11 | 4401.520 ns | 10373.062 ns | 10669.970 ns | 339108 / 339128 / 339180 | 0.389x | 0.407x | 8.91% / 9.78% / 7.75% | 11/11 / 11/11 | noisy |
| 基础对象 | encode | Person | string | 11 | 3045.373 ns | 12393.995 ns | 11834.116 ns | 339176 / 339180 / 339116 | 0.244x | 0.251x | 13.66% / 8.43% / 8.64% | 11/11 / 11/11 | noisy |
| 大 Map | decode | HashMap<String, Int64>[64] | string | 11 | 36079.130 ns | 313001.016 ns | 209590.519 ns | 339128 / 339108 / 339180 | 0.111x | 0.162x | 14.93% / 4.60% / 9.48% | 11/11 / 11/11 | noisy |
| 大 Map | encode | HashMap<String, Int64>[64] | string | 11 | 6685.867 ns | 149429.938 ns | 118107.455 ns | 339180 / 339128 / 339116 | 0.045x | 0.057x | 7.98% / 6.94% / 7.84% | 11/11 / 11/11 | noisy |
| 大数组 | decode | ArrayList<ProfileRecord>[64] | string | 11 | 126022.697 ns | 209535.546 ns | 87502.012 ns | 339180 / 339120 / 339128 | 0.588x | 1.467x | 4.57% / 7.26% / 7.98% | 11/11 / 0/11 | noisy |
| 大数组 | encode | ArrayList<ProfileRecord>[64] | string | 11 | 30294.131 ns | 121544.145 ns | 75929.600 ns | 339184 / 339124 / 339180 | 0.254x | 0.389x | 19.13% / 6.86% / 6.70% | 11/11 / 11/11 | noisy |
| 字段顺序 | decode | Person | string | 11 | 13724.374 ns | 21452.972 ns | 15356.073 ns | 339180 / 339112 / 339124 | 0.621x | 0.889x | 5.17% / 12.38% / 7.88% | 11/11 / 10/11 | noisy |
| 嵌套对象 | decode | ProfileBundle | bytes | 11 | 22236.505 ns | 22081.284 ns | 15279.306 ns | 339180 / 339180 / 339108 | 1.007x | 1.349x | 9.83% / 8.45% / 5.99% | 5/11 / 0/11 | noisy |
| 嵌套对象 | decode | ProfileBundle | string | 11 | 19786.161 ns | 22443.469 ns | 15216.461 ns | 339128 / 339176 / 339180 | 0.928x | 1.300x | 6.83% / 7.62% / 2.26% | 10/11 / 0/11 | noisy |
| 嵌套对象 | encode | ProfileBundle | bytes | 11 | 11825.634 ns | 9990.675 ns | 10789.172 ns | 339180 / 339108 / 339180 | 1.177x | 1.086x | 13.10% / 10.91% / 7.77% | 4/11 / 4/11 | noisy |
| 嵌套对象 | encode | ProfileBundle | string | 11 | 10811.455 ns | 12065.297 ns | 11276.938 ns | 339180 / 339108 / 339128 | 0.927x | 0.963x | 18.29% / 9.04% / 6.44% | 7/11 / 6/11 | noisy |
| 数值边界 | decode | UInt64Envelope | bytes | 11 | 14898.453 ns | 16582.180 ns | 12165.682 ns | 339128 / 339180 / 339116 | 0.898x | 1.124x | 14.28% / 7.91% / 4.49% | 11/11 / 2/11 | noisy |
| 数值边界 | decode | UInt64Envelope | string | 11 | 13962.012 ns | 15744.583 ns | 11650.537 ns | 339180 / 339184 / 339116 | 0.883x | 1.126x | 12.88% / 5.64% / 7.55% | 10/11 / 3/11 | noisy |
| 数值边界 | encode | UInt64Envelope | bytes | 11 | 2623.504 ns | 9411.466 ns | 8601.036 ns | 339128 / 339180 / 339136 | 0.314x | 0.315x | 12.70% / 7.12% / 6.32% | 11/11 / 11/11 | noisy |
| 数值边界 | encode | UInt64Envelope | string | 11 | 2164.859 ns | 7909.080 ns | 9228.116 ns | 339176 / 339180 / 339180 | 0.238x | 0.227x | 24.19% / 10.07% / 8.25% | 11/11 / 11/11 | noisy |
| 时间/大数 | decode | TemporalStats | bytes | 11 | 19566.792 ns | 33501.538 ns | 30774.349 ns | 339176 / 339124 / 339108 | 0.562x | 0.629x | 13.08% / 10.97% / 7.03% | 11/11 / 11/11 | noisy |
| 时间/大数 | decode | TemporalStats | string | 11 | 20037.414 ns | 37175.055 ns | 30383.809 ns | 339188 / 339116 / 339180 | 0.536x | 0.611x | 9.68% / 6.89% / 8.61% | 11/11 / 11/11 | noisy |
| 时间/大数 | encode | TemporalStats | bytes | 11 | 20324.760 ns | 21708.495 ns | 19949.550 ns | 339176 / 339180 / 339180 | 0.904x | 1.021x | 19.41% / 4.84% / 5.06% | 6/11 / 5/11 | noisy |
| 时间/大数 | encode | TemporalStats | string | 11 | 22299.444 ns | 22232.960 ns | 20413.006 ns | 339180 / 339180 / 339112 | 0.914x | 1.058x | 17.94% / 16.40% / 6.23% | 7/11 / 5/11 | noisy |
| 未知字段 | decode | Person | string | 11 | 17731.072 ns | 23405.935 ns | 16751.836 ns | 339180 / 339180 / 339180 | 0.743x | 1.045x | 2.62% / 10.34% / 5.24% | 11/11 / 0/11 | noisy |
| 流式 I/O | decode | Person | stream | 11 | 33910.857 ns | 20283.631 ns | 15156.013 ns | 339128 / 339176 / 339112 | 1.671x | 2.244x | 10.78% / 11.02% / 5.96% | 0/11 / 0/11 | noisy |
| 流式 I/O | encode | Person | stream | 11 | 6450.496 ns | 12323.809 ns | 10829.666 ns | 339176 / 339112 / 339108 | 0.521x | 0.579x | 7.04% / 9.62% / 10.08% | 11/11 / 11/11 | noisy |
| 深层嵌套 | decode | ArrayList<HashMap<String, ArrayList<ProfileRecord>>> | string | 11 | 362249.942 ns | 202973.714 ns | 96768.000 ns | 339180 / 339176 / 339108 | 1.832x | 3.734x | 4.42% / 5.60% / 4.48% | 0/11 / 0/11 | noisy |
| 深层嵌套 | encode | ArrayList<HashMap<String, ArrayList<ProfileRecord>>> | string | 11 | 58702.769 ns | 99833.596 ns | 67412.004 ns | 339180 / 339180 / 339128 | 0.590x | 0.835x | 12.61% / 8.01% / 5.67% | 11/11 / 11/11 | noisy |
| 转义/Unicode | decode | String | bytes | 11 | 5839.520 ns | 2200.567 ns | 1810.250 ns | 339176 / 339112 / 339112 | 2.754x | 3.222x | 9.37% / 4.11% / 1.56% | 0/11 / 0/11 | noisy |
| 转义/Unicode | decode | String | string | 11 | 5779.629 ns | 2357.991 ns | 2354.358 ns | 339112 / 339180 / 339180 | 2.618x | 2.431x | 11.27% / 5.73% / 9.18% | 0/11 / 0/11 | noisy |
| 转义/Unicode | encode | String | bytes | 11 | 1656.456 ns | 3138.800 ns | 3044.415 ns | 339176 / 339180 / 339108 | 0.536x | 0.551x | 13.79% / 5.25% / 6.34% | 11/11 / 11/11 | noisy |
| 转义/Unicode | encode | String | string | 11 | 1836.205 ns | 3050.679 ns | 3284.386 ns | 339180 / 339184 / 339128 | 0.569x | 0.552x | 9.85% / 6.27% / 1.57% | 11/11 / 11/11 | noisy |


## 复核

在归档解压目录执行 `sha256sum -c checksums.txt`，再用仓库中的
`scripts/json_cjfast_perf_summary.py --min-runs 11` 重新汇总 `run/`。本地重新生成的 CSV 和
Markdown 与归档内版本一致；JSON 仅因浮点末位舍入存在 `1e-12` 级差异，不修改 raw summary。
