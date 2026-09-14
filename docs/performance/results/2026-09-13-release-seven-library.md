# 2026-09-13 当前 `0.1.0` 候选七库完整对比

本页记录 [`current-main.json`](../../../benchmarks/results/full-seven-library/current-main.json) 指向的 typed JSON benchmark。两批测量均绑定到提交 `4766daa7ac88a5ad0869cfa2dbdb12c63acd0161`，对应当前 `0.1.0` release candidate 的 clean tree。完整原始证据、脚本和 checksum 见[证据目录](../../../benchmarks/results/full-seven-library/2026-09-13-release-4766daa/README.md)。

该归档生成于当前 runner 增加 peak RSS sidecar 之前；下方 timing 表仅是历史 noisy
快照，不能替代发布检查要求的 RSS qualification。更新后的七库 runner/summary 已要求
每个进程的 RSS sidecar，必须在合格 Server 上重新完成两批测量。

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

每个 workload-library 组合运行 11 个独立进程轮次。每个表格单元格是这 11 个轮次的中位数，单位为 µs/op，越小越好。`Max CV` 是该 workload 在七个库中的最大 CV。只有 `Max CV <= 5%` 的行才是 stable；CV 超过 5% 的行仍完整保留，noisy 本身不改变普通 Release 的回退门禁。

| 批次 | 完整测量单元 | Stable workloads | 结论 |
| --- | ---: | ---: | --- |
| 第一批 | 770/770 | 0/10 | 完整测量；10/10 noisy |
| 第二批 | 770/770 | 0/10 | 完整测量；10/10 noisy |

## 第一批

| Workload | yjson | stdx.json | cangjieJSON | json4cj | cjfast_json | Jackson | fastjson2 | Max CV |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Address encode | 0.916 | 2.761 | 3.066 | 3.474 | 2.477 | 0.179 | 0.067 | 19.19% |
| Address decode | 1.481 | 2.453 | 3.606 | 3.437 | 2.038 | 0.321 | 0.071 | 11.52% |
| Person encode | 1.650 | 13.324 | 18.179 | 5.074 | 10.536 | 0.559 | 0.266 | 19.19% |
| Person decode | 7.893 | 21.590 | 27.944 | 20.854 | 15.420 | 1.115 | 0.420 | 12.91% |
| Large Array encode | 28.814 | 99.013 | 250.368 | 92.073 | 75.776 | 9.167 | 4.137 | 7.81% |
| Large Array decode | 106.161 | 182.449 | 421.871 | 172.160 | 77.952 | 18.861 | 5.076 | 8.09% |
| Large Map encode | 6.292 | 131.086 | 180.075 | 131.605 | 129.490 | 1.781 | 1.733 | 6.51% |
| Large Map decode | 29.624 | 252.288 | 351.808 | 222.464 | 227.365 | 5.301 | 3.888 | 7.15% |
| Deep Nested encode | 43.557 | 78.421 | 171.805 | 85.589 | 74.069 | 4.511 | 2.506 | 16.77% |
| Deep Nested decode | 316.985 | 170.364 | 241.074 | 143.040 | 96.320 | 10.440 | 3.411 | 15.68% |

## 第二批

| Workload | yjson | stdx.json | cangjieJSON | json4cj | cjfast_json | Jackson | fastjson2 | Max CV |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Address encode | 0.900 | 3.325 | 3.185 | 3.476 | 2.489 | 0.178 | 0.066 | 10.37% |
| Address decode | 1.490 | 2.406 | 3.395 | 3.441 | 2.054 | 0.319 | 0.072 | 12.81% |
| Person encode | 1.700 | 13.254 | 16.956 | 5.425 | 10.415 | 0.564 | 0.267 | 10.23% |
| Person decode | 6.446 | 21.810 | 26.928 | 21.316 | 15.621 | 1.112 | 0.419 | 18.70% |
| Large Array encode | 28.847 | 100.328 | 251.520 | 91.904 | 75.840 | 9.042 | 4.162 | 9.81% |
| Large Array decode | 107.767 | 187.745 | 397.481 | 175.659 | 77.376 | 18.908 | 5.154 | 8.68% |
| Large Map encode | 6.075 | 130.189 | 179.092 | 130.409 | 129.510 | 1.771 | 1.861 | 6.45% |
| Large Map decode | 29.717 | 249.920 | 350.483 | 224.512 | 227.156 | 5.323 | 3.943 | 7.01% |
| Deep Nested encode | 45.090 | 71.863 | 171.648 | 85.786 | 73.728 | 4.549 | 2.475 | 12.87% |
| Deep Nested decode | 325.770 | 161.899 | 263.682 | 144.555 | 96.069 | 10.454 | 3.400 | 10.05% |

## API、环境和解释

每个 adapter 使用语义等价的最快公开 typed API；存在 direct typed path 时不使用 DOM fallback。七库顺序和 workload 顺序逐轮旋转，偶数轮反转 workload 顺序。Cangjie 使用 200 ms warmup、至少 1 秒测量和至少 12 个 batch；Java 每个外层轮次使用一个 fork、3 × 500 ms warmup 和 1 × 1 秒测量。

| 项目 | 值 |
| --- | --- |
| Candidate | `4766daa7ac88a5ad0869cfa2dbdb12c63acd0161` |
| Product source SHA-256 | `6056f53aa56767a69a29685dad1d6b8fadd8c39a7b47ca6ecc60b46f114acb0b` |
| Effective harness SHA-256 | `4d5788b785c9b69993f91e78934dcb5e21fca8b9ac2b2a7c6986c115e65e0865` |
| Candidate identity SHA-256 | `1e2e2d91e0500c8851fa26c579f36ba247a2511b6ea4b918d3bdd6a145c71267` |
| SDK | Cangjie STS `1.1.3`; `cjc`/`cjpm` `1.1.3` |
| Host | `ubuntu2223131`; Linux 5.15.0-187-generic; x86_64; 96 logical CPUs |
| CPU | CPU 1, sibling 49; both measured utilization 0.0% in the 30-second idle sample |
| Heap | `128MB` |
| Java | OpenJDK 17.0.20+8-1-22.04-Ubuntu; JMH 1.37; Jackson 2.18.2; fastjson2 2.0.52 |

所有数字只描述记录中的主机、SDK、API、payload 和进程调度。两批均 noisy，因此不发布稳定的跨库精确排名；完整 raw evidence 仍作为可复核的 release 输入保存。
