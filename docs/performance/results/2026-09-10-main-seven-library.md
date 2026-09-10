# 2026-09-10 当前 `main` 七库完整对比

本页记录 [`current-main.json`](../../../benchmarks/results/full-seven-library/current-main.json) 指向的 typed JSON benchmark。测量绑定到提交
`2758853efe1117c7d2b272abd36cf90de46526f5`。两批都完成了规定的 770 个测量单元；第一批 5/10、第二批 0/10 个 workload 满足 Max CV <= 5%，其余结果保留为 noisy。

## 先看 workload

Encode 从已经构造好的 typed value 生成紧凑 JSON 字符串。Decode 从 canonical JSON 字符串
恢复相同的 typed 类型。表中的 payload bytes 是 decode 输入的 UTF-8 大小。

| Workload | Typed value 的形状 | 规模 | Payload bytes |
| --- | --- | ---: | ---: |
| Address | `Address{street_name: String, zipcode: Int64}` | 2 个字段 | 47 |
| Person | 3 个字符串 tag、2 个整数 score、嵌套 Address 和 null nick | 7 个 JSON 字段 | 176 |
| Large Array | `ArrayList<ProfileRecord>`；每条记录有 id、alias 和 level | 64 条记录 | 3929 |
| Large Map | `HashMap<String, Int64>`；key 为 `metric_0` 到 `metric_63` | 64 个 entry | 1013 |
| Deep Nested | `ArrayList<HashMap<String, ArrayList<ProfileRecord>>>` | 8 组 × 4 条记录，共 32 条 | 1929 |

Large Array 测试大量同类型对象。Large Map 测试 String key 和 Int64 密集路径。Deep Nested
测试三层容器、32 个 generated record，以及每层容器的读写开销。它不是“大文档”吞吐测试。

## 结果状态

每个 workload-library 组合运行 11 个独立进程轮次。每个表格单元格是这 11 个轮次的中位数，
单位为 µs/op，越小越好。`Max CV` 是该 workload 在七个库中的最大 CV。只有
`Max CV <= 5%` 的行才是 stable。

| 批次 | 完整测量单元 | Stable workloads | 结论 |
| --- | ---: | ---: | --- |
| 第一批 | 770/770 | 5/10 | 按规则完整重跑 |
| 第二批 | 770/770 | 0/10 | 保留两批并标记 noisy，不再重跑 |

README 展示第二批完整表，不合并两批，也不从两批中挑选更好的数字。

## 第一批

| Workload | yjson | stdx.json | cangjieJSON | json4cj | cjfast_json | Jackson | fastjson2 | Max CV |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Address encode | 0.255 | 0.661 | 0.669 | 0.687 | 0.567 | 0.107 | 0.047 | 11.70% |
| Address decode | 0.137 | 1.075 | 0.360 | 1.250 | 0.478 | 0.181 | 0.040 | 11.39% |
| Person encode | 0.666 | 2.472 | 3.953 | 1.575 | 2.288 | 0.315 | 0.137 | 4.99% |
| Person decode | 0.964 | 4.634 | 3.119 | 5.364 | 3.090 | 0.644 | 0.226 | 5.55% |
| Large Array encode | 10.725 | 22.242 | 58.059 | 26.119 | 19.274 | 4.558 | 2.821 | 9.23% |
| Large Array decode | 21.027 | 41.196 | 27.399 | 61.319 | 28.159 | 9.272 | 3.161 | 5.31% |
| Large Map encode | 2.120 | 15.924 | 32.529 | 19.622 | 16.915 | 1.551 | 1.074 | 4.18% |
| Large Map decode | 6.510 | 34.800 | 35.894 | 39.237 | 33.753 | 3.074 | 2.402 | 2.43% |
| Deep Nested encode | 11.780 | 17.314 | 36.504 | 20.273 | 15.149 | 2.542 | 1.478 | 4.45% |
| Deep Nested decode | 30.529 | 30.642 | 22.875 | 38.820 | 21.209 | 5.463 | 1.896 | 2.58% |

## 第二批

| Workload | yjson | stdx.json | cangjieJSON | json4cj | cjfast_json | Jackson | fastjson2 | Max CV |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Address encode | 0.297 | 0.724 | 0.770 | 0.777 | 0.649 | 0.119 | 0.051 | 13.49% |
| Address decode | 0.158 | 1.243 | 0.413 | 1.439 | 0.541 | 0.203 | 0.044 | 13.93% |
| Person encode | 0.767 | 2.870 | 4.557 | 1.813 | 2.626 | 0.362 | 0.151 | 8.66% |
| Person decode | 1.081 | 5.258 | 3.464 | 5.995 | 3.508 | 0.721 | 0.254 | 9.30% |
| Large Array encode | 11.987 | 24.691 | 65.484 | 29.276 | 21.757 | 5.063 | 2.794 | 9.26% |
| Large Array decode | 23.765 | 46.327 | 30.231 | 69.087 | 31.836 | 10.077 | 3.420 | 8.56% |
| Large Map encode | 2.350 | 17.590 | 36.412 | 21.804 | 19.560 | 1.650 | 1.176 | 8.08% |
| Large Map decode | 7.355 | 39.397 | 40.563 | 44.449 | 37.728 | 3.350 | 2.660 | 8.53% |
| Deep Nested encode | 13.125 | 19.467 | 41.231 | 22.654 | 17.022 | 2.809 | 1.575 | 9.43% |
| Deep Nested decode | 33.975 | 34.780 | 25.950 | 44.101 | 24.069 | 6.121 | 2.081 | 8.07% |

## 各库使用的 API

每个 adapter 使用语义等价的最快公开 typed API。存在 direct typed path 时，不使用 DOM
fallback。内部只提供 DOM-backed typed path 的库仍使用该公开入口。

| 库 | 测量路径 |
| --- | --- |
| yjson | 缓存具体 `JsonCodec`；generated object decode 缓存 `YJson.fastDecoder` |
| stdx.json | 以 `ByteBuffer` 直接驱动 `JsonWriter` 和 `JsonReader`；类型实现 `JsonSerializable` 和 `JsonDeserializable` |
| cangjieJSON | `@JsonAdapter` 生成的 `toJson` 和 `fromJson`；该公开 typed path 内部使用 DOM |
| json4cj | `@Codable` 生成的 encode/decode；根容器使用公开 built-in encoder 和 decoder |
| cjfast_json | `@JsonAdapter` 生成的 `toJson` 和 `fromJson` |
| Jackson | 缓存具体或 generic `ObjectWriter` 和 `ObjectReader` |
| fastjson2 | 缓存具体或 generic `ObjectWriter` 和 `ObjectReader`；每次 operation 创建 `JSONWriter` 或 `JSONReader` |

## 测量环境

| 项目 | 值 |
| --- | --- |
| 产品源码 | commit `2758853efe1117c7d2b272abd36cf90de46526f5` |
| Product source SHA-256 | `6056f53aa56767a69a29685dad1d6b8fadd8c39a7b47ca6ecc60b46f114acb0b` |
| Effective harness SHA-256 | `4d5788b785c9b69993f91e78934dcb5e21fca8b9ac2b2a7c6986c115e65e0865` |
| Cangjie | `1.3.0-alpha.20260829010011`、cjpm 1.1.3、stdx 0.0.3 |
| Java | `openjdk version "17.0.20.1" 2026-08-18`、JMH 1.37、Jackson 2.18.2、fastjson2 2.0.52 |
| 主机 | `Linux-6.17.0-1022-azure-x86_64-with-glibc2.39`、128 MiB heap |
| 第一批 CPU | CPU 2（sibling 3）；30 秒采样中两个 hardware thread 的利用率为 0.10%、0.10%。 |
| 第二批 CPU | CPU 2（sibling 3）；30 秒采样中两个 hardware thread 的利用率为 0.10%、0.10%。 |

每一轮都会轮转 workload 和七库顺序，偶数轮再反转 workload 顺序。Cangjie 使用 200 ms
warmup、至少 1 秒测量和至少 12 个 batch。Java 每个外层轮次使用一个 fork、3 × 500 ms
warmup 和 1 × 1 秒测量。

跨 runtime 数字只描述这台主机、这些版本、这些 API 和这些 payload。它们不是语言排名，
也不能推导 allocation、RSS、峰值内存或其他 payload 的吞吐。
## 证据与 freshness gate

证据目录保存两批 raw report、日志、manifest、metadata、派生 summary、实际 harness 源码、
json4cj source-only 快照、构建日志和 checksum：

[`benchmarks/results/full-seven-library/2026-09-09-main-bddbe6e`](../../../benchmarks/results/full-seven-library/2026-09-10-main-008e50b/README.md)

从仓库根目录运行：

```terminal
python3 scripts/check_seven_library_evidence.py
```

校验器会验证归档 checksum、安全解包、两批完整性、metadata 身份和可重生成的 summary。
它还要求 marker 的测量提交是当前提交的祖先，并重新计算当前 benchmark input closure 的摘要。
runtime、`@JsonCodec` 宏或 benchmark fixture 发生变化后，必须重跑 benchmark 并更新 marker；
独立 JSON literal 宏不属于这条 typed-codec closure，因此不会单独使这些结果失效。

最近一次通过 release qualification 的数据仍是
[yjson 2.0.0 性能验收](2026-08-27-yjson-2.0.0.md)。
