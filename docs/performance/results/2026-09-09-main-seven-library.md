# 2026-09-09 当前 `main` 七库完整对比

本页记录 [`current-main.json`](../../../benchmarks/results/full-seven-library/current-main.json)
指向的 typed JSON benchmark。测量绑定到提交
`bddbe6e022f8809b33f42141d5ac54dc2e081406`。两批都完成了规定的 770 个测量单元，但
每一行都至少有一个库的 CV 超过 5%。这是一份 noisy 延迟快照，不是 release qualification。

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
| 第一批 | 770/770 | 0/10 | 按规则完整重跑 |
| 第二批 | 770/770 | 0/10 | 保留两批并标记 noisy，不再重跑 |

README 展示第二批完整表，不合并两批，也不从两批中挑选更好的数字。

## 第一批

| Workload | yjson | stdx.json | cangjieJSON | json4cj | cjfast_json | Jackson | fastjson2 | Max CV |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Address encode | 1.043 | 3.145 | 3.133 | 3.457 | 2.480 | 0.178 | 0.066 | 10.77% |
| Address decode | 1.495 | 2.443 | 3.372 | 3.442 | 2.042 | 0.324 | 0.072 | 9.12% |
| Person encode | 1.713 | 13.228 | 17.094 | 5.451 | 9.943 | 0.568 | 0.267 | 14.57% |
| Person decode | 8.209 | 21.457 | 26.841 | 20.213 | 15.516 | 1.108 | 0.421 | 20.59% |
| Large Array encode | 28.672 | 88.993 | 250.059 | 91.822 | 75.814 | 9.186 | 4.147 | 19.21% |
| Large Array decode | 108.629 | 178.466 | 418.215 | 173.888 | 78.176 | 18.734 | 5.029 | 16.31% |
| Large Map encode | 6.893 | 130.176 | 174.753 | 132.022 | 130.475 | 1.774 | 1.743 | 6.18% |
| Large Map decode | 36.128 | 249.687 | 309.894 | 221.890 | 231.899 | 5.376 | 3.975 | 13.41% |
| Deep Nested encode | 47.797 | 80.448 | 171.817 | 85.248 | 74.496 | 4.521 | 2.466 | 8.34% |
| Deep Nested decode | 325.760 | 156.603 | 222.966 | 141.814 | 96.393 | 10.408 | 3.429 | 10.78% |

## 第二批

| Workload | yjson | stdx.json | cangjieJSON | json4cj | cjfast_json | Jackson | fastjson2 | Max CV |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Address encode | 1.050 | 3.002 | 3.107 | 3.426 | 2.457 | 0.180 | 0.066 | 9.36% |
| Address decode | 1.509 | 2.439 | 3.545 | 3.437 | 2.008 | 0.322 | 0.074 | 9.33% |
| Person encode | 1.717 | 12.660 | 17.746 | 5.463 | 10.003 | 0.562 | 0.267 | 11.20% |
| Person decode | 8.094 | 21.504 | 27.952 | 20.632 | 15.347 | 1.114 | 0.420 | 8.45% |
| Large Array encode | 28.465 | 93.706 | 249.131 | 92.416 | 75.729 | 9.060 | 4.163 | 6.81% |
| Large Array decode | 107.986 | 182.805 | 421.106 | 174.720 | 78.080 | 19.057 | 5.064 | 13.88% |
| Large Map encode | 6.779 | 129.396 | 174.803 | 127.590 | 132.165 | 1.727 | 1.734 | 6.71% |
| Large Map decode | 33.280 | 248.149 | 350.976 | 222.605 | 228.864 | 5.297 | 3.955 | 16.32% |
| Deep Nested encode | 47.031 | 80.576 | 172.032 | 85.376 | 74.496 | 4.486 | 2.460 | 14.04% |
| Deep Nested decode | 306.889 | 164.182 | 248.285 | 141.824 | 96.256 | 10.413 | 3.425 | 16.32% |

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
| 产品源码 | commit `bddbe6e022f8809b33f42141d5ac54dc2e081406` |
| Product source SHA-256 | `df9108e367363847b0fd59b3c611cc6a3504f4d426152e13479caf3e8b94d7f9` |
| Effective harness SHA-256 | `4d5788b785c9b69993f91e78934dcb5e21fca8b9ac2b2a7c6986c115e65e0865` |
| Cangjie | `1.1.0-alpha.20260803040049`、cjpm 1.1.3、stdx 0.0.3 |
| Java | OpenJDK 17.0.20、JMH 1.37、Jackson 2.18.2、fastjson2 2.0.52 |
| 主机 | Linux x86_64、Intel Xeon Gold 6248R、128 MiB heap |
| 第一批 CPU | CPU 4、sibling 52；30 秒采样均为 0.0% |
| 第二批 CPU | CPU 4、sibling 52；30 秒采样均为 0.0% |

每一轮都会轮转 workload 和七库顺序，偶数轮再反转 workload 顺序。Cangjie 使用 200 ms
warmup、至少 1 秒测量和至少 12 个 batch。Java 每个外层轮次使用一个 fork、3 × 500 ms
warmup 和 1 × 1 秒测量。

跨 runtime 数字只描述这台主机、这些版本、这些 API 和这些 payload。它们不是语言排名，
也不能推导 allocation、RSS、峰值内存或其他 payload 的吞吐。

## 证据与 freshness gate

证据目录保存两批 raw report、日志、manifest、metadata、派生 summary、实际 harness 源码、
json4cj source-only 快照、构建日志和 checksum：

[`benchmarks/results/full-seven-library/2026-09-09-main-bddbe6e`](../../../benchmarks/results/full-seven-library/2026-09-09-main-bddbe6e/README.md)

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
