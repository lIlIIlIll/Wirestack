# 2026-09-14 当前 `0.1.0` 候选七库完整对比

本页记录 [`current-main.json`](../../../benchmarks/results/full-seven-library/current-main.json) 指向的 RSS-complete typed JSON benchmark。两批测量均绑定到提交 `7436598b6cd22084ea990832b07d972aeae26e1b`，对应当前 `0.1.0` release candidate 的 measured tree。完整原始证据、RSS sidecar、脚本和 checksum 见[证据目录](../../../benchmarks/results/full-seven-library/2026-09-14-release-7436598/README.md)。

每个 workload-library 组合运行 11 个独立进程轮次。每个进程由 GNU `/usr/bin/time -v` 记录 peak RSS，`manifest.csv` 的 `max_rss_kb` 与 sidecar 逐项对应；下表 timing 单位为 µs/op，数值是 11 个轮次的中位数，越小越好。两批每个 workload 的七库最大 CV 都超过 5%，因此完整结果标记为 noisy，不发布稳定的跨库精确排名。

## 先看 workload

Encode 从已经构造好的 typed value 生成紧凑 JSON 字符串。Decode 从 canonical JSON 字符串恢复相同的 typed 类型。表中的 payload bytes 是 decode 输入的 UTF-8 大小。

| Workload | Typed value 的形状 | 规模 | Payload bytes |
| --- | --- | ---: | ---: |
| Address | `Address{street_name: String, zipcode: Int64}` | 2 个字段 | 47 |
| Person | 3 个字符串 tag、2 个整数 score、嵌套 Address 和 null nick | 7 个 JSON 字段 | 176 |
| Large Array | `ArrayList<ProfileRecord>`；每条记录有 id、alias 和 level | 64 条记录 | 3929 |
| Large Map | `HashMap<String, Int64>`；key 为 `metric_0` 到 `metric_63` | 64 个 entry | 1013 |
| Deep Nested | `ArrayList<HashMap<String, ArrayList<ProfileRecord>>>` | 8 组 × 4 条记录，共 32 条 | 1929 |

## 结果状态

`Max CV` 是该 workload 在七个库中的最大 CV。只有 `Max CV <= 5%` 的行才是 stable；CV 超过 5% 的行仍完整保留，noisy 本身不改变普通 Release 的回退门禁。

| 批次 | 完整测量单元 | Stable workloads | 结论 |
| --- | ---: | ---: | --- |
| 第一批 | 770/770 | 0/10 | 完整测量；10/10 noisy |
| 第二批 | 770/770 | 0/10 | 完整测量；10/10 noisy |

## 第一批

| Workload | yjson | stdx.json | cangjieJSON | json4cj | cjfast_json | Jackson | fastjson2 | Max CV |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Address encode | 1.356 | 3.220 | 2.806 | 3.451 | 2.996 | 0.169 | 0.066 | 9.34% |
| Address decode | 1.453 | 2.428 | 3.097 | 3.437 | 2.033 | 0.304 | 0.067 | 11.99% |
| Person encode | 2.384 | 12.435 | 16.251 | 5.461 | 10.164 | 0.582 | 0.270 | 21.50% |
| Person decode | 8.375 | 21.646 | 25.365 | 20.081 | 14.899 | 1.135 | 0.427 | 15.89% |
| Large Array encode | 28.714 | 111.914 | 264.053 | 92.480 | 75.662 | 8.934 | 4.197 | 23.75% |
| Large Array decode | 121.353 | 207.906 | 296.173 | 226.182 | 84.150 | 18.461 | 5.034 | 11.12% |
| Large Map encode | 6.812 | 144.395 | 160.425 | 122.573 | 124.745 | 1.799 | 1.740 | 15.19% |
| Large Map decode | 30.321 | 311.883 | 303.734 | 210.204 | 209.241 | 5.063 | 3.965 | 20.07% |
| Deep Nested encode | 58.573 | 95.216 | 172.828 | 82.014 | 67.563 | 4.478 | 2.479 | 18.29% |
| Deep Nested decode | 377.233 | 204.974 | 230.285 | 148.591 | 95.179 | 10.471 | 3.419 | 7.80% |

## 第二批

| Workload | yjson | stdx.json | cangjieJSON | json4cj | cjfast_json | Jackson | fastjson2 | Max CV |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Address encode | 1.306 | 3.250 | 2.813 | 3.442 | 2.960 | 0.167 | 0.066 | 9.19% |
| Address decode | 1.448 | 2.346 | 3.167 | 3.444 | 2.065 | 0.305 | 0.068 | 10.13% |
| Person encode | 3.088 | 12.525 | 16.955 | 5.456 | 10.057 | 0.583 | 0.268 | 25.42% |
| Person decode | 8.140 | 21.674 | 23.960 | 19.999 | 14.271 | 1.133 | 0.425 | 13.68% |
| Large Array encode | 30.151 | 113.661 | 251.488 | 93.673 | 76.203 | 8.856 | 4.198 | 20.51% |
| Large Array decode | 125.845 | 206.283 | 314.016 | 215.774 | 78.775 | 18.304 | 5.070 | 12.18% |
| Large Map encode | 6.682 | 139.925 | 158.891 | 123.904 | 118.018 | 1.770 | 1.744 | 13.13% |
| Large Map decode | 34.159 | 312.636 | 295.014 | 221.351 | 211.354 | 5.142 | 3.960 | 15.92% |
| Deep Nested encode | 57.366 | 98.377 | 174.965 | 85.600 | 67.824 | 4.473 | 2.630 | 15.95% |
| Deep Nested decode | 373.038 | 201.061 | 223.722 | 144.791 | 95.330 | 10.388 | 3.364 | 9.46% |

## API、环境和解释

每个 adapter 使用语义等价的最快公开 typed API；存在 direct typed path 时不使用 DOM fallback。七库顺序和 workload 顺序逐轮旋转，偶数轮反转 workload 顺序。Cangjie 使用 200 ms warmup、至少 1 秒测量和至少 12 个 batch；Java 每个外层轮次使用一个 fork、3 × 500 ms warmup 和 1 × 1 秒测量。每个 raw manifest 单元同时保留 timing report、日志和 RSS sidecar；本批全部 sidecar 的最大记录为 `352596` kbytes。

| 项目 | 值 |
| --- | --- |
| Candidate | `7436598b6cd22084ea990832b07d972aeae26e1b` |
| Measured tree | `00d9629474c5b5a850bc427aca6f84046dc7ffd5` |
| Product source SHA-256 | `b0120df219570213b3a61a7876349efeabd2bb9bf92a8fb4eea3066e25d11edf` |
| Effective harness SHA-256 | `4d5788b785c9b69993f91e78934dcb5e21fca8b9ac2b2a7c6986c115e65e0865` |
| Candidate identity SHA-256 | `00bfbb6e4929e2152c44c96b08177c18bf2705001557d741fe3cb410b08238be` |
| SDK | Cangjie STS `1.1.3`; `cjc`/`cjpm` `1.1.3` |
| Host | `ubuntu2223131`; Linux 5.15.0-187-generic; x86_64; 96 logical CPUs |
| CPU | CPU 3, sibling 51；两线程 30 秒 idle sample 均低于 1% |
| Heap | `128MB` |
| GNU time | `/usr/bin/time`; RSS unit `kbytes` |
| Java | OpenJDK 17.0.20+8-1-22.04-Ubuntu; JMH 1.37; Jackson 2.18.2; fastjson2 2.0.52 |

所有数字只描述记录中的主机、SDK、API、payload 和进程调度。两批均 noisy，因此不发布稳定的跨库精确排名；完整 raw evidence 和 RSS sidecar 仍作为可复核的 release 输入保存。
