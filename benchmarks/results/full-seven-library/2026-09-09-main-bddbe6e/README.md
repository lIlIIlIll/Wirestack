# 2026-09-09 `main` 七库 JSON benchmark 证据

本目录保存 `bddbe6e022f8809b33f42141d5ac54dc2e081406` 的两批完整测量。每批覆盖 10 个 encode/decode workload、7 个库和 11 个独立进程轮次，共 770 个测量单元。

两批开始前均选中 CPU 4（sibling 52）；30 秒采样中两个 hardware thread 的利用率均为 0.0%。这些结果保留完整的原始报告、日志、manifest、metadata 和派生汇总；CV 超过 5% 的 workload 仍标为 noisy，不用于声明精确倍数或替代 release qualification。

## 身份

| 项目 | 值 |
| --- | --- |
| Product source SHA-256 | `df9108e367363847b0fd59b3c611cc6a3504f4d426152e13479caf3e8b94d7f9` |
| Effective harness SHA-256 | `4d5788b785c9b69993f91e78934dcb5e21fca8b9ac2b2a7c6986c115e65e0865` |
| Optimal API overlay SHA-256 | 见 `checksums.txt` |

## 文件

| 文件 | 内容 |
| --- | --- |
| `formal-main-11-1.tar.gz` | 第一批 raw report、日志、manifest、metadata 和派生汇总 |
| `formal-main-11-2.tar.gz` | 第二批 raw report、日志、manifest、metadata 和派生汇总 |
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

校验器会验证 checksum、安全解包、两批各 770 个单元、metadata 身份、汇总可重生成、测量提交祖先关系，以及当前 checkout 的产品和 benchmark 输入摘要。

完整数据表、workload 形状和解释见
[当前 `main` 七库结果](../../../../docs/performance/results/2026-09-09-main-seven-library.md)。
