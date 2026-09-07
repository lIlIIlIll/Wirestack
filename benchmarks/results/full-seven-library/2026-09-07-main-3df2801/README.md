# 2026-09-07 `main` 七库 JSON benchmark 证据

本目录保存 `main` 提交
`3df280151b3a3a818c6ad75c254750a19d25e5a1` 的两批完整测量。每批覆盖 10 个
encode/decode workload、7 个库和 11 个独立进程轮次，共 770 个测量单元。

两批开始前均选中 CPU 4（sibling 52）；30 秒采样中两个 hardware thread 的利用率
均低于 1.0%。两批仍有 workload 的最大 CV 超过 5%，因此这些
数字是完整但 noisy 的开发快照，不是发布资格数据，也不能用于声明精确倍数。

## 身份

| 项目 | 值 |
| --- | --- |
| Product source SHA-256 | `0f16de1d0f424626d807e7950785d534b818bef0fdc0f061ceed7be63e651651` |
| Effective harness SHA-256 | `4d5788b785c9b69993f91e78934dcb5e21fca8b9ac2b2a7c6986c115e65e0865` |
| Optimal API overlay SHA-256 | `4f1350b31ab636db4b6b00410d0927f4baf1e52900657ac5f6ae5eb529d0b35d` |

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
[当前 `main` 七库结果](../../../../docs/performance/results/2026-09-07-main-seven-library.md)。
