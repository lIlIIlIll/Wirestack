# 2026-09-15 当前 `0.1.0` 候选七库完整对比

本页记录 [`current-main.json`](../../../benchmarks/results/full-seven-library/current-main.json) 指向的 RSS-complete typed JSON benchmark。两批测量均绑定到提交 `af8693fe435f438bb67daf466d453e4dd079b3ca`，对应当前 `0.1.0` release candidate 的 measured tree。完整原始证据、RSS sidecar、脚本和 checksum 见[证据目录](../../../benchmarks/results/full-seven-library/2026-09-15-release-af8693f/README.md)。

每个 workload-library 组合运行 11 个独立进程轮次。每个进程由 GNU `/usr/bin/time -v` 记录 peak RSS，`manifest.csv` 的 `max_rss_kb` 与 sidecar 逐项对应；下表 timing 单位为 µs/op，数值是 11 个轮次的中位数，越小越好。CV 超过 5% 的行标记为 noisy，不发布稳定的跨库精确排名。Cangjie timing 使用构建后的 benchmark executable，GNU time 不包围构建步骤。

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
| 第一批 | 770/770 | 1/10 | 完整测量；9/10 noisy |
| 第二批 | 770/770 | 2/10 | 完整测量；8/10 noisy |

## 第一批

| Workload | yjson | stdx.json | cangjieJSON | json4cj | cjfast_json | Jackson | fastjson2 | Max CV |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Address encode | 0.814 | 2.080 | 3.158 | 3.470 | 2.459 | 0.178 | 0.067 | 25.94% |
| Address decode | 1.288 | 2.222 | 3.461 | 3.451 | 2.022 | 0.323 | 0.072 | 14.89% |
| Person encode | 1.612 | 11.260 | 16.695 | 5.415 | 9.907 | 0.563 | 0.269 | 8.92% |
| Person decode | 7.984 | 19.506 | 26.230 | 20.485 | 15.407 | 1.107 | 0.421 | 5.47% |
| Large Array encode | 26.895 | 86.656 | 249.792 | 92.288 | 75.435 | 8.999 | 4.147 | 7.22% |
| Large Array decode | 82.176 | 175.333 | 414.955 | 175.066 | 77.495 | 18.948 | 5.085 | 12.33% |
| Large Map encode | 7.004 | 122.965 | 181.300 | 135.680 | 128.728 | 1.775 | 1.736 | 6.72% |
| Large Map decode | 26.615 | 243.200 | 318.185 | 223.731 | 231.027 | 5.333 | 3.957 | 8.70% |
| Deep Nested encode | 43.925 | 75.776 | 171.550 | 84.693 | 73.984 | 4.524 | 2.483 | 4.41% |
| Deep Nested decode | 325.120 | 154.427 | 269.836 | 142.994 | 95.667 | 10.418 | 3.432 | 9.94% |

## 第二批

| Workload | yjson | stdx.json | cangjieJSON | json4cj | cjfast_json | Jackson | fastjson2 | Max CV |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Address encode | 0.810 | 2.699 | 3.136 | 3.453 | 2.447 | 0.180 | 0.066 | 27.08% |
| Address decode | 1.242 | 2.374 | 3.372 | 3.452 | 2.028 | 0.319 | 0.072 | 11.29% |
| Person encode | 1.610 | 10.304 | 16.610 | 5.445 | 9.969 | 0.569 | 0.268 | 11.58% |
| Person decode | 8.089 | 19.415 | 26.998 | 20.394 | 15.738 | 1.103 | 0.420 | 6.80% |
| Large Array encode | 26.098 | 85.248 | 250.240 | 91.582 | 75.648 | 9.162 | 4.147 | 3.90% |
| Large Array decode | 83.456 | 174.199 | 404.502 | 176.277 | 77.360 | 18.935 | 5.114 | 12.17% |
| Large Map encode | 6.991 | 123.840 | 180.770 | 130.649 | 129.024 | 1.719 | 1.735 | 7.76% |
| Large Map decode | 26.686 | 239.258 | 330.531 | 221.003 | 224.585 | 5.346 | 3.954 | 6.72% |
| Deep Nested encode | 43.966 | 75.200 | 172.297 | 84.576 | 73.884 | 4.503 | 2.494 | 2.74% |
| Deep Nested decode | 328.363 | 159.464 | 256.042 | 142.470 | 95.738 | 10.458 | 3.418 | 7.10% |

## API、环境和解释

每个 adapter 使用语义等价的最快公开 typed API；存在 direct typed path 时不使用 DOM fallback。七库顺序和 workload 顺序逐轮旋转，偶数轮反转 workload 顺序。Cangjie 使用 200 ms warmup、至少 1 秒测量和至少 12 个 batch；Java 每个外层轮次使用一个 fork、3 × 500 ms warmup 和 1 × 1 秒测量。每个 raw manifest 单元同时保留 timing report、日志和 RSS sidecar；构建步骤在未计时阶段完成。

| 项目 | 值 |
| --- | --- |
| Candidate | `af8693fe435f438bb67daf466d453e4dd079b3ca` |
| Measured tree | `d9f10c776b2cd186be1bcb78f984b090033e191c` |
| Product source SHA-256 | `e367e12cfdc9af4857c60589878370d63d011af4edac5df36174aebe87ae8fc8` |
| Effective harness SHA-256 | `4d5788b785c9b69993f91e78934dcb5e21fca8b9ac2b2a7c6986c115e65e0865` |
| Candidate identity SHA-256 | `2cac5f70965cc91554f1c3a384ab7c10631c0e274028178e8b7461d4217b7861` |
| Measured overlay SHA-256 | `4f1350b31ab636db4b6b00410d0927f4baf1e52900657ac5f6ae5eb529d0b35` |
| SDK | Cangjie STS `1.1.3`; `cjc`/`cjpm` `1.1.3` |
| Host | `ubuntu2223131` via SSH alias `Server`; Linux 5.15.0-187-generic; x86_64; 96 logical CPUs |
| CPU | CPU 1, sibling 49；两线程 30 秒 idle sample 均低于 1% |
| Heap | `128MB` |
| GNU time | `/usr/bin/time`; RSS unit `kbytes` |
| Java | OpenJDK 17.0.20+8-1-22.04-Ubuntu; JMH 1.37; Jackson 2.18.2; fastjson2 2.0.52 |

第一批所有 timed process 的最大 RSS 为 `226240 kbytes`；第二批为 `226420 kbytes`。归档 SHA-256：第一批 `1ea77a85d8e24c04eff277c7cfb042a52bb09fab5a384d35800e48f599035f06`，第二批 `cb1316a1ab979c0aa3fe27f001a9e182bfb3efe3ef6f04cfdb3ce633c22cc4b1`。两批共 1540 个 workload-library-round 单元，全部保留 raw report、日志、manifest、metadata 和 RSS sidecar。稳定行仅用于复核；noisy 行不支持稳定精确跨库排名。

复核时在包含这些文件的证据目录执行 `sha256sum -c checksums.txt`；该清单校验两份 formal archive 及同目录的 source/harness 文件，不在归档解压目录内。分别解压每份归档后，在包含 `manifest.csv` 的解压目录执行 `python3 benchmarks/full-seven-library/summarize_full.py <解压目录> --min-runs 11`，重新读取 raw report 和 RSS sidecar 并生成 summary；exact case filter 和 direct executable 命令记录在归档 `metadata.json` 与 `run_full.py` 中。
