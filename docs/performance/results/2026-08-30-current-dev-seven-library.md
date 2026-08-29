# 2026-08-30 当前 dev 七库完整对比

本页记录当前 `dev` 的同批次 typed JSON 对比。两批都完整，但稳定性门槛未通过。因此表中
数字只能作为当前实现的延迟快照，不能用于发布精确倍数。

## 测量身份

| 项目 | 值 |
| --- | --- |
| yjson 产品源码 | commit `1dedf2a6d959453a1d946d69da7ba0216b3d5d87` |
| yjson benchmark source digest | `7f49b9e433aad08de69d6f0a7d5bee4f7a2b313a89c5e06f5f14e1fb117c0f42` |
| Optimal API overlay | `optimal-api-overlay-current.patch`，SHA-256 `6837b8e3949e2a5bfd19cafde6813291248889a51b1c8cbd11b9c56c0dd81039` |
| cangjieJSON | commit `910fd9c61858f33b242a0076c22b2e06c8073511` |
| cjfast_json | commit `eefdedd1e53c93bb5ada11a96b9b81d88b2c6c65` |
| json4cj | source tree SHA-256 `e7ae4a06f149a311b98c5889b119201f5ab39f71f87e93aaf6a633f794103bae` |
| Java | OpenJDK 17.0.20、JMH 1.37、Jackson 2.18.2、fastjson2 2.0.52 |
| Cangjie | `1.1.0-alpha.20260803040049`、cjpm 1.1.3、stdx 0.0.3 |
| 主机 | Linux x86_64，Intel Xeon Gold 6248R，128 MiB heap |
| 第一批 | CPU 0，sibling 48，采样时两者利用率 0%，11 轮 |
| 第二批 | CPU 4，sibling 52，采样时两者利用率 0%，11 轮 |

每个 workload 和七库顺序按轮次轮转，偶数轮反转 workload 顺序。Cangjie 使用 200 ms
warmup、至少 1 秒测量和至少 12 个 batch。Java 每个外层轮次使用一个 fork、3 × 500 ms
warmup 和 1 × 1 秒测量。所有库使用语义等价的最快公开 typed API；存在 direct typed path
时不使用 DOM fallback。

Canonical decode payload 分别为 Address 47 bytes、Person 176 bytes、Large Array 3929 bytes、
Large Map 1013 bytes 和 Deep Nested 1929 bytes。

## 第一批

下表是 11 个独立进程轮次的中位数。`Max CV` 是该 workload 七个实现中的最大 CV。

| Workload | yjson | stdx.json | cangjieJSON | json4cj | cjfast_json | Jackson | fastjson2 | Max CV |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Address encode | 1.539 µs | 57.370 µs | 3.449 µs | 3.456 µs | 2.458 µs | 0.171 µs | 0.066 µs | 19.62% |
| Address decode | 0.814 µs | 37.248 µs | 3.306 µs | 3.454 µs | 2.015 µs | 0.310 µs | 0.069 µs | 8.70% |
| Person encode | 3.879 µs | 82.005 µs | 17.402 µs | 5.509 µs | 10.738 µs | 0.576 µs | 0.257 µs | 14.17% |
| Person decode | 10.064 µs | 99.132 µs | 28.129 µs | 22.464 µs | 15.552 µs | 1.139 µs | 0.427 µs | 10.16% |
| Large Array encode | 47.104 µs | 558.454 µs | 248.704 µs | 91.443 µs | 75.776 µs | 8.940 µs | 3.722 µs | 8.11% |
| Large Array decode | 47.663 µs | 1073.004 µs | 418.259 µs | 175.275 µs | 78.336 µs | 18.886 µs | 5.052 µs | 10.03% |
| Large Map encode | 7.168 µs | 284.001 µs | 174.493 µs | 126.797 µs | 129.586 µs | 1.851 µs | 1.741 µs | 15.74% |
| Large Map decode | 28.581 µs | 589.577 µs | 351.211 µs | 223.232 µs | 229.655 µs | 5.428 µs | 4.018 µs | 11.25% |
| Deep Nested encode | 61.184 µs | 363.048 µs | 171.648 µs | 85.606 µs | 73.865 µs | 4.506 µs | 2.604 µs | 6.53% |
| Deep Nested decode | 76.130 µs | 606.595 µs | 255.283 µs | 142.713 µs | 96.768 µs | 10.534 µs | 3.499 µs | 9.16% |

第一批 10 行都超过 5% CV 门槛，因此按规则完整重跑。

## 第二批

| Workload | yjson | stdx.json | cangjieJSON | json4cj | cjfast_json | Jackson | fastjson2 | Max CV |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Address encode | 1.564 µs | 92.127 µs | 2.836 µs | 3.398 µs | 2.946 µs | 0.170 µs | 0.064 µs | 18.90% |
| Address decode | 0.944 µs | 37.182 µs | 3.098 µs | 3.449 µs | 2.042 µs | 0.304 µs | 0.067 µs | 14.20% |
| Person encode | 3.836 µs | 123.469 µs | 16.211 µs | 5.465 µs | 10.058 µs | 0.584 µs | 0.264 µs | 9.54% |
| Person decode | 10.356 µs | 124.353 µs | 24.933 µs | 19.891 µs | 15.228 µs | 1.134 µs | 0.427 µs | 13.11% |
| Large Array encode | 72.185 µs | 633.995 µs | 265.352 µs | 92.306 µs | 76.370 µs | 8.927 µs | 3.961 µs | 16.32% |
| Large Array decode | 66.086 µs | 1100.139 µs | 316.129 µs | 211.037 µs | 80.198 µs | 18.932 µs | 5.107 µs | 9.26% |
| Large Map encode | 7.733 µs | 370.841 µs | 169.543 µs | 121.402 µs | 117.848 µs | 1.781 µs | 1.752 µs | 16.52% |
| Large Map decode | 33.637 µs | 716.636 µs | 293.737 µs | 222.504 µs | 202.004 µs | 5.277 µs | 3.933 µs | 20.68% |
| Deep Nested encode | 84.492 µs | 426.165 µs | 172.341 µs | 84.366 µs | 72.480 µs | 4.520 µs | 2.508 µs | 10.02% |
| Deep Nested decode | 94.873 µs | 784.964 µs | 222.617 µs | 144.320 µs | 93.575 µs | 10.533 µs | 3.395 µs | 9.46% |

第二批仍有 9.26% 到 20.68% 的最大 CV，10 行全部标记 noisy。按照固定规则不再继续重跑。
表中可讨论观察方向，不能发布精确比例或把某一批中更好的数字挑出作为结果。

## API 与证据边界

- yjson 缓存具体 typed codec；generated object decode 使用缓存的 `YJson.fastDecoder`。
- stdx.json 使用 `JsonSerializable`、`JsonDeserializable`、`JsonWriter` 和 `JsonReader`。
- cangjieJSON 与 cjfast_json 使用 `@JsonAdapter` 生成的 `toJson` 和 `fromJson`。
- json4cj 使用 `@Codable` 生成路径；根容器使用公开 built-in encoder 和 decoder。
- Jackson 和 fastjson2 缓存具体或 generic `ObjectWriter`、`ObjectReader`。

两批归档包含 raw report、每次运行日志、manifest、metadata、summary JSON、CSV 和 Markdown，以及
`COMPLETE` 标记。证据入口和校验命令见
[`benchmarks/results/full-seven-library/2026-08-30`](../../../benchmarks/results/full-seven-library/2026-08-30/README.md)。

该结果不覆盖 2.0.0 的 release qualification，也不证明 allocation、RSS 或 peak memory。
本结果文档及证据提交不改变表中绑定的产品源码。
