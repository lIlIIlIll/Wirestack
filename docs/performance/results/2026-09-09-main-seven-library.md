# 2026-09-09 当前 `main` 七库完整对比

本页记录 [`current-main.json`](../../../benchmarks/results/full-seven-library/current-main.json)
指向的 typed JSON benchmark。测量绑定到提交
`987bc8a764771e8157a5b5c0c45c169f654d0b4f`。两批都完成了规定的 770 个测量单元，但
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
| Address encode | 1.059 | 3.316 | 3.423 | 3.475 | 2.464 | 0.181 | 0.066 | 11.09% |
| Address decode | 1.490 | 2.430 | 3.246 | 3.455 | 2.040 | 0.323 | 0.072 | 12.86% |
| Person encode | 1.731 | 13.190 | 16.767 | 5.466 | 10.920 | 0.561 | 0.271 | 16.99% |
| Person decode | 7.948 | 21.637 | 28.208 | 20.246 | 15.333 | 1.108 | 0.420 | 8.68% |
| Large Array encode | 28.704 | 92.416 | 250.470 | 92.430 | 76.544 | 8.993 | 4.172 | 16.49% |
| Large Array decode | 108.641 | 179.660 | 418.300 | 179.152 | 77.982 | 18.879 | 5.076 | 14.69% |
| Large Map encode | 6.819 | 115.840 | 182.885 | 135.162 | 131.453 | 1.745 | 1.745 | 8.06% |
| Large Map decode | 32.572 | 253.440 | 347.059 | 221.568 | 228.782 | 5.343 | 4.000 | 9.95% |
| Deep Nested encode | 44.055 | 79.104 | 171.008 | 85.376 | 74.624 | 4.495 | 2.496 | 11.23% |
| Deep Nested decode | 324.476 | 164.389 | 238.824 | 141.440 | 96.853 | 10.451 | 3.454 | 10.65% |

## 第二批

| Workload | yjson | stdx.json | cangjieJSON | json4cj | cjfast_json | Jackson | fastjson2 | Max CV |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Address encode | 1.066 | 3.340 | 3.179 | 3.437 | 2.480 | 0.179 | 0.067 | 12.78% |
| Address decode | 1.505 | 2.439 | 3.512 | 3.446 | 2.032 | 0.325 | 0.073 | 26.97% |
| Person encode | 1.748 | 13.433 | 17.337 | 5.454 | 10.080 | 0.565 | 0.269 | 9.73% |
| Person decode | 8.201 | 21.760 | 26.771 | 20.265 | 15.443 | 1.114 | 0.421 | 12.14% |
| Large Array encode | 28.677 | 99.807 | 250.376 | 92.003 | 76.346 | 9.178 | 4.168 | 17.94% |
| Large Array decode | 105.334 | 183.183 | 413.851 | 174.592 | 77.874 | 18.908 | 5.134 | 14.47% |
| Large Map encode | 6.773 | 114.816 | 178.072 | 130.441 | 131.483 | 1.752 | 1.744 | 17.61% |
| Large Map decode | 33.024 | 248.173 | 320.931 | 222.208 | 231.520 | 5.306 | 3.930 | 14.50% |
| Deep Nested encode | 47.616 | 78.944 | 171.808 | 85.043 | 74.381 | 4.457 | 2.501 | 13.59% |
| Deep Nested decode | 316.554 | 160.401 | 274.398 | 142.336 | 96.469 | 10.475 | 3.455 | 10.82% |

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
| 产品源码 | commit `987bc8a764771e8157a5b5c0c45c169f654d0b4f` |
| Product source SHA-256 | `755467918a8bacee501cc662b7237952d3daf8f7c9291eea7dc32cca2715d7e3` |
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

[`benchmarks/results/full-seven-library/2026-09-09-main-987bc8a`](../../../benchmarks/results/full-seven-library/2026-09-09-main-987bc8a/README.md)

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
