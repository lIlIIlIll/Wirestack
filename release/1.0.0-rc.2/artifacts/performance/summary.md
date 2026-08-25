# yjson / stdx.json / cjfast_json release benchmark

Every matched workload is included. CV changes only the stable/noisy label; it never removes a row.

- Complete workloads: 36
- Stable workloads (all libraries CV <= 5.00%): 13
- Noisy workloads retained: 23

| Scenario | Operation | Payload | Input | Runs | yjson median | stdx median | cjfast median | Y/S | Y/C | CV Y/S/C | yjson faster pairs S/C | Status |
|:--|:--|:--|:--|--:|--:|--:|--:|--:|--:|--:|--:|:--|
| Pretty JSON | decode | Person | string | 11 | 7040.000 ns | 97312.000 ns | 16323.998 ns | 0.072x | 0.424x | 5.36% / 2.55% / 5.45% | 11/11 / 11/11 | noisy |
| Pretty JSON | encode | Person | string | 11 | 8235.914 ns | 83507.200 ns | 10929.781 ns | 0.098x | 0.752x | 6.18% / 1.03% / 10.34% | 11/11 / 11/11 | noisy |
| 基础对象 | decode | Address | bytes | 11 | 1323.801 ns | 35196.121 ns | 1974.055 ns | 0.037x | 0.669x | 2.55% / 2.16% / 0.52% | 11/11 / 11/11 | stable |
| 基础对象 | decode | Address | string | 11 | 1168.917 ns | 35381.126 ns | 2035.944 ns | 0.033x | 0.573x | 6.72% / 0.17% / 6.08% | 11/11 / 11/11 | noisy |
| 基础对象 | decode | Person | bytes | 11 | 9553.002 ns | 87936.000 ns | 16020.610 ns | 0.106x | 0.605x | 8.13% / 7.95% / 6.03% | 11/11 / 11/11 | noisy |
| 基础对象 | decode | Person | string | 11 | 10907.009 ns | 87523.556 ns | 15357.284 ns | 0.119x | 0.661x | 14.07% / 4.96% / 5.22% | 11/11 / 11/11 | noisy |
| 基础对象 | encode | Address | bytes | 11 | 1787.195 ns | 56274.824 ns | 2453.216 ns | 0.032x | 0.729x | 8.56% / 0.75% / 13.91% | 11/11 / 11/11 | noisy |
| 基础对象 | encode | Address | string | 11 | 1585.237 ns | 56473.011 ns | 2467.213 ns | 0.028x | 0.597x | 9.83% / 0.50% / 12.85% | 11/11 / 11/11 | noisy |
| 基础对象 | encode | Person | bytes | 11 | 3778.071 ns | 76117.333 ns | 9942.931 ns | 0.049x | 0.379x | 0.71% / 0.90% / 12.71% | 11/11 / 11/11 | noisy |
| 基础对象 | encode | Person | string | 11 | 4191.488 ns | 76600.889 ns | 10794.565 ns | 0.054x | 0.389x | 3.45% / 0.82% / 9.87% | 11/11 / 11/11 | noisy |
| 大 Map | decode | HashMap<String, Int64>[64] | string | 11 | 210261.333 ns | 589312.000 ns | 239181.395 ns | 0.348x | 0.877x | 4.06% / 3.46% / 4.10% | 11/11 / 11/11 | stable |
| 大 Map | encode | HashMap<String, Int64>[64] | string | 11 | 120093.538 ns | 259263.379 ns | 131072.000 ns | 0.465x | 0.917x | 1.58% / 3.08% / 0.91% | 11/11 / 11/11 | stable |
| 大数组 | decode | ArrayList<ProfileRecord>[64] | string | 11 | 43797.333 ns | 971497.412 ns | 78023.111 ns | 0.046x | 0.566x | 5.25% / 4.06% / 3.73% | 11/11 / 11/11 | noisy |
| 大数组 | encode | ArrayList<ProfileRecord>[64] | string | 11 | 107814.400 ns | 480393.846 ns | 75520.000 ns | 0.237x | 1.432x | 3.11% / 11.86% / 0.56% | 11/11 / 0/11 | noisy |
| 字段顺序 | decode | Person | string | 11 | 6657.150 ns | 87652.571 ns | 17613.802 ns | 0.075x | 0.385x | 2.63% / 0.87% / 5.68% | 11/11 / 11/11 | noisy |
| 嵌套对象 | decode | ProfileBundle | bytes | 11 | 13960.924 ns | 93029.333 ns | 15619.273 ns | 0.150x | 0.894x | 2.62% / 1.58% / 5.39% | 11/11 / 11/11 | noisy |
| 嵌套对象 | decode | ProfileBundle | string | 11 | 13608.172 ns | 93209.600 ns | 15597.207 ns | 0.145x | 0.849x | 2.18% / 0.64% / 4.83% | 11/11 / 11/11 | stable |
| 嵌套对象 | encode | ProfileBundle | bytes | 11 | 14528.000 ns | 76826.566 ns | 12656.762 ns | 0.189x | 1.145x | 2.31% / 0.74% / 2.77% | 11/11 / 0/11 | stable |
| 嵌套对象 | encode | ProfileBundle | string | 11 | 15137.295 ns | 77193.846 ns | 12141.534 ns | 0.196x | 1.238x | 3.99% / 0.53% / 4.36% | 11/11 / 0/11 | stable |
| 数值边界 | decode | UInt64Envelope | bytes | 11 | 12051.744 ns | 80110.933 ns | 12328.727 ns | 0.150x | 0.977x | 2.06% / 2.22% / 4.00% | 11/11 / 10/11 | stable |
| 数值边界 | decode | UInt64Envelope | string | 11 | 11903.492 ns | 80183.273 ns | 11160.635 ns | 0.145x | 1.087x | 2.29% / 2.71% / 14.47% | 11/11 / 5/11 | noisy |
| 数值边界 | encode | UInt64Envelope | bytes | 11 | 9892.214 ns | 76320.000 ns | 9614.166 ns | 0.130x | 1.024x | 0.73% / 3.50% / 3.27% | 11/11 / 4/11 | stable |
| 数值边界 | encode | UInt64Envelope | string | 11 | 10327.843 ns | 75346.051 ns | 9729.788 ns | 0.137x | 1.027x | 2.74% / 1.34% / 3.61% | 11/11 / 3/11 | stable |
| 时间/大数 | decode | TemporalStats | bytes | 11 | 7444.101 ns | 96896.000 ns | 32118.389 ns | 0.077x | 0.232x | 0.77% / 1.82% / 4.83% | 11/11 / 11/11 | stable |
| 时间/大数 | decode | TemporalStats | string | 11 | 7258.922 ns | 96896.000 ns | 31121.762 ns | 0.075x | 0.232x | 0.79% / 1.04% / 4.86% | 11/11 / 11/11 | stable |
| 时间/大数 | encode | TemporalStats | bytes | 11 | 20753.903 ns | 81024.000 ns | 21760.000 ns | 0.255x | 0.956x | 0.77% / 2.21% / 1.73% | 11/11 / 11/11 | stable |
| 时间/大数 | encode | TemporalStats | string | 11 | 21163.055 ns | 81277.264 ns | 21824.000 ns | 0.261x | 0.971x | 2.15% / 1.15% / 1.19% | 11/11 / 10/11 | stable |
| 未知字段 | decode | Person | string | 11 | 8680.600 ns | 106188.800 ns | 17667.240 ns | 0.081x | 0.491x | 3.66% / 2.12% / 9.46% | 11/11 / 11/11 | noisy |
| 流式 I/O | decode | Person | stream | 11 | 15510.284 ns | 91340.800 ns | 15696.879 ns | 0.171x | 0.952x | 4.87% / 2.78% / 5.65% | 11/11 / 9/11 | noisy |
| 流式 I/O | encode | Person | stream | 11 | 6154.406 ns | 76726.857 ns | 9806.344 ns | 0.080x | 0.636x | 7.52% / 13.46% / 8.07% | 11/11 / 11/11 | noisy |
| 深层嵌套 | decode | ArrayList<HashMap<String, ArrayList<ProfileRecord>>> | string | 11 | 76949.333 ns | 604160.000 ns | 96358.400 ns | 0.126x | 0.799x | 4.13% / 5.98% / 0.73% | 11/11 / 11/11 | noisy |
| 深层嵌套 | encode | ArrayList<HashMap<String, ArrayList<ProfileRecord>>> | string | 11 | 98304.000 ns | 281681.748 ns | 74339.200 ns | 0.356x | 1.321x | 0.88% / 7.89% / 1.94% | 11/11 / 0/11 | noisy |
| 转义/Unicode | decode | String | bytes | 11 | 2389.472 ns | 30037.333 ns | 1832.902 ns | 0.083x | 1.272x | 5.40% / 2.41% / 9.16% | 11/11 / 1/11 | noisy |
| 转义/Unicode | decode | String | string | 11 | 2545.233 ns | 28828.061 ns | 2356.750 ns | 0.088x | 1.076x | 1.00% / 1.91% / 11.29% | 11/11 / 2/11 | noisy |
| 转义/Unicode | encode | String | bytes | 11 | 1505.230 ns | 56192.000 ns | 2466.590 ns | 0.027x | 0.554x | 3.32% / 2.41% / 11.40% | 11/11 / 11/11 | noisy |
| 转义/Unicode | encode | String | string | 11 | 1455.179 ns | 56210.286 ns | 3285.067 ns | 0.026x | 0.447x | 10.07% / 17.88% / 7.97% | 11/11 / 11/11 | noisy |
