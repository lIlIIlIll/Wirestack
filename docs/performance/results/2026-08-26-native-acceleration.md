# 2026-08-26 Native 单引擎加速门禁

本页比较同一份源码、同一 `YJson` API 在 Pure 与
`YJsonNativeAccel.initialize()` 两种进程冻结状态下的表现。它不是 Native DOM 与 Pure DOM
的 backend 排名。

## 冻结身份

| 项目 | 值 |
| --- | --- |
| Source digest | `794d2b70dd3fdc7e37864c33f81c30583b2d269c0dc48aa7912a7bd66bb1e9ac` |
| Runner | Linux x86_64 Server，8 个可用 CPU，固定单 CPU affinity |
| OS / libc | Linux 5.15，glibc 2.35 |
| Cangjie | `1.1.0-alpha.20260817040003` |
| cjpm | `1.1.3` |
| Heap | 128 MiB |
| Protocol | 11 轮；Pure/Native 独立进程；逐轮交替顺序 |

runner 在计时前验证 fixture roundtrip，并对每份 raw report 计算 SHA-256。以下批次是 source
digest 不变后复用同一 build 的完整重跑；所有行双方 CV 均不超过 5%。

## 结果

`N/P` 为 Native median / Pure median，小于 1 表示 Native 延迟更低。

| Case | Pure median ns | Native median ns | N/P | Native wins | CV P/N | Gate role | Gate |
| --- | ---: | ---: | ---: | ---: | ---: | --- | --- |
| `writeNumericArray` | 7180320.00 | 7291876.81 | 1.016 | 4/11 | 2.59% / 4.47% | ordinary | pass |
| `writeNumericBytes` | 2111898.45 | 591898.26 | 0.280 | 11/11 | 2.74% / 4.20% | advertised write | pass |
| `readNumericArray` | 2760609.94 | 2881797.95 | 1.044 | 1/11 | 3.71% / 3.90% | ordinary | pass |
| `readNumericDocument` | 2100342.86 | 1278928.70 | 0.609 | 11/11 | 3.80% / 4.35% | advertised read | pass |
| `writeEscapedStrings` | 1461523.86 | 1462656.00 | 1.001 | 5/11 | 3.05% / 1.12% | ordinary | pass |
| `writeEscapedBytes` | 1352128.00 | 1348681.60 | 0.997 | 8/11 | 1.89% / 2.30% | ordinary | pass |
| `writePlainStrings` | 1224842.97 | 1239552.00 | 1.012 | 4/11 | 4.62% / 3.59% | ordinary | pass |

## 可陈述结论

- 广告 write workload `writeNumericBytes` 的 median 为 Pure 的 28.0%，11/11 配对获胜。
- 广告 read workload `readNumericDocument` 的 median 为 Pure 的 60.9%，11/11 配对获胜；返回
  的仍是 managed Compact document，不需要 `close()`。
- 五个普通 workload 全部在 5% regression 上限内；其中最大观测回退是
  `readNumericArray` 的 4.4%。
- 不能据此宣称 typed numeric array read 已加速：该行 N/P 为 1.044，且只赢 1/11。

判定规则和复测政策见[性能测量方法](../methodology.md)。这些比例只适用于上表源码、SDK、
主机和 workload；后续源码必须生成新的带日期结果，不能覆写本页。
