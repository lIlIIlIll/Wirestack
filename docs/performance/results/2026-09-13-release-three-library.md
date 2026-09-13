# 2026-09-13 当前 `0.1.0` 候选三库完整对比

本页记录当前候选的 yjson、stdx.json 和 cjfast_json 共同 workload release 测量。结果绑定
提交 `4766daa7ac88a5ad0869cfa2dbdb12c63acd0161`；完整 raw samples、preflight、metadata、manifest、summary
和 checksum 位于归档路径
`benchmarks/results/release-performance/2026-09-13-4766daa/yjson-three-library-release-4766daa-r2.tar.gz`。
该归档不是 GitHub Release 上传资产。[发布证据](../../../release/0.1.0/evidence.md)记录整体 gate 状态。

## 结果状态

每个 workload/library 组合完成 11 个独立进程轮次；workload 顺序逐轮旋转，偶数轮反转，
三库顺序逐轮旋转。完整 36 个 workload 均保留。CV 超过 5% 的行标记为 noisy；noisy 行
只保留方向和复核数据，不作为稳定的精确性能排名。

| 项目 | 值 |
| --- | --- |
| Candidate | `4766daa7ac88a5ad0869cfa2dbdb12c63acd0161` |
| Candidate measured tree | `ccbee2fa194180c66374d44852c0122c30b7e9a6` |
| SDK | Cangjie `1.1.3`；`cjc`/`cjpm` 输出见 raw `run/metadata.json`；metadata `sdk_label`=`unknown` |
| Host | `ubuntu2223131`；Linux-5.15.0-187-generic-x86_64-with-glibc2.35 |
| CPU / heap | CPU `1`；`128MB` |
| Scope | 36 workloads × 3 libraries × 11 rounds = 1188 library/workload rounds |
| Stable workloads | 3/36（all three libraries CV <= 5%） |
| Noisy workloads retained | 33/36 |
| cjfast_json commit | `eefdedd1e53c93bb5ada11a96b9b81d88b2c6c65` |
| stdx dependency | `0.0.3` |
| yjson source SHA-256 | `fe27982225cab157ef1c8ea039ee97fe0dad80b17d8835ebeadc77d91801f018` |
| cjfast_json source SHA-256 | `b28dc5299b7793e6eb97e3e4554ab8740b046d68d0af97583457691e46326ccd` |
| Archive SHA-256 | `01cf6df6cbdc20cfbb758b94d705ec9c7c23e5925127c9e4b7c26b7d7a2f6c52` |

`ccbee2fa194180c66374d44852c0122c30b7e9a6` 是提交 `4766daa` 的 measured source tree；
当前七库 marker 另以 candidate identity 绑定 release graph、root manifest、root lock 和九包 lockstep manifests。

## 完整汇总

Every matched workload is included. CV changes only the stable/noisy label; it never removes a row.

- Complete workloads: 36
- Stable workloads (all libraries CV <= 5.00%): 3
- Noisy workloads retained: 33

| Scenario | Operation | Payload | Input | Runs | yjson median | stdx median | cjfast median | Y/S | Y/C | CV Y/S/C | yjson faster pairs S/C | Status |
|:--|:--|:--|:--|--:|--:|--:|--:|--:|--:|--:|--:|:--|
| Pretty JSON | decode | Person | string | 11 | 12405.491 ns | 21816.000 ns | 16167.551 ns | 0.570x | 0.757x | 6.01% / 8.77% / 9.00% | 11/11 / 10/11 | noisy |
| Pretty JSON | encode | Person | string | 11 | 8454.095 ns | 11577.705 ns | 12256.178 ns | 0.758x | 0.754x | 10.77% / 11.14% / 8.81% | 10/11 / 10/11 | noisy |
| 基础对象 | decode | Address | bytes | 11 | 3203.439 ns | 2302.732 ns | 1962.276 ns | 1.391x | 1.639x | 5.76% / 10.21% / 1.56% | 0/11 / 0/11 | noisy |
| 基础对象 | decode | Address | string | 11 | 1534.578 ns | 2455.101 ns | 2040.883 ns | 0.632x | 0.744x | 4.89% / 9.84% / 11.31% | 11/11 / 11/11 | noisy |
| 基础对象 | decode | Person | bytes | 11 | 18828.609 ns | 21325.531 ns | 16214.496 ns | 0.876x | 1.176x | 6.17% / 1.87% / 5.43% | 10/11 / 1/11 | noisy |
| 基础对象 | decode | Person | string | 11 | 16213.136 ns | 21685.333 ns | 16213.016 ns | 0.749x | 0.991x | 4.23% / 3.63% / 4.59% | 11/11 / 6/11 | stable |
| 基础对象 | encode | Address | bytes | 11 | 1656.953 ns | 3086.794 ns | 2465.825 ns | 0.545x | 0.676x | 1.84% / 8.09% / 8.60% | 11/11 / 11/11 | noisy |
| 基础对象 | encode | Address | string | 11 | 1024.406 ns | 3247.853 ns | 2492.933 ns | 0.300x | 0.400x | 9.68% / 12.85% / 9.56% | 11/11 / 11/11 | noisy |
| 基础对象 | encode | Person | bytes | 11 | 4108.000 ns | 12228.339 ns | 12017.029 ns | 0.337x | 0.347x | 2.38% / 14.17% / 10.69% | 11/11 / 11/11 | noisy |
| 基础对象 | encode | Person | string | 11 | 1731.826 ns | 13176.889 ns | 10112.595 ns | 0.131x | 0.174x | 12.85% / 7.95% / 15.35% | 11/11 / 11/11 | noisy |
| 大 Map | decode | HashMap<String, Int64>[64] | string | 11 | 29529.212 ns | 248640.000 ns | 239402.351 ns | 0.118x | 0.124x | 15.57% / 2.98% / 4.13% | 11/11 / 11/11 | noisy |
| 大 Map | encode | HashMap<String, Int64>[64] | string | 11 | 6054.364 ns | 128486.400 ns | 131027.102 ns | 0.048x | 0.046x | 4.77% / 4.18% / 2.62% | 11/11 / 11/11 | stable |
| 大数组 | decode | ArrayList<ProfileRecord>[64] | string | 11 | 104088.965 ns | 187053.233 ns | 77824.000 ns | 0.568x | 1.335x | 11.48% / 11.77% / 2.25% | 11/11 / 0/11 | noisy |
| 大数组 | encode | ArrayList<ProfileRecord>[64] | string | 11 | 28720.000 ns | 92049.111 ns | 75392.000 ns | 0.321x | 0.381x | 1.99% / 10.30% / 0.58% | 11/11 / 11/11 | noisy |
| 字段顺序 | decode | Person | string | 11 | 12173.345 ns | 21760.000 ns | 16153.380 ns | 0.560x | 0.746x | 5.86% / 7.13% / 5.32% | 11/11 / 11/11 | noisy |
| 嵌套对象 | decode | ProfileBundle | bytes | 11 | 20642.790 ns | 22520.741 ns | 15555.001 ns | 0.920x | 1.313x | 2.80% / 2.38% / 5.38% | 10/11 / 0/11 | noisy |
| 嵌套对象 | decode | ProfileBundle | string | 11 | 17465.600 ns | 22927.928 ns | 15671.336 ns | 0.760x | 1.113x | 0.59% / 1.14% / 5.19% | 11/11 / 2/11 | noisy |
| 嵌套对象 | encode | ProfileBundle | bytes | 11 | 10629.988 ns | 13019.110 ns | 12661.638 ns | 0.819x | 0.841x | 2.21% / 5.61% / 1.90% | 11/11 / 11/11 | noisy |
| 嵌套对象 | encode | ProfileBundle | string | 11 | 8040.316 ns | 13352.615 ns | 12990.104 ns | 0.602x | 0.641x | 11.40% / 4.32% / 2.96% | 11/11 / 11/11 | noisy |
| 数值边界 | decode | UInt64Envelope | bytes | 11 | 13937.099 ns | 16810.667 ns | 12424.775 ns | 0.827x | 1.133x | 5.24% / 4.50% / 5.17% | 11/11 / 1/11 | noisy |
| 数值边界 | decode | UInt64Envelope | string | 11 | 12125.867 ns | 17088.000 ns | 12427.055 ns | 0.717x | 0.982x | 7.11% / 7.46% / 12.44% | 11/11 / 6/11 | noisy |
| 数值边界 | encode | UInt64Envelope | bytes | 11 | 2702.847 ns | 10151.619 ns | 9549.419 ns | 0.269x | 0.282x | 4.63% / 3.21% / 2.71% | 11/11 / 11/11 | stable |
| 数值边界 | encode | UInt64Envelope | string | 11 | 1320.789 ns | 9726.993 ns | 9826.678 ns | 0.154x | 0.133x | 17.55% / 11.92% / 3.18% | 11/11 / 11/11 | noisy |
| 时间/大数 | decode | TemporalStats | bytes | 11 | 17392.000 ns | 37376.000 ns | 31430.837 ns | 0.465x | 0.549x | 11.93% / 7.52% / 5.27% | 11/11 / 11/11 | noisy |
| 时间/大数 | decode | TemporalStats | string | 11 | 17140.364 ns | 38695.822 ns | 31490.486 ns | 0.445x | 0.541x | 2.38% / 7.07% / 7.74% | 11/11 / 11/11 | noisy |
| 时间/大数 | encode | TemporalStats | bytes | 11 | 18969.600 ns | 22758.400 ns | 21207.997 ns | 0.827x | 0.897x | 12.34% / 1.38% / 1.92% | 9/11 / 9/11 | noisy |
| 时间/大数 | encode | TemporalStats | string | 11 | 18522.667 ns | 23078.737 ns | 21472.000 ns | 0.803x | 0.864x | 8.25% / 6.04% / 1.10% | 10/11 / 9/11 | noisy |
| 未知字段 | decode | Person | string | 11 | 15195.257 ns | 22991.719 ns | 17202.743 ns | 0.740x | 0.868x | 8.36% / 12.06% / 6.34% | 11/11 / 9/11 | noisy |
| 流式 I/O | decode | Person | stream | 11 | 36487.111 ns | 21283.556 ns | 15498.056 ns | 1.716x | 2.130x | 5.78% / 0.53% / 6.20% | 0/11 / 0/11 | noisy |
| 流式 I/O | encode | Person | stream | 11 | 6497.699 ns | 13207.126 ns | 12116.143 ns | 0.490x | 0.541x | 7.09% / 9.06% / 8.67% | 11/11 / 11/11 | noisy |
| 深层嵌套 | decode | ArrayList<HashMap<String, ArrayList<ProfileRecord>>> | string | 11 | 311752.411 ns | 165251.753 ns | 96661.333 ns | 1.829x | 3.212x | 11.80% / 6.18% / 0.57% | 0/11 / 0/11 | noisy |
| 深层嵌套 | encode | ArrayList<HashMap<String, ArrayList<ProfileRecord>>> | string | 11 | 48032.427 ns | 82347.500 ns | 73813.333 ns | 0.585x | 0.649x | 9.69% / 12.09% / 0.67% | 11/11 / 11/11 | noisy |
| 转义/Unicode | decode | String | bytes | 11 | 4884.760 ns | 2244.088 ns | 1829.885 ns | 2.177x | 2.622x | 5.35% / 1.46% / 9.08% | 0/11 / 0/11 | noisy |
| 转义/Unicode | decode | String | string | 11 | 4696.084 ns | 2440.776 ns | 2390.894 ns | 1.912x | 1.902x | 10.09% / 11.33% / 7.00% | 0/11 / 0/11 | noisy |
| 转义/Unicode | encode | String | bytes | 11 | 1700.272 ns | 2682.078 ns | 2453.102 ns | 0.622x | 0.674x | 13.65% / 12.69% / 11.46% | 11/11 / 11/11 | noisy |
| 转义/Unicode | encode | String | string | 11 | 1844.133 ns | 2953.472 ns | 3252.144 ns | 0.616x | 0.566x | 10.78% / 8.76% / 5.16% | 11/11 / 11/11 | noisy |

## 复核

在归档解压目录执行 `sha256sum -c checksums.txt`，再用仓库中的
`scripts/json_cjfast_perf_summary.py --min-runs 11` 重新汇总 `run/`。本地重新生成的 CSV 和
Markdown 与归档内版本一致；JSON 仅因浮点末位舍入存在 `1e-12` 级差异，不修改 raw summary。
