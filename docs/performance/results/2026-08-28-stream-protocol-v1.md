# 2026-08-28 Stream protocol v1 结果

本页记录 typed incremental Stream 的 previous-yjson baseline、内部 scratch 生命周期和 peer
比较。previous-yjson A/B 批次没有通过发布门槛，因此这些数字不构成 yjson 2.0.1 的 Stream
性能声明。

## 冻结身份

| 项目 | 值 |
| --- | --- |
| Previous-yjson | commit `eebd3a20531d225a76646fb0e08f37280fa3309d`，benchmark overlay `b882261a` |
| Candidate samples | source archive `14aaaf02674246b3594c3932cbd3c37894d6f34a98a11f23e9d787368b4e8923`，unpooled lifecycle |
| Peer candidate | source archive `4f167fb91eca97b21460b02d0e01e5175e8c31c37cbeab4fa0f4c5e41cd174a0`，实验池已撤回 |
| Runner | `ubuntu2223131`，Linux x86_64，Intel Xeon Gold 6248R，CPU 8 pinned |
| Heap | 128 MiB |
| SDK | Cangjie `1.1.0-alpha.20260803040049`，cjpm `1.1.3`，stdx `0.0.3` |
| Protocol | v1，cell-isolated，11 轮；660 个 previous-yjson A/B 进程，330 个 peer 进程 |
| Raw archive | `formal-cell-1.tar.gz`，SHA-256 `000fb3b9719859515a5806d304c89a0801e9fd523932ca74119484e4594fde14` |
| Peer archive | `peer-cell-1.tar.gz`，SHA-256 `5eebe1d05545ece3e3879d95ab8ca516b5681eb61da15f360fe3c078206731fe` |

原始 archive、manifest、机器汇总和 payload 位于
[`benchmarks/results/stream-v1/2026-08-28`](../../../benchmarks/results/stream-v1/2026-08-28/README.md)。
具体 JSON、大小和 SHA-256 见 [Stream workload 参考](../stream-workloads.md)。

## previous-yjson 与候选

每个单元格各用一个进程。表中延迟是 11 个 process median 的中位数。Improvement 是逐轮
配对改善率的中位数，正数表示候选更快。`CV B/C` 任一侧超过 5% 时，该行是 noisy。

| Case | Previous-yjson | Candidate | Improvement | Candidate wins | CV B/C | Stability |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| `decode-person-chunk-4k` | 48.922 µs | 18.531 µs | +61.94% | 11/11 | 9.53% / 7.21% | noisy |
| `decode-person-chunk-64` | 48.917 µs | 20.506 µs | +55.82% | 10/11 | 21.46% / 2.12% | noisy |
| `decode-person-chunk-random` | 48.831 µs | 18.264 µs | +62.58% | 11/11 | 14.38% / 17.56% | noisy |
| `decode-records-1m-chunk-4k` | 151.063 ms | 70.359 ms | +53.42% | 11/11 | 0.55% / 6.80% | noisy |
| `decode-records-1m-chunk-64` | 152.078 ms | 91.110 ms | +40.51% | 11/11 | 0.57% / 4.66% | stable |
| `decode-records-1m-chunk-random` | 151.162 ms | 69.937 ms | +53.73% | 11/11 | 0.46% / 9.26% | noisy |
| `decode-records-64k-chunk-4k` | 9.162 ms | 3.408 ms | +63.07% | 11/11 | 2.90% / 7.12% | noisy |
| `decode-records-64k-chunk-64` | 9.147 ms | 4.072 ms | +54.21% | 11/11 | 11.23% / 11.40% | noisy |
| `decode-records-64k-chunk-random` | 8.922 ms | 3.432 ms | +62.45% | 11/11 | 2.96% / 1.71% | stable |
| `encode-person-counting` | 7.808 µs | 8.078 µs | -8.67% | 5/11 | 25.80% / 18.62% | noisy |
| `encode-person-memory` | 7.507 µs | 7.963 µs | -4.48% | 3/11 | 24.56% / 15.95% | noisy |
| `encode-records-1m-counting` | 14.963 ms | 13.750 ms | +7.61% | 11/11 | 1.57% / 2.08% | stable |
| `encode-records-1m-memory` | 12.636 ms | 19.184 ms | -33.71% | 4/11 | 19.19% / 21.75% | noisy |
| `encode-records-64k-counting` | 1.267 ms | 1.239 ms | +2.48% | 9/11 | 1.96% / 2.67% | stable |
| `encode-records-64k-memory` | 1.167 ms | 1.199 ms | -2.86% | 3/11 | 2.42% / 13.95% | noisy |

所有 9 个 Decode 行的中位数方向都改善，候选赢 10/11 或 11/11。只有 1 MiB、64-byte
chunk 和 64 KiB、deterministic-random chunk 两行双方 CV 不超过 5%，可以引用精确改善率。
Encode 的稳定行没有超过 5% 的回退；1 MiB counting sink 改善 7.61%，64 KiB counting sink
改善 2.48%。

## 内部 scratch 生命周期

`Unpooled one-shot` 通过 benchmark-only 环境开关禁止复用 4 KiB scratch。`Pooled
steady-state` 使用实验候选的默认内部行为。两者都会为每次调用创建 reader、writer 和
context。生命周期门槛失败后，最终实现撤回了实验池，因此上面的 A/B 主表使用 unpooled
candidate 样本。

双方 CV 不超过 5% 的四行如下。Improvement 的正数表示 pooled 更快。

| Case | Unpooled | Pooled | Paired improvement | Pooled wins | CV U/P |
| --- | ---: | ---: | ---: | ---: | ---: |
| `decode-records-1m-chunk-64` | 91.110 ms | 88.562 ms | -0.78% | 5/11 | 4.66% / 3.83% |
| `decode-records-64k-chunk-random` | 3.432 ms | 3.434 ms | -0.17% | 5/11 | 1.71% / 0.54% |
| `encode-records-1m-counting` | 13.750 ms | 13.815 ms | -0.68% | 4/11 | 2.08% / 3.59% |
| `encode-records-64k-counting` | 1.239 ms | 1.232 ms | +0.68% | 6/11 | 2.67% / 4.80% |

这里的中位数差异都低于 1%。完整 15 行生命周期表位于
[`candidate-summary.md`](../../../benchmarks/results/stream-v1/2026-08-28/formal-cell-1/candidate-summary.md)。
scratch 复用只在一个 canonical payload 上呈现改善方向，没有达到两个 payload 的门槛。

## 门槛结果

| Gate | 结果 | 证据 |
| --- | --- | --- |
| 稳定核心行不回退超过 5% | PASS | 没有稳定行超过 5% 回退 |
| 两个 canonical Decode 行改善至少 5%，且赢至少 6/11 | FAIL | 三个 4096-byte chunk canonical 行的 candidate CV 都超过 5% |
| scratch 复用在至少两个 payload 上更快 | FAIL | 只有 `records-1m` 呈现改善方向 |
| 阻断行双方 CV 不超过 5% | FAIL | previous-yjson A/B 有 11 行超限；生命周期表也有 11 行超限 |

第二批完整正式运行仍有相同稳定性问题。结果按规则保留，不删除 outlier，也不继续选择性
重跑单行。

## Peer eligibility

| 实现 | Incremental decode | Streaming encode | 处理方式 |
| --- | --- | --- | --- |
| yjson | `YJson.fromStream<T>(InputStream)` | `YJson.toStream(value, OutputStream)` | 进入正式表 |
| stdx.json | `JsonReader(InputStream)` | `JsonWriter(OutputStream)` | 进入独立 11 轮配对表 |
| cjfast_json adapter | 只接受 `ByteBuffer` | 没有等价 caller-owned `OutputStream` adapter | `N/A` |

stdx.json 的配对结果使用同一 payload、chunk、sink、CPU 和 heap。该批次单独归档，避免与
previous-yjson A/B 生命周期维度混合。

## yjson 与 stdx.json

peer 批次为每个 case 和实现分别启动进程，共 330 个进程。`yjson/stdx` 小于 1 表示 yjson
延迟更低。双方 CV 都不超过 5% 的行标为 stable。

| Case | yjson | stdx.json | yjson/stdx | yjson wins | CV Y/S | Stability |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| `decode-person-chunk-4k` | 18.098 µs | 143.312 µs | 0.126x | 11/11 | 7.18% / 29.42% | noisy |
| `decode-person-chunk-64` | 20.862 µs | 88.430 µs | 0.236x | 11/11 | 1.52% / 35.69% | noisy |
| `decode-person-chunk-random` | 17.909 µs | 87.735 µs | 0.204x | 11/11 | 15.60% / 27.72% | noisy |
| `decode-records-1m-chunk-4k` | 75.827 ms | 181.590 ms | 0.418x | 11/11 | 7.25% / 2.74% | noisy |
| `decode-records-1m-chunk-64` | 93.447 ms | 191.492 ms | 0.488x | 11/11 | 3.41% / 3.01% | stable |
| `decode-records-1m-chunk-random` | 76.646 ms | 179.626 ms | 0.427x | 11/11 | 1.83% / 2.57% | stable |
| `decode-records-64k-chunk-4k` | 3.389 ms | 20.954 ms | 0.162x | 11/11 | 3.08% / 34.60% | noisy |
| `decode-records-64k-chunk-64` | 4.229 ms | 21.005 ms | 0.201x | 11/11 | 0.52% / 31.61% | noisy |
| `decode-records-64k-chunk-random` | 3.521 ms | 10.236 ms | 0.344x | 11/11 | 1.73% / 40.32% | noisy |
| `encode-person-counting` | 7.920 µs | 117.845 µs | 0.067x | 11/11 | 4.62% / 12.65% | noisy |
| `encode-person-memory` | 7.243 µs | 116.901 µs | 0.062x | 11/11 | 28.91% / 10.98% | noisy |
| `encode-records-1m-counting` | 14.737 ms | 110.584 ms | 0.133x | 11/11 | 2.30% / 0.83% | stable |
| `encode-records-1m-memory` | 12.528 ms | 109.380 ms | 0.115x | 11/11 | 16.21% / 0.68% | noisy |
| `encode-records-64k-counting` | 1.363 ms | 9.489 ms | 0.144x | 11/11 | 0.56% / 14.39% | noisy |
| `encode-records-64k-memory` | 1.245 ms | 5.567 ms | 0.224x | 11/11 | 1.73% / 15.33% | noisy |

yjson 在 15 行都赢 11/11。稳定行只有三个：1 MiB Decode 的 64-byte chunk 为 0.488x，
deterministic-random chunk 为 0.427x，1 MiB Encode 的 counting sink 为 0.133x。其余行只
保留方向证据，不用于精确比例声明。完整机器汇总见
[`peer-summary.md`](../../../benchmarks/results/stream-v1/2026-08-28/peer-cell-1/peer-summary.md)。

## 适用边界

结果只描述列出的 typed API、payload、chunk、sink、SDK 和主机。它不代表多文档 framing、
DOM、allocation、RSS、网络 I/O 或其他平台。测量规则见 [Stream 性能](../stream.md)与
[性能测量方法](../methodology.md)。
