# 2026-08-30 七库完整 JSON benchmark 证据

本目录保存当前 `dev` 提交 `1dedf2a6d959453a1d946d69da7ba0216b3d5d87` 的两批完整
测量。每批包含 10 个 encode 和 decode workload、7 个库和 11 轮，共 770 个测量单元格。

## 文件

| 文件 | 内容 |
| --- | --- |
| `formal-current-11-1.tar.gz` | 第一批 raw report、日志、manifest、metadata 和汇总 |
| `formal-current-11-2.tar.gz` | 按稳定性规则执行的完整重跑 |
| `harness-source.tar.gz` | 七库 adapter、runner、汇总脚本和构建环境脚本 |
| `optimal-api-overlay-current.patch` | 在精确 yjson commit 上使用的 canonical payload 与最优公开 API overlay |
| `checksums.txt` | 上述四个文件的 SHA-256 |

运行以下命令校验归档：

```terminal
cd benchmarks/results/full-seven-library/2026-08-30
sha256sum -c checksums.txt
```

成功时会为四个文件分别输出 `OK`。完整结论和两批汇总见
[当前开发性能结果](../../../../docs/performance/results/2026-08-30-current-dev-seven-library.md)。

两批所有 workload 都至少有一个实现的 CV 超过 5%。这些数据完整保留，但不能用于发布
精确倍数或替代 2.0.0 的 qualified performance gate。
