# 2026-08-30 当前 `main` 七库完整对比

本页记录 [`current-main.json`](../../../benchmarks/results/full-seven-library/current-main.json)
指向的 typed JSON benchmark。测量绑定到提交
`d2f375c8274e11609fa6f12fd2cb2c9a40da0a2b`。两批都完成了规定的 770 个测量单元，但
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

README 展示第二批完整表，不合并两批，也不从两批中挑选更好的数字。由于两批均为 noisy，
本页不发布精确性能倍数。

## 第一批

| Workload | yjson | stdx.json | cangjieJSON | json4cj | cjfast_json | Jackson | fastjson2 | Max CV |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Address encode | 1.601 | 57.419 | 3.005 | 3.478 | 2.474 | 0.170 | 0.066 | 14.30% |
| Address decode | 0.832 | 37.188 | 3.507 | 3.435 | 2.045 | 0.326 | 0.069 | 12.81% |
| Person encode | 3.961 | 95.744 | 18.064 | 5.461 | 10.868 | 0.570 | 0.257 | 15.79% |
| Person decode | 10.322 | 94.208 | 29.881 | 20.118 | 15.425 | 1.130 | 0.429 | 17.37% |
| Large Array encode | 33.635 | 496.585 | 250.688 | 91.608 | 75.886 | 8.952 | 3.951 | 10.55% |
| Large Array decode | 52.260 | 1023.407 | 406.700 | 178.300 | 78.144 | 18.819 | 5.049 | 9.04% |
| Large Map encode | 7.137 | 284.526 | 171.994 | 128.023 | 131.334 | 1.839 | 1.730 | 5.74% |
| Large Map decode | 28.507 | 587.331 | 342.529 | 223.027 | 231.305 | 5.452 | 4.138 | 9.84% |
| Deep Nested encode | 42.988 | 356.786 | 170.739 | 85.532 | 74.208 | 4.520 | 2.593 | 11.05% |
| Deep Nested decode | 66.812 | 643.928 | 256.894 | 142.336 | 96.199 | 10.541 | 3.462 | 33.99% |

## 第二批

| Workload | yjson | stdx.json | cangjieJSON | json4cj | cjfast_json | Jackson | fastjson2 | Max CV |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Address encode | 1.611 | 56.948 | 3.097 | 3.471 | 2.471 | 0.170 | 0.067 | 14.67% |
| Address decode | 0.776 | 37.205 | 3.433 | 3.438 | 2.041 | 0.321 | 0.069 | 11.48% |
| Person encode | 3.922 | 95.700 | 16.788 | 5.425 | 10.284 | 0.566 | 0.256 | 16.04% |
| Person decode | 10.167 | 93.739 | 29.100 | 20.003 | 15.707 | 1.133 | 0.430 | 9.07% |
| Large Array encode | 33.536 | 552.568 | 249.626 | 91.447 | 75.910 | 8.921 | 3.720 | 7.81% |
| Large Array decode | 50.432 | 1035.366 | 415.140 | 175.467 | 78.027 | 18.998 | 5.053 | 6.64% |
| Large Map encode | 7.109 | 304.432 | 161.078 | 128.235 | 131.101 | 1.752 | 1.728 | 10.29% |
| Large Map decode | 28.564 | 584.020 | 337.328 | 222.829 | 232.171 | 5.404 | 4.118 | 14.44% |
| Deep Nested encode | 46.592 | 366.702 | 171.247 | 84.907 | 74.496 | 4.487 | 2.596 | 11.64% |
| Deep Nested decode | 81.797 | 628.928 | 253.308 | 142.592 | 95.616 | 10.598 | 3.470 | 33.04% |

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
| 产品源码 | commit `d2f375c8274e11609fa6f12fd2cb2c9a40da0a2b` |
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

[`benchmarks/results/full-seven-library/2026-08-30-main-d2f375c8274e`](../../../benchmarks/results/full-seven-library/2026-08-30-main-d2f375c8274e/README.md)

从仓库根目录运行：

```terminal
python3 scripts/check_seven_library_evidence.py
```

校验器会验证归档 checksum、安全解包、两批完整性、metadata 身份和可重生成的 summary。
它还要求 marker 的测量提交是当前提交的祖先，并重新计算当前产品源码与 benchmark 输入摘要。
性能输入发生变化后，必须重跑 benchmark 并更新 marker；只更新 README 中的数字不能通过门禁。

最近一次通过 release qualification 的数据仍是
[yjson 2.0.0 性能验收](2026-08-27-yjson-2.0.0.md)。
