# 2026-09-10 `main` 七库 JSON benchmark 证据

本目录保存 `2758853efe1117c7d2b272abd36cf90de46526f5` 的两批完整测量。每批覆盖 10 个 encode/decode workload、7 个库和 11 个独立进程轮次，共 770 个测量单元。

两批开始前均选中 CPU 2（sibling 3）；30 秒采样中两个 hardware thread 的利用率为 0.10%、0.10%。这些结果保留完整的原始报告、日志、manifest、metadata 和派生汇总；第一批 5/10、第二批 0/10 个 workload 满足 Max CV <= 5%。

## 身份

| 项目 | 值 |
| --- | --- |
| Product source SHA-256 | `6056f53aa56767a69a29685dad1d6b8fadd8c39a7b47ca6ecc60b46f114acb0b` |
| Effective harness SHA-256 | `4d5788b785c9b69993f91e78934dcb5e21fca8b9ac2b2a7c6986c115e65e0865` |
| Optimal API overlay SHA-256 | 见 `checksums.txt` |

## 文件

| 文件 | 内容 |
| --- | --- |
| `formal-main-11-1.tar.gz` | 第一批 raw report、日志、manifest、metadata 和派生汇总 |
| `formal-main-11-2.tar.gz` | 第二批 raw report、日志、manifest、metadata 和派生汇总 |
| `harness-source.tar.gz` | 实际执行的七库 adapter、runner、汇总脚本和环境脚本 |
| `json4cj-source.tar.gz` | json4cj 的 source-only 输入快照 |
| `optimal-api-overlay-main.patch` | 测量提交上使用的 canonical payload 和最优公开 API patch |
| `source-identity.json` | 产品与有效 harness 的逐文件摘要及 Git 身份 |
| `checksums.txt` | 上述证据文件的 SHA-256 inventory |

从仓库根目录执行完整校验：

```terminal
python3 scripts/check_seven_library_evidence.py
```

校验器会验证 checksum、安全解包、两批各 770 个单元、metadata 身份、汇总可重生成、测量提交的
candidate closure，以及当前 checkout 的产品和 benchmark 输入摘要；测量提交对象被 squash
合并裁剪后，仍可用 marker 和归档中的身份信息完成严格校验。

完整数据表、workload 形状和解释见
[当前 `main` 七库结果](../../../../docs/performance/results/2026-09-10-main-seven-library.md)。
