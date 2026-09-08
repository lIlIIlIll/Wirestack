# 2026-09-07 当前 `main` 七库完整对比

本页记录 [`current-main.json`](../../../benchmarks/results/full-seven-library/current-main.json)
指向的 typed JSON benchmark。测量绑定到提交
`3df280151b3a3a818c6ad75c254750a19d25e5a1`。两批都完成了规定的 770 个测量单元，但
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
| Address encode | 1.335 | 3.327 | 2.818 | 3.403 | 3.074 | 0.169 | 0.065 | 8.71% |
| Address decode | 1.525 | 2.396 | 3.095 | 3.479 | 2.048 | 0.306 | 0.067 | 8.72% |
| Person encode | 2.763 | 12.594 | 16.445 | 5.512 | 10.978 | 0.580 | 0.270 | 14.93% |
| Person decode | 8.167 | 21.310 | 24.308 | 19.802 | 15.182 | 1.121 | 0.430 | 28.24% |
| Large Array encode | 30.230 | 112.132 | 265.465 | 101.188 | 77.248 | 8.920 | 3.802 | 15.83% |
| Large Array decode | 128.152 | 211.058 | 300.719 | 211.251 | 78.308 | 18.481 | 5.092 | 12.26% |
| Large Map encode | 6.911 | 135.700 | 160.250 | 126.506 | 116.736 | 1.817 | 1.745 | 16.39% |
| Large Map decode | 51.833 | 316.007 | 304.152 | 224.736 | 221.318 | 5.110 | 3.910 | 19.53% |
| Deep Nested encode | 47.279 | 101.470 | 172.963 | 84.190 | 70.612 | 4.515 | 2.516 | 18.61% |
| Deep Nested decode | 381.001 | 199.987 | 234.134 | 146.717 | 96.256 | 10.349 | 3.381 | 10.03% |

## 第二批

| Workload | yjson | stdx.json | cangjieJSON | json4cj | cjfast_json | Jackson | fastjson2 | Max CV |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Address encode | 1.352 | 3.328 | 3.012 | 3.439 | 2.993 | 0.171 | 0.064 | 6.99% |
| Address decode | 1.441 | 2.272 | 3.141 | 3.463 | 2.041 | 0.303 | 0.068 | 9.44% |
| Person encode | 2.790 | 12.451 | 16.228 | 5.522 | 10.807 | 0.576 | 0.268 | 20.78% |
| Person decode | 8.787 | 21.528 | 23.434 | 19.803 | 15.000 | 1.132 | 0.428 | 17.24% |
| Large Array encode | 29.947 | 110.982 | 266.532 | 92.128 | 75.797 | 8.948 | 4.195 | 17.07% |
| Large Array decode | 128.124 | 205.158 | 311.836 | 222.162 | 84.072 | 18.560 | 5.028 | 9.23% |
| Large Map encode | 6.865 | 140.355 | 159.085 | 125.937 | 105.971 | 1.809 | 1.732 | 17.62% |
| Large Map decode | 50.537 | 306.371 | 297.182 | 220.016 | 211.071 | 5.054 | 4.013 | 15.02% |
| Deep Nested encode | 48.196 | 100.192 | 173.245 | 80.522 | 68.255 | 4.486 | 2.654 | 14.98% |
| Deep Nested decode | 371.596 | 197.669 | 242.864 | 141.084 | 96.716 | 10.453 | 3.377 | 8.59% |

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
| 产品源码 | commit `3df280151b3a3a818c6ad75c254750a19d25e5a1` |
| Product source SHA-256 | `ef4b24f136e2916306e13c6e635e078433160e5c5ca93d50032f8033d8d309a9` |
| Effective harness SHA-256 | `db8e1c8a67f64753cc85c40fa31f8b1a7da7c523fdb204ee6581cae7cca5a4ca` |
| Cangjie | `1.1.0-alpha.20260803040049`、cjpm 1.1.3、stdx 0.0.3 |
| Java | OpenJDK 17.0.20、JMH 1.37、Jackson 2.18.2、fastjson2 2.0.52 |
| 主机 | Linux x86_64、Intel Xeon Gold 6248R、128 MiB heap |
| 第一批 CPU | CPU 2、sibling 50；30 秒采样均为 0.0% |
| 第二批 CPU | CPU 4、sibling 52；30 秒采样均为 0.0% |

每一轮都会轮转 workload 和七库顺序，偶数轮再反转 workload 顺序。Cangjie 使用 200 ms
warmup、至少 1 秒测量和至少 12 个 batch。Java 每个外层轮次使用一个 fork、3 × 500 ms
warmup 和 1 × 1 秒测量。

跨 runtime 数字只描述这台主机、这些版本、这些 API 和这些 payload。它们不是语言排名，
也不能推导 allocation、RSS、峰值内存或其他 payload 的吞吐。

## 证据与 freshness gate

证据目录保存两批 raw report、日志、manifest、metadata、派生 summary、实际 harness 源码、
json4cj source-only 快照、构建日志和 checksum：

[`benchmarks/results/full-seven-library/2026-09-07-main-3df2801`](../../../benchmarks/results/full-seven-library/2026-09-07-main-3df2801/README.md)

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
