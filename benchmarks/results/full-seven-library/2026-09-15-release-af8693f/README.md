# 2026-09-15 `0.1.0` 候选七库 JSON benchmark 证据

本目录保存当前 `0.1.0` release candidate `af8693fe435f438bb67daf466d453e4dd079b3ca` 在 Cangjie STS `1.1.3` 下的两批 RSS-complete 测量。每批覆盖 10 个 encode/decode workload、7 个库和 11 个独立进程轮次，共 770 个测量单元；两批均完整通过。两批使用 `Server`（远端主机名 `ubuntu2223131`）的 CPU 1（sibling 49），正式采样的两个硬件线程利用率均低于 1%。

每个测量进程都由 GNU `/usr/bin/time -v` sidecar 记录 peak RSS；`manifest.csv` 的 `max_rss_kb` 与 sidecar 逐项绑定，summary 阶段重新校验每个 sidecar。Cangjie timing 直接执行未计时构建产生的 benchmark executable；构建步骤不在 GNU time 的 RSS 和 timing 范围内。

完整解释、两批表格和运行环境见[当前候选七库结果](../../../../docs/performance/results/2026-09-13-release-seven-library.md)。

## 性能

只有第二批 `Max CV <= 5%` 的 workload 写入本节；其余 workload 仍完整保留在两份 formal archive 中。

| Workload | yjson | stdx.json | cangjieJSON | json4cj | cjfast_json | Jackson | fastjson2 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Large Array encode | 26.098 | 85.248 | 250.240 | 91.582 | 75.648 | 9.162 | 4.147 |
| Deep Nested encode | 43.966 | 75.200 | 172.297 | 84.576 | 73.884 | 4.503 | 2.494 |

## 身份

| 项目 | 值 |
| --- | --- |
| Measured commit | `af8693fe435f438bb67daf466d453e4dd079b3ca` |
| Measured tree | `d9f10c776b2cd186be1bcb78f984b090033e191c` |
| Product source SHA-256 | `e367e12cfdc9af4857c60589878370d63d011af4edac5df36174aebe87ae8fc8` |
| Effective harness SHA-256 | `4d5788b785c9b69993f91e78934dcb5e21fca8b9ac2b2a7c6986c115e65e0865` |
| SDK | Cangjie STS `1.1.3` (`cjc`/`cjpm` `1.1.3`) |
| Host | `ubuntu2223131`, Linux x86_64 |
| CPU | CPU 1, sibling 49; both formal idle-sample utilizations `<1%` |
| Heap | `128MB` |

## 文件

| 文件 | 内容 |
| --- | --- |
| `formal-release-11-1.tar.gz` | 第一批 770 个 raw report、RSS sidecar、日志、manifest、metadata 和派生汇总 |
| `formal-release-11-2.tar.gz` | 第二批 770 个 raw report、RSS sidecar、日志、manifest、metadata 和派生汇总 |
| `harness-source.tar.gz` | 实际执行的七库 adapter、direct executable RSS runner、汇总脚本、环境脚本和 preflight overlay |
| `json4cj-source.tar.gz` | `json4cj` 的 source-only 输入快照 |
| `canonical-build-logs.tar.gz` | 五个 canonical harness 的未计时构建日志 |
| `fixture-preflight-overlay.patch` | 外部 fixture 使用的 canonical encode/decode preflight patch |
| `source-identity.json` | 产品与有效 harness 的逐文件摘要、Git 身份、artifact 身份和两批 metadata |
| `checksums.txt` | 上述证据文件的 SHA-256 inventory |

## 校验

从仓库根目录执行完整校验：

```terminal
python3 scripts/check_seven_library_evidence.py
```

校验器会验证 checksum、安全解包、两批各 770 个单元、RSS sidecar、metadata 身份、汇总可重生成、测量提交的 candidate closure，以及当前 checkout 的产品和 benchmark 输入摘要。`noisy` 只描述 CV；它不改变完整性和普通 Release 的回退规则。
