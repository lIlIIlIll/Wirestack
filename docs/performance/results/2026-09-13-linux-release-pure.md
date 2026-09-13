# 2026-09-13 `0.1.0` 候选 Pure release 对比

本页记录当前候选 `4766daa7ac88a5ad0869cfa2dbdb12c63acd0161` 与 release baseline `175a4b23656ab44d2d139b810e69ac364347297a` 的 Pure A/B 测量。完整 raw report、每轮日志、源码身份、工具链、CPU 采样和 checksum 保存在 `benchmarks/results/release-performance/2026-09-13-4766daa/yjson-pure-release-4766daa-r4.tar.gz`。

## Gate 结论

Runner `scripts/json_pure_perf_compare.py` 在 Cangjie STS `1.1.3` 下以 `--rebuild --enforce` 执行 24 个实际 case、11 轮、128 MiB heap、`--gate-mode release`。CPU 1 与 sibling 49 先经过 30 秒 idle sample，利用率均为 `0.0%`，满足正式 idle-core 条件。

- `all_ratios_at_most_1_05`: **true**
- `both_cv_at_most_5_percent`: `false`（只标记 noisy，不改变普通 Release gate）
- `passed`: **true**
- 最大候选回退：`yjsonStringEncodePerson`，`1.038x`，`-3.77%`
- 最大候选改善：`yjsonBytesDecodeLargeInt64Map`，`0.757x`，`24.26%`

普通 Release 只要求所有 candidate/baseline 比值不超过 `1.05`；本批没有声明优化目标，因此没有触发 optimization target gate。

## 完整结果

单位为 ns/op；`ratio` 为 candidate/baseline，越小越好。CV 超过 5% 的行仍完整保留，不能用于稳定的精确排名。

| Case | Baseline | Candidate | Ratio | Improvement | Candidate wins | CV baseline / candidate |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `yjsonStringEncodeLargeInt64Map` | 5402.498 | 5490.699 | 1.016x | -1.63% | 3/11 | 3.78% / 2.08% |
| `yjsonStringDecodeLargeInt64Map` | 31744.000 | 25364.480 | 0.799x | 20.10% | 11/11 | 1.74% / 3.02% |
| `yjsonBytesDecodeLargeInt64Map` | 35091.394 | 26576.533 | 0.757x | 24.26% | 11/11 | 5.19% / 3.92% |
| `yjsonStringEncodeDeepNestedProfiles` | 41872.492 | 41522.579 | 0.992x | 0.84% | 7/11 | 2.15% / 0.94% |
| `yjsonStringDecodeDeepNestedProfiles` | 301747.200 | 302336.000 | 1.002x | -0.20% | 4/11 | 5.02% / 5.42% |
| `yjsonBytesDecodeDeepNestedProfiles` | 307609.600 | 303911.273 | 0.988x | 1.20% | 8/11 | 3.78% / 6.70% |
| `yjsonStringEncodePerson` | 1436.335 | 1490.466 | 1.038x | -3.77% | 4/11 | 2.39% / 3.32% |
| `yjsonStringDecodePerson` | 7621.972 | 7523.510 | 0.987x | 1.29% | 8/11 | 4.08% / 7.33% |
| `yjsonStringEncodeLargeProfileArray` | 25548.800 | 25669.818 | 1.005x | -0.47% | 5/11 | 1.41% / 0.95% |
| `yjsonStringDecodeLargeProfileArray` | 73347.119 | 74186.473 | 1.011x | -1.14% | 1/11 | 1.01% / 1.06% |
| `parseStringRecords64k` | 2251155.394 | 2311236.267 | 1.027x | -2.67% | 4/11 | 5.40% / 4.53% |
| `parseBytesRecords64k` | 2335904.000 | 2288349.663 | 0.980x | 2.04% | 6/11 | 4.01% / 3.63% |
| `parseStringRecords1m` | 30801024.000 | 31180032.000 | 1.012x | -1.23% | 4/11 | 7.71% / 12.95% |
| `parseBytesRecords1m` | 31833728.000 | 32027946.667 | 1.006x | -0.61% | 6/11 | 10.25% / 5.53% |
| `yjsonStringEncodeProfileBundle` | 7001.495 | 6940.116 | 0.991x | 0.88% | 10/11 | 0.87% / 0.73% |
| `yjsonStringDecodeProfileBundle` | 15595.233 | 15361.044 | 0.985x | 1.50% | 7/11 | 2.07% / 3.21% |
| `yjsonBytesEncodeProfileBundle` | 9006.545 | 9040.000 | 1.004x | -0.37% | 5/11 | 2.58% / 2.17% |
| `yjsonBytesDecodeProfileBundle` | 17920.000 | 17749.333 | 0.990x | 0.95% | 8/11 | 1.77% / 4.51% |
| `yjsonStringEncodeEscapedUnicodeString` | 1388.800 | 1385.256 | 0.997x | 0.26% | 6/11 | 3.57% / 6.88% |
| `yjsonBytesEncodeEscapedUnicodeString` | 1294.540 | 1310.126 | 1.012x | -1.20% | 1/11 | 3.04% / 1.91% |
| `decodePersonChunk4k` | 62953.329 | 61857.374 | 0.983x | 1.74% | 7/11 | 5.25% / 5.49% |
| `decodeRecords64kChunk4k` | 11325252.267 | 11226163.200 | 0.991x | 0.87% | 8/11 | 2.92% / 16.56% |
| `encodePersonMemory` | 9516.126 | 9292.621 | 0.977x | 2.35% | 9/11 | 4.16% / 5.77% |
| `encodeRecords64kMemory` | 1302578.479 | 1306313.915 | 1.003x | -0.29% | 3/11 | 2.79% / 2.69% |

## 身份

| 项目 | 值 |
| --- | --- |
| Candidate commit/tree | `4766daa7ac88a5ad0869cfa2dbdb12c63acd0161` / `ccbee2fa194180c66374d44852c0122c30b7e9a6` |
| Baseline commit | `175a4b23656ab44d2d139b810e69ac364347297a` |
| Candidate product source SHA-256 | `6056f53aa56767a69a29685dad1d6b8fadd8c39a7b47ca6ecc60b46f114acb0b` |
| Effective harness SHA-256 | `4d5788b785c9b69993f91e78934dcb5e21fca8b9ac2b2a7c6986c115e65e0865` |
| Runner SHA-256 | `48a45854a72ed269a23e328cc7f28c6ce594ed3784d157a4e0403427dcedc0d1` |
| Corpus SHA-256 | `db9b0242e01fb4cfa2468245f8be5329a0967052412b7340f12c468c6202a70f` |
| Summary SHA-256 | `783197b7e4bcf181a177df045206210924244fb3b54018bb162cdcc42d46e265` |
| Provenance SHA-256 | `6b8a514c1650a55b8a8b83f6caf43e93a824b462a5c16604bc724c1e09419670` |
| CPU selection SHA-256 | `b4a5c6a96f45f5b72aa741d984d7e7e819e3feb0b0dffe87bd37d6214d4a5055` |
| Archive SHA-256 | `506504cbe6caf5a87d4c1a699d9855b5ddc4e293fbd15e883487f71a506c2053` |
| Host / SDK | `ubuntu2223131`, Linux 5.15.0-187-generic, x86_64 / Cangjie STS `1.1.3` |
