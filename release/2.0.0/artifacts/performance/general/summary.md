# yjson / stdx.json / cjfast_json release benchmark

Every matched workload is included. CV changes only the stable/noisy label; it never removes a row.

- Complete workloads: 36
- Stable workloads (all libraries CV <= 5.00%): 13
- Noisy workloads retained: 23

| Scenario | Operation | Payload | Input | Runs | yjson median | stdx median | cjfast median | Y/S | Y/C | CV Y/S/C | yjson faster pairs S/C | Status |
|:--|:--|:--|:--|--:|--:|--:|--:|--:|--:|--:|--:|:--|
| Pretty JSON | decode | Person | string | 11 | 7631.700 ns | 97343.247 ns | 17376.529 ns | 0.077x | 0.437x | 4.66% / 2.50% / 5.19% | 11/11 / 11/11 | noisy |
| Pretty JSON | encode | Person | string | 11 | 7424.000 ns | 84147.786 ns | 10867.942 ns | 0.088x | 0.689x | 1.21% / 2.07% / 12.86% | 11/11 / 11/11 | noisy |
| 基础对象 | decode | Address | bytes | 11 | 1428.601 ns | 35328.000 ns | 1982.386 ns | 0.040x | 0.714x | 3.90% / 0.44% / 0.84% | 11/11 / 11/11 | stable |
| 基础对象 | decode | Address | string | 11 | 1395.946 ns | 35560.000 ns | 2041.468 ns | 0.039x | 0.681x | 5.40% / 0.28% / 4.16% | 11/11 / 11/11 | noisy |
| 基础对象 | decode | Person | bytes | 11 | 10449.815 ns | 89717.703 ns | 15295.276 ns | 0.115x | 0.657x | 8.74% / 2.57% / 1.79% | 11/11 / 11/11 | noisy |
| 基础对象 | decode | Person | string | 11 | 9963.493 ns | 87893.333 ns | 15919.056 ns | 0.110x | 0.596x | 4.64% / 2.16% / 4.82% | 11/11 / 11/11 | stable |
| 基础对象 | encode | Address | bytes | 11 | 1259.592 ns | 56435.692 ns | 2460.942 ns | 0.022x | 0.509x | 3.73% / 0.72% / 8.25% | 11/11 / 11/11 | noisy |
| 基础对象 | encode | Address | string | 11 | 1454.407 ns | 56640.270 ns | 2468.540 ns | 0.026x | 0.578x | 4.36% / 0.34% / 8.92% | 11/11 / 11/11 | noisy |
| 基础对象 | encode | Person | bytes | 11 | 3357.330 ns | 76544.000 ns | 9785.983 ns | 0.044x | 0.343x | 3.21% / 0.70% / 10.65% | 11/11 / 11/11 | noisy |
| 基础对象 | encode | Person | string | 11 | 3848.806 ns | 76678.400 ns | 10209.290 ns | 0.050x | 0.384x | 1.00% / 0.33% / 7.61% | 11/11 / 11/11 | noisy |
| 大 Map | decode | HashMap<String, Int64>[64] | string | 11 | 206441.739 ns | 591616.000 ns | 228480.000 ns | 0.342x | 0.893x | 3.36% / 1.50% / 18.41% | 11/11 / 10/11 | noisy |
| 大 Map | encode | HashMap<String, Int64>[64] | string | 11 | 122424.264 ns | 258218.667 ns | 130503.111 ns | 0.480x | 0.937x | 3.17% / 2.01% / 1.69% | 11/11 / 10/11 | stable |
| 大数组 | decode | ArrayList<ProfileRecord>[64] | string | 11 | 49664.000 ns | 963072.000 ns | 78336.000 ns | 0.051x | 0.633x | 2.57% / 3.75% / 3.80% | 11/11 / 11/11 | stable |
| 大数组 | encode | ArrayList<ProfileRecord>[64] | string | 11 | 46080.000 ns | 449230.629 ns | 76117.333 ns | 0.103x | 0.608x | 0.53% / 11.73% / 1.10% | 11/11 / 11/11 | noisy |
| 字段顺序 | decode | Person | string | 11 | 7525.367 ns | 87942.737 ns | 17541.825 ns | 0.085x | 0.430x | 6.62% / 0.49% / 5.49% | 11/11 / 11/11 | noisy |
| 嵌套对象 | decode | ProfileBundle | bytes | 11 | 14544.331 ns | 93483.886 ns | 15586.485 ns | 0.154x | 0.930x | 5.11% / 0.91% / 5.37% | 11/11 / 11/11 | noisy |
| 嵌套对象 | decode | ProfileBundle | string | 11 | 14135.273 ns | 93849.600 ns | 15792.240 ns | 0.151x | 0.896x | 2.03% / 0.50% / 4.98% | 11/11 / 11/11 | stable |
| 嵌套对象 | encode | ProfileBundle | bytes | 11 | 10344.431 ns | 77258.667 ns | 12545.571 ns | 0.133x | 0.816x | 2.73% / 0.69% / 3.89% | 11/11 / 11/11 | stable |
| 嵌套对象 | encode | ProfileBundle | string | 11 | 10766.641 ns | 77565.538 ns | 12337.800 ns | 0.139x | 0.845x | 2.13% / 0.68% / 4.59% | 11/11 / 11/11 | stable |
| 数值边界 | decode | UInt64Envelope | bytes | 11 | 12501.850 ns | 80280.381 ns | 12132.480 ns | 0.149x | 1.029x | 2.83% / 3.01% / 4.97% | 11/11 / 3/11 | stable |
| 数值边界 | decode | UInt64Envelope | string | 11 | 12313.600 ns | 80563.200 ns | 10067.162 ns | 0.153x | 1.223x | 1.46% / 2.86% / 18.67% | 11/11 / 2/11 | noisy |
| 数值边界 | encode | UInt64Envelope | bytes | 11 | 9370.939 ns | 75946.667 ns | 9566.705 ns | 0.124x | 0.965x | 2.30% / 4.10% / 2.31% | 11/11 / 10/11 | stable |
| 数值边界 | encode | UInt64Envelope | string | 11 | 9632.083 ns | 75776.000 ns | 9645.704 ns | 0.127x | 0.954x | 3.07% / 1.91% / 3.21% | 11/11 / 7/11 | stable |
| 时间/大数 | decode | TemporalStats | bytes | 11 | 7533.178 ns | 97280.000 ns | 33786.266 ns | 0.077x | 0.224x | 3.59% / 1.55% / 5.35% | 11/11 / 11/11 | noisy |
| 时间/大数 | decode | TemporalStats | string | 11 | 7301.116 ns | 97211.733 ns | 31150.539 ns | 0.075x | 0.220x | 3.56% / 0.59% / 7.20% | 11/11 / 11/11 | noisy |
| 时间/大数 | encode | TemporalStats | bytes | 11 | 20620.800 ns | 81749.333 ns | 21691.058 ns | 0.251x | 0.952x | 0.60% / 4.62% / 1.09% | 11/11 / 11/11 | stable |
| 时间/大数 | encode | TemporalStats | string | 11 | 21026.588 ns | 81792.000 ns | 21767.837 ns | 0.256x | 0.964x | 1.68% / 2.67% / 0.92% | 11/11 / 10/11 | stable |
| 未知字段 | decode | Person | string | 11 | 9146.918 ns | 106726.400 ns | 17201.013 ns | 0.083x | 0.517x | 6.86% / 2.90% / 6.55% | 11/11 / 11/11 | noisy |
| 流式 I/O | decode | Person | stream | 11 | 30592.000 ns | 87691.636 ns | 15684.516 ns | 0.349x | 1.849x | 3.49% / 3.25% / 5.44% | 11/11 / 0/11 | noisy |
| 流式 I/O | encode | Person | stream | 11 | 5630.061 ns | 77056.000 ns | 9988.686 ns | 0.073x | 0.561x | 2.37% / 4.57% / 9.11% | 11/11 / 11/11 | noisy |
| 深层嵌套 | decode | ArrayList<HashMap<String, ArrayList<ProfileRecord>>> | string | 11 | 81262.933 ns | 601088.000 ns | 96682.667 ns | 0.134x | 0.844x | 0.58% / 1.50% / 2.70% | 11/11 / 11/11 | stable |
| 深层嵌套 | encode | ArrayList<HashMap<String, ArrayList<ProfileRecord>>> | string | 11 | 63552.000 ns | 276585.290 ns | 74500.267 ns | 0.231x | 0.856x | 1.18% / 7.96% / 0.64% | 11/11 / 11/11 | noisy |
| 转义/Unicode | decode | String | bytes | 11 | 2570.907 ns | 30080.000 ns | 1831.253 ns | 0.086x | 1.404x | 1.47% / 1.78% / 11.92% | 11/11 / 0/11 | noisy |
| 转义/Unicode | decode | String | string | 11 | 2534.286 ns | 29568.000 ns | 2360.331 ns | 0.085x | 1.012x | 4.74% / 1.50% / 8.79% | 11/11 / 4/11 | noisy |
| 转义/Unicode | encode | String | bytes | 11 | 1315.247 ns | 55878.132 ns | 2427.612 ns | 0.024x | 0.486x | 6.70% / 1.79% / 10.55% | 11/11 / 11/11 | noisy |
| 转义/Unicode | encode | String | string | 11 | 1538.838 ns | 56576.000 ns | 3232.653 ns | 0.026x | 0.474x | 6.06% / 14.98% / 5.38% | 11/11 / 11/11 | noisy |
