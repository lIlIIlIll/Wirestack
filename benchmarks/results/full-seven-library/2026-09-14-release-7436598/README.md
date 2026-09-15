# 2026-09-14 `0.1.0` 候选七库 JSON benchmark 证据

本目录保存当前 `0.1.0` release candidate `7436598b6cd22084ea990832b07d972aeae26e1b` 在 Cangjie STS `1.1.3` 下的两批 RSS-complete 测量。每批覆盖 10 个 encode/decode workload、7 个库和 11 个独立进程轮次，共 770 个测量单元；两批均完整通过。两批使用 `Server` 的 CPU 3（sibling 51），正式采样的两个硬件线程利用率均低于 1%。

每个测量进程都由 GNU `/usr/bin/time -v` sidecar 记录 peak RSS；`manifest.csv` 的 `max_rss_kb` 与 sidecar 逐项绑定，summary 阶段重新校验每个 sidecar。两批所有 workload 的 CV 均超过 5%，因此结果保留为完整 noisy 复核数据，不发布稳定的跨库精确排名。

完整解释、两批表格和运行环境见[当前候选七库结果](../../../../docs/performance/results/2026-09-13-release-seven-library.md)。

## 身份

| 项目 | 值 |
| --- | --- |
| Measured commit | `7436598b6cd22084ea990832b07d972aeae26e1b` |
| Measured tree | `00d9629474c5b5a850bc427aca6f84046dc7ffd5` |
| Product source SHA-256 | `b0120df219570213b3a61a7876349efeabd2bb9bf92a8fb4eea3066e25d11edf` |
| Effective harness SHA-256 | `4d5788b785c9b69993f91e78934dcb5e21fca8b9ac2b2a7c6986c115e65e0865` |
| Candidate identity SHA-256 | `00bfbb6e4929e2152c44c96b08177c18bf2705001557d741fe3cb410b08238be` |
| Release graph input SHA-256 | `43b1c43d5a9c12128aa9acedf3e148d531a7a623e24c24d3734dee22bfa96bfc` |
| SDK | Cangjie STS `1.1.3` (`cjc`/`cjpm` `1.1.3`) |
| Host | `ubuntu2223131`, Linux 5.15.0-187-generic, x86_64 |
| CPU | CPU 3, sibling 51; both formal idle-sample utilizations `<1%` |
| Heap | `128MB` |

## 文件

| 文件 | 内容 |
| --- | --- |
| `formal-release-11-1.tar.gz` | 第一批 770 个 raw report、RSS sidecar、日志、manifest、metadata 和派生汇总 |
| `formal-release-11-2.tar.gz` | 第二批 770 个 raw report、RSS sidecar、日志、manifest、metadata 和派生汇总 |
| `harness-source.tar.gz` | 实际执行的七库 adapter、RSS runner、汇总脚本和环境脚本 |
| `json4cj-source.tar.gz` | `json4cj` 的 source-only 输入快照 |
| `measured-overlay-none.patch` | 当前 yjson 产品源码未使用额外 overlay 的记录；外部 fixture 使用仓库内 preflight patch |
| `source-identity.json` | 产品与有效 harness 的逐文件摘要、Git 身份和两批 metadata |
| `checksums.txt` | 上述证据文件的 SHA-256 inventory |

## 校验

从仓库根目录执行完整校验：

```terminal
python3 scripts/check_seven_library_evidence.py
```

校验器会验证 checksum、安全解包、两批各 770 个单元、RSS sidecar、metadata 身份、汇总可重生成、测量提交的 candidate closure，以及当前 checkout 的产品和 benchmark 输入摘要。`noisy` 只描述 CV，不改变完整性和普通 Release 的回退规则。
