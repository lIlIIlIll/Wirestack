# 2026-08-30 `main` 七库 JSON benchmark 证据

本目录保存 `main` 提交
`d2f375c8274e11609fa6f12fd2cb2c9a40da0a2b` 的两批完整测量。每批覆盖 10 个
encode/decode workload、7 个库和 11 个独立进程轮次，共 770 个测量单元。

两批开始前分别选中 CPU 2（sibling 50）和 CPU 4（sibling 52）；30 秒采样中两个
hardware thread 的利用率均为 0.0%。两批仍有 workload 的最大 CV 超过 5%，因此这些
数字是完整但 noisy 的开发快照，不是发布资格数据，也不能用于声明精确倍数。

## 身份

| 项目 | 值 |
| --- | --- |
| Product source SHA-256 | `ef4b24f136e2916306e13c6e635e078433160e5c5ca93d50032f8033d8d309a9` |
| Effective harness SHA-256 | `db8e1c8a67f64753cc85c40fa31f8b1a7da7c523fdb204ee6581cae7cca5a4ca` |
| Optimal API overlay SHA-256 | `6837b8e3949e2a5bfd19cafde6813291248889a51b1c8cbd11b9c56c0dd81039` |

## 文件

| 文件 | 内容 |
| --- | --- |
| `formal-main-11-1.tar.gz` | 第一批 raw report、日志、manifest、metadata 和派生汇总 |
| `formal-main-11-2.tar.gz` | 按稳定性规则执行的第二个完整批次 |
| `harness-source.tar.gz` | 实际执行的七库 adapter、runner、汇总脚本和环境脚本 |
| `json4cj-source.tar.gz` | json4cj 的 source-only 输入快照 |
| `canonical-build-logs.tar.gz` | 五个 canonical adapter 的构建日志 |
| `optimal-api-overlay-main.patch` | 测量提交上使用的 canonical payload 和最优公开 API patch |
| `source-identity.json` | 产品与有效 harness 的逐文件摘要及 Git 身份 |
| `checksums.txt` | 上述证据文件的 SHA-256 inventory |

从仓库根目录执行完整校验：

```terminal
python3 scripts/check_seven_library_evidence.py
```

校验器会验证 checksum、安全解包、两批各 770 个单元、metadata 身份、汇总可重生成、
测量提交祖先关系，以及当前 checkout 的产品和 benchmark 输入摘要。

完整数据表、workload 形状和解释见
[当前 `main` 七库结果](../../../../docs/performance/results/2026-08-30-main-seven-library.md)。
