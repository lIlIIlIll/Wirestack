# 2026-09-14 `0.1.0` 候选 Pure release 对比

本页记录当前候选 `7436598b6cd22084ea990832b07d972aeae26e1b` 与 release baseline
`175a4b23656ab44d2d139b810e69ac364347297a` 的 Pure A/B 测量。完整 raw report、每轮日志、RSS sidecar、源码身份、工具链、CPU 采样和 checksum 保存在
`benchmarks/results/release-performance/2026-09-14-7436598/yjson-pure-release-7436598-r1.tar.gz`。
该归档不是 GitHub Release 上传资产。[发布证据](../../../release/0.1.0/evidence.md)记录整体 gate 状态。

本次使用 `--rebuild --enforce` 执行 24 个实际 case、11 轮、128 MiB heap、`--gate-mode release`。
每个 baseline/candidate 独立进程均由 GNU `/usr/bin/time -v` 记录 peak RSS；summary 表中的 RSS 列与
sidecar 逐项对应。CPU 2 与 sibling 50 先经过 30 秒 idle sample，利用率均为 `0.0%`，满足正式 idle-core 条件。

## Gate 结论

- `all_ratios_at_most_1_05`: **true**
- `both_cv_at_most_5_percent`: `false`（只标记 noisy，不改变普通 Release gate）
- `passed`: **true**
- 最大候选回退：`yjsonBytesDecodeProfileBundle`，`1.047x`，`-4.7%`
- 最大候选改善：`yjsonStringDecodeProfileBundle`，`0.594x`，`40.6%`

普通 Release 只要求所有 candidate/baseline 比值不超过 `1.05`；本批没有声明优化目标，因此没有触发 optimization target gate。CV 超过 5% 的行仍完整保留，不能用于稳定的精确排名。

## 完整结果

单位为 ns/op；`C/B` 为 candidate/baseline，越小越好。RSS 单位为 kbytes；每列是该 case 11 个进程 sidecar 的最大值。

| Case | Baseline median | Candidate median | C/B | Improvement | Wins | Baseline CV | Candidate CV | Baseline max RSS KB | Candidate max RSS KB |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| `yjsonStringEncodeLargeInt64Map` | 5.492 us | 5.670 us | 1.032x | -3.2% | 2/11 | 3.90% | 6.45% | 192840 | 192708 |
| `yjsonStringDecodeLargeInt64Map` | 29.686 us | 23.421 us | 0.789x | 21.1% | 11/11 | 5.83% | 1.79% | 193052 | 193200 |
| `yjsonBytesDecodeLargeInt64Map` | 30.920 us | 25.923 us | 0.838x | 16.2% | 11/11 | 2.41% | 4.44% | 193196 | 192832 |
| `yjsonStringEncodeDeepNestedProfiles` | 39.081 us | 39.495 us | 1.011x | -1.1% | 5/11 | 7.19% | 8.81% | 192328 | 192384 |
| `yjsonStringDecodeDeepNestedProfiles` | 324.425 us | 298.104 us | 0.919x | 8.1% | 9/11 | 6.05% | 8.41% | 192528 | 191400 |
| `yjsonBytesDecodeDeepNestedProfiles` | 316.191 us | 318.542 us | 1.007x | -0.7% | 6/11 | 15.46% | 20.14% | 192048 | 191752 |
| `yjsonStringEncodePerson` | 1.597 us | 1.587 us | 0.994x | 0.6% | 5/11 | 5.23% | 6.90% | 192164 | 192532 |
| `yjsonStringDecodePerson` | 5.636 us | 5.415 us | 0.961x | 3.9% | 7/11 | 14.47% | 32.35% | 193320 | 192732 |
| `yjsonStringEncodeLargeProfileArray` | 26.726 us | 26.814 us | 1.003x | -0.3% | 3/11 | 0.79% | 1.22% | 192200 | 191664 |
| `yjsonStringDecodeLargeProfileArray` | 68.950 us | 69.248 us | 1.004x | -0.4% | 4/11 | 3.57% | 1.33% | 192160 | 192028 |
| `parseStringRecords64k` | 2378.337 us | 2408.282 us | 1.013x | -1.3% | 6/11 | 5.12% | 6.12% | 189788 | 190148 |
| `parseBytesRecords64k` | 2518.907 us | 2482.662 us | 0.986x | 1.4% | 6/11 | 5.43% | 4.39% | 190412 | 190368 |
| `parseStringRecords1m` | 36659.968 us | 34903.637 us | 0.952x | 4.8% | 8/11 | 8.15% | 4.64% | 188964 | 189356 |
| `parseBytesRecords1m` | 35476.736 us | 35470.848 us | 1.000x | 0.0% | 5/11 | 6.52% | 6.37% | 189460 | 189184 |
| `yjsonStringEncodeProfileBundle` | 6.938 us | 6.777 us | 0.977x | 2.3% | 4/11 | 4.60% | 4.41% | 192376 | 192940 |
| `yjsonStringDecodeProfileBundle` | 12.835 us | 7.623 us | 0.594x | 40.6% | 7/11 | 19.62% | 29.19% | 192784 | 192176 |
| `yjsonBytesEncodeProfileBundle` | 7.844 us | 7.991 us | 1.019x | -1.9% | 4/11 | 15.23% | 12.78% | 191696 | 192196 |
| `yjsonBytesDecodeProfileBundle` | 13.843 us | 14.490 us | 1.047x | -4.7% | 3/11 | 14.12% | 10.08% | 192892 | 192120 |
| `yjsonStringEncodeEscapedUnicodeString` | 1.142 us | 1.131 us | 0.991x | 0.9% | 7/11 | 5.48% | 4.36% | 191808 | 192408 |
| `yjsonBytesEncodeEscapedUnicodeString` | 1.042 us | 1.036 us | 0.995x | 0.5% | 7/11 | 2.84% | 5.15% | 192104 | 191880 |
| `decodePersonChunk4k` | 67.211 us | 66.483 us | 0.989x | 1.1% | 8/11 | 1.30% | 1.81% | 192372 | 191960 |
| `decodeRecords64kChunk4k` | 11672.044 us | 12129.472 us | 1.039x | -3.9% | 6/11 | 18.26% | 19.95% | 191296 | 191388 |
| `encodePersonMemory` | 9.698 us | 9.748 us | 1.005x | -0.5% | 4/11 | 8.01% | 3.39% | 192440 | 192340 |
| `encodeRecords64kMemory` | 1305.268 us | 1296.117 us | 0.993x | 0.7% | 10/11 | 0.64% | 1.54% | 186884 | 186216 |


## 身份

| 项目 | 值 |
| --- | --- |
| Candidate commit/tree | `7436598b6cd22084ea990832b07d972aeae26e1b` / `00d9629474c5b5a850bc427aca6f84046dc7ffd5` |
| Baseline commit/tree | `175a4b23656ab44d2d139b810e69ac364347297a` / `c7116cc24173d8553d4ccce4d31ec80a570b74ee` |
| Candidate product source SHA-256 | `b0120df219570213b3a61a7876349efeabd2bb9bf92a8fb4eea3066e25d11edf` |
| Baseline product source SHA-256 | `df9108e367363847b0fd59b3c611cc6a3504f4d426152e13479caf3e8b94d7f9` |
| Effective harness SHA-256 | `4d5788b785c9b69993f91e78934dcb5e21fca8b9ac2b2a7c6986c115e65e0865` |
| Runner SHA-256 | `9a2bd99bf80cb7403fb0419a9b245f045bf0c426798807662d8fddcbbb8d9c42` |
| Corpus SHA-256 | `db9b0242e01fb4cfa2468245f8be5329a0967052412b7340f12c468c6202a70f` |
| CPU selection | CPU `2`, sibling `50`；30 秒 idle sample 两线程均为 `0.0%` |
| SDK | Cangjie STS `1.1.3`；`cjc`/`cjpm` `1.1.3` |
| Heap | `128MB` |
| GNU time | `/usr/bin/time`; RSS unit `kbytes` |
| Archive SHA-256 | `4cccd194b00d8810f263f466f2ca9e56d5daccd67732b40627ef064c7e466e5f` |

## 复核

归档包含 `provenance.json`、`cpu-selection.json`、`cpu-pair-monitor.csv`、两套 source identity、每轮 timing report、日志和 RSS sidecar。解压后可执行 `sha256sum -c checksums.txt`；再按仓库中的 `scripts/json_pure_perf_compare.py` 逻辑重生成 summary，对比 timing、gate 和 RSS 数据。
