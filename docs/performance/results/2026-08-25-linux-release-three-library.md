# 2026-08-25 Linux release comparison

- Candidate source: `1eac96b3e49862dd13323e2c99e7ae0ce246b6c2`
- Platform: Linux x86_64, 8 logical CPUs
- Cangjie: `1.1.0-alpha.20260803040049`; cjpm `1.1.3`; stdx `0.0.3`
- cjfast_json: `eefdedd1e53c93bb5ada11a96b9b81d88b2c6c65`
- Heap: 128 MiB
- Design: 11 rotating-order process rounds per library and workload
- Scope: latency only; lower is better

> This evidence predates the correctness changes that follow the candidate source above. It remains the release baseline for that exact source and must not be relabeled as a later candidate result.

Every matched workload is included. CV changes only the stable/noisy label; it never removes a row.

- Complete workloads: 36
- Stable workloads (all libraries CV <= 5.00%): 9
- Noisy workloads retained: 27

| Scenario | Operation | Payload | Input | Runs | yjson median | stdx median | cjfast median | Y/S | Y/C | CV Y/S/C | yjson faster pairs S/C | Status |
|:--|:--|:--|:--|--:|--:|--:|--:|--:|--:|--:|--:|:--|
| Pretty JSON | decode | Person | string | 11 | 7296.000 ns | 98247.111 ns | 16619.821 ns | 0.071x | 0.412x | 5.30% / 2.69% / 6.50% | 11/11 / 11/11 | noisy |
| Pretty JSON | encode | Person | string | 11 | 8151.144 ns | 84224.000 ns | 11007.146 ns | 0.095x | 0.738x | 3.70% / 1.49% / 12.97% | 11/11 / 11/11 | noisy |
| 基础对象 | decode | Address | bytes | 11 | 1312.636 ns | 35286.891 ns | 1962.525 ns | 0.038x | 0.669x | 1.64% / 1.34% / 0.86% | 11/11 / 11/11 | stable |
| 基础对象 | decode | Address | string | 11 | 1240.635 ns | 35531.392 ns | 2034.732 ns | 0.035x | 0.607x | 9.02% / 0.48% / 4.73% | 11/11 / 11/11 | noisy |
| 基础对象 | decode | Person | bytes | 11 | 10386.284 ns | 87315.782 ns | 15448.672 ns | 0.116x | 0.653x | 11.82% / 2.26% / 5.07% | 11/11 / 11/11 | noisy |
| 基础对象 | decode | Person | string | 11 | 11001.794 ns | 86784.000 ns | 15631.547 ns | 0.127x | 0.698x | 27.17% / 0.62% / 4.03% | 11/11 / 10/11 | noisy |
| 基础对象 | encode | Address | bytes | 11 | 1825.579 ns | 56029.428 ns | 2454.468 ns | 0.033x | 0.739x | 5.89% / 1.02% / 17.46% | 11/11 / 11/11 | noisy |
| 基础对象 | encode | Address | string | 11 | 1522.827 ns | 56320.000 ns | 2442.481 ns | 0.027x | 0.595x | 5.91% / 0.39% / 9.73% | 11/11 / 11/11 | noisy |
| 基础对象 | encode | Person | bytes | 11 | 3791.543 ns | 76181.333 ns | 10459.083 ns | 0.050x | 0.366x | 1.29% / 2.96% / 7.99% | 11/11 / 11/11 | noisy |
| 基础对象 | encode | Person | string | 11 | 4194.490 ns | 76672.000 ns | 10238.107 ns | 0.055x | 0.414x | 3.23% / 0.79% / 6.88% | 11/11 / 11/11 | noisy |
| 大 Map | decode | HashMap<String, Int64>[64] | string | 11 | 200939.462 ns | 591360.000 ns | 231965.091 ns | 0.340x | 0.870x | 3.59% / 1.72% / 3.65% | 11/11 / 11/11 | stable |
| 大 Map | encode | HashMap<String, Int64>[64] | string | 11 | 120004.923 ns | 257996.800 ns | 131979.636 ns | 0.469x | 0.916x | 2.19% / 1.77% / 2.96% | 11/11 / 11/11 | stable |
| 大数组 | decode | ArrayList<ProfileRecord>[64] | string | 11 | 42012.903 ns | 1004737.542 ns | 78225.778 ns | 0.042x | 0.535x | 6.86% / 4.17% / 0.35% | 11/11 / 11/11 | noisy |
| 大数组 | encode | ArrayList<ProfileRecord>[64] | string | 11 | 108492.800 ns | 438753.524 ns | 75719.585 ns | 0.250x | 1.433x | 1.34% / 11.74% / 1.27% | 11/11 / 0/11 | noisy |
| 字段顺序 | decode | Person | string | 11 | 6543.536 ns | 87778.909 ns | 16800.744 ns | 0.074x | 0.389x | 5.50% / 2.69% / 5.17% | 11/11 / 11/11 | noisy |
| 嵌套对象 | decode | ProfileBundle | bytes | 11 | 13548.645 ns | 93241.600 ns | 15722.764 ns | 0.142x | 0.804x | 5.49% / 1.31% / 5.43% | 11/11 / 11/11 | noisy |
| 嵌套对象 | decode | ProfileBundle | string | 11 | 13383.322 ns | 93440.000 ns | 16596.949 ns | 0.143x | 0.816x | 4.52% / 0.57% / 5.13% | 11/11 / 11/11 | noisy |
| 嵌套对象 | encode | ProfileBundle | bytes | 11 | 14498.133 ns | 77465.600 ns | 12683.813 ns | 0.188x | 1.140x | 2.51% / 10.82% / 4.19% | 11/11 / 0/11 | noisy |
| 嵌套对象 | encode | ProfileBundle | string | 11 | 14947.932 ns | 77568.000 ns | 12617.043 ns | 0.193x | 1.175x | 5.77% / 0.63% / 3.60% | 11/11 / 1/11 | noisy |
| 数值边界 | decode | UInt64Envelope | bytes | 11 | 11950.984 ns | 79814.095 ns | 12507.028 ns | 0.149x | 0.956x | 2.93% / 2.45% / 4.63% | 11/11 / 11/11 | stable |
| 数值边界 | decode | UInt64Envelope | string | 11 | 11872.715 ns | 83904.000 ns | 11789.424 ns | 0.142x | 0.971x | 1.86% / 2.44% / 12.88% | 11/11 / 7/11 | noisy |
| 数值边界 | encode | UInt64Envelope | bytes | 11 | 9819.733 ns | 75477.333 ns | 9477.271 ns | 0.130x | 1.036x | 0.86% / 2.81% / 2.19% | 11/11 / 1/11 | stable |
| 数值边界 | encode | UInt64Envelope | string | 11 | 10246.054 ns | 75605.333 ns | 9748.213 ns | 0.135x | 1.030x | 1.03% / 1.02% / 2.87% | 11/11 / 2/11 | stable |
| 时间/大数 | decode | TemporalStats | bytes | 11 | 7364.982 ns | 97664.000 ns | 33212.747 ns | 0.075x | 0.219x | 1.12% / 1.71% / 5.95% | 11/11 / 11/11 | noisy |
| 时间/大数 | decode | TemporalStats | string | 11 | 7213.196 ns | 97002.667 ns | 31611.210 ns | 0.074x | 0.224x | 2.75% / 1.33% / 6.12% | 11/11 / 11/11 | noisy |
| 时间/大数 | encode | TemporalStats | bytes | 11 | 20667.556 ns | 80839.111 ns | 21818.667 ns | 0.256x | 0.946x | 0.82% / 0.89% / 2.51% | 11/11 / 10/11 | stable |
| 时间/大数 | encode | TemporalStats | string | 11 | 21376.000 ns | 81272.471 ns | 21920.000 ns | 0.262x | 0.978x | 2.15% / 1.34% / 1.41% | 11/11 / 9/11 | stable |
| 未知字段 | decode | Person | string | 11 | 8811.176 ns | 105472.000 ns | 17192.633 ns | 0.084x | 0.504x | 5.68% / 2.01% / 7.22% | 11/11 / 11/11 | noisy |
| 流式 I/O | decode | Person | stream | 11 | 15786.667 ns | 87239.111 ns | 16847.282 ns | 0.181x | 0.922x | 8.82% / 1.63% / 5.88% | 11/11 / 8/11 | noisy |
| 流式 I/O | encode | Person | stream | 11 | 6144.578 ns | 77482.667 ns | 10774.159 ns | 0.080x | 0.603x | 8.59% / 7.18% / 9.78% | 11/11 / 11/11 | noisy |
| 深层嵌套 | decode | ArrayList<HashMap<String, ArrayList<ProfileRecord>>> | string | 11 | 76243.556 ns | 606720.000 ns | 96768.000 ns | 0.124x | 0.792x | 2.16% / 2.17% / 1.75% | 11/11 / 11/11 | stable |
| 深层嵌套 | encode | ArrayList<HashMap<String, ArrayList<ProfileRecord>>> | string | 11 | 98688.000 ns | 277433.983 ns | 74410.667 ns | 0.354x | 1.337x | 1.24% / 7.02% / 1.18% | 11/11 / 0/11 | noisy |
| 转义/Unicode | decode | String | bytes | 11 | 2461.144 ns | 30176.000 ns | 1840.929 ns | 0.082x | 1.336x | 0.75% / 2.41% / 11.56% | 11/11 / 0/11 | noisy |
| 转义/Unicode | decode | String | string | 11 | 2516.395 ns | 29952.000 ns | 2365.066 ns | 0.085x | 1.071x | 3.71% / 2.17% / 11.54% | 11/11 / 4/11 | noisy |
| 转义/Unicode | encode | String | bytes | 11 | 1515.733 ns | 56246.857 ns | 2452.042 ns | 0.027x | 0.615x | 1.68% / 5.79% / 12.41% | 11/11 / 11/11 | noisy |
| 转义/Unicode | encode | String | string | 11 | 1416.140 ns | 56480.000 ns | 3192.879 ns | 0.025x | 0.491x | 11.87% / 6.95% / 13.57% | 11/11 / 11/11 | noisy |
