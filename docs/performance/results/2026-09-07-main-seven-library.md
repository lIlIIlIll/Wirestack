# 2026-09-07 当前 `main` 七库完整对比

本页记录 [`current-main.json`](../../../benchmarks/results/full-seven-library/current-main.json)
指向的 typed JSON benchmark。测量绑定到提交
`087a82eb9b76fccbe44d3bdb53e7f06527a3d827`。两批都完成了规定的 770 个测量单元，但
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
| Address encode | 1.305 | 3.324 | 2.837 | 3.425 | 2.991 | 0.169 | 0.067 | 15.09% |
| Address decode | 1.502 | 2.425 | 3.078 | 3.449 | 2.052 | 0.307 | 0.067 | 11.73% |
| Person encode | 2.773 | 12.394 | 15.982 | 5.493 | 10.581 | 0.577 | 0.269 | 19.15% |
| Person decode | 9.205 | 21.220 | 25.825 | 19.973 | 14.925 | 1.129 | 0.425 | 17.11% |
| Large Array encode | 28.464 | 113.644 | 261.336 | 91.857 | 76.064 | 9.020 | 3.937 | 10.04% |
| Large Array decode | 132.692 | 205.405 | 317.075 | 226.204 | 79.915 | 18.613 | 5.051 | 11.15% |
| Large Map encode | 6.856 | 135.270 | 162.038 | 124.272 | 125.398 | 1.811 | 1.778 | 7.62% |
| Large Map decode | 49.550 | 315.729 | 295.572 | 215.065 | 217.086 | 5.086 | 3.919 | 22.28% |
| Deep Nested encode | 55.721 | 102.764 | 172.213 | 79.450 | 74.197 | 4.498 | 2.491 | 14.08% |
| Deep Nested decode | 387.172 | 197.653 | 230.720 | 160.719 | 94.381 | 10.410 | 3.428 | 14.13% |

## 第二批

| Workload | yjson | stdx.json | cangjieJSON | json4cj | cjfast_json | Jackson | fastjson2 | Max CV |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Address encode | 1.279 | 3.052 | 2.840 | 3.471 | 2.961 | 0.169 | 0.066 | 17.04% |
| Address decode | 1.570 | 2.420 | 3.107 | 3.441 | 2.047 | 0.304 | 0.066 | 8.89% |
| Person encode | 3.187 | 12.550 | 16.246 | 5.462 | 10.828 | 0.576 | 0.269 | 30.89% |
| Person decode | 8.346 | 19.188 | 26.047 | 19.916 | 14.935 | 1.136 | 0.428 | 10.09% |
| Large Array encode | 28.877 | 115.411 | 255.277 | 92.486 | 75.933 | 8.878 | 4.231 | 12.57% |
| Large Array decode | 129.378 | 200.035 | 310.735 | 223.328 | 78.876 | 18.540 | 5.052 | 8.51% |
| Large Map encode | 6.957 | 138.527 | 160.427 | 123.440 | 127.793 | 1.789 | 1.739 | 10.76% |
| Large Map decode | 49.210 | 316.508 | 288.467 | 203.392 | 208.025 | 5.102 | 3.961 | 14.12% |
| Deep Nested encode | 54.989 | 96.611 | 172.437 | 85.193 | 70.899 | 4.488 | 2.535 | 14.87% |
| Deep Nested decode | 374.897 | 195.640 | 211.924 | 162.089 | 96.250 | 10.468 | 3.421 | 8.24% |

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
| 产品源码 | commit `087a82eb9b76fccbe44d3bdb53e7f06527a3d827` |
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

[`benchmarks/results/full-seven-library/2026-09-07-main-087a82e`](../../../benchmarks/results/full-seven-library/2026-09-07-main-087a82e/README.md)

从仓库根目录运行：

```terminal
python3 scripts/check_seven_library_evidence.py
```

校验器会验证归档 checksum、安全解包、两批完整性、metadata 身份和可重生成的 summary。
它还要求 marker 的测量提交是当前提交的祖先，并重新计算当前产品源码与 benchmark 输入摘要。
性能输入发生变化后，必须重跑 benchmark 并更新 marker；只更新 README 中的数字不能通过门禁。

最近一次通过 release qualification 的数据仍是
[yjson 2.0.0 性能验收](2026-08-27-yjson-2.0.0.md)。
