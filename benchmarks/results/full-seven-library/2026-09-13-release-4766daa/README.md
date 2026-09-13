# 2026-09-13 `0.1.0` 候选七库 JSON benchmark 证据

本目录保存当前 `0.1.0` release candidate `4766daa7ac88a5ad0869cfa2dbdb12c63acd0161` 在 Cangjie STS `1.1.3` 下的两批完整测量。每批覆盖 10 个 encode/decode workload、7 个库和 11 个独立进程轮次，共 770 个测量单元。两批均在 `ubuntu2223131` 的 CPU 1（sibling 49）上完成 30 秒 idle-core 采样；两批 10/10 workload 均为 noisy，但完整数据不因 CV 被删除。

完整解释、两批表格和运行环境见[当前候选七库结果](../../../../docs/performance/results/2026-09-13-release-seven-library.md)。

## 身份

| 项目 | 值 |
| --- | --- |
| Measured commit | `4766daa7ac88a5ad0869cfa2dbdb12c63acd0161` |
| Measured tree | `ccbee2fa194180c66374d44852c0122c30b7e9a6` |
| Product source SHA-256 | `6056f53aa56767a69a29685dad1d6b8fadd8c39a7b47ca6ecc60b46f114acb0b` |
| Effective harness SHA-256 | `4d5788b785c9b69993f91e78934dcb5e21fca8b9ac2b2a7c6986c115e65e0865` |
| Candidate identity SHA-256 | `1e2e2d91e0500c8851fa26c579f36ba247a2511b6ea4b918d3bdd6a145c71267` |
| Release graph input SHA-256 | `43b1c43d5a9c12128aa9acedf3e148d531a7a623e24c24d3734dee22bfa96bfc` |
| SDK | Cangjie STS `1.1.3` (`cjc`/`cjpm` `1.1.3`) |
| Host | `ubuntu2223131`, Linux 5.15.0-187-generic, x86_64 |
| Heap | `128MB` |

## 文件

| 文件 | 内容 |
| --- | --- |
| `formal-release-11-1.tar.gz` | 第一批 raw report、日志、manifest、metadata 和派生汇总 |
| `formal-release-11-2.tar.gz` | 第二批 raw report、日志、manifest、metadata 和派生汇总 |
| `harness-source.tar.gz` | 实际执行的七库 adapter、runner、汇总脚本和环境脚本 |
| `json4cj-source.tar.gz` | `json4cj` 的 source-only 输入快照 |
| `measured-overlay-none.patch` | 当前 yjson 产品源码未使用额外 overlay 的记录；外部 fixture 使用仓库内 preflight patch |
| `source-identity.json` | 产品与有效 harness 的逐文件摘要、Git 身份和两批 metadata |
| `checksums.txt` | 上述证据文件的 SHA-256 inventory |

## 校验

从仓库根目录执行完整校验：

```terminal
python3 scripts/check_seven_library_evidence.py
```

校验器会验证 checksum、安全解包、两批各 770 个单元、metadata 身份、汇总可重生成、测量提交的 candidate closure，以及当前 checkout 的产品和 benchmark 输入摘要。`noisy` 只描述 CV，不改变完整性和 release gate 的回退规则。
