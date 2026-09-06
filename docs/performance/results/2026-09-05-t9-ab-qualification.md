# 2026-09-05 T9 A/B qualification(bb43321 基线 vs 优化后 dev)

11 轮交替/反转 A/B,按 0.1.0 性能纪律执行:固定 CPU(96 核 server `ubuntu2223131`,
`--cpu 8`),每轮独立进程、奇偶轮换 cell 顺序,每侧 11 轮。**全部 30 case 双侧
CV ≤ 3%,全部 stable**。

- A(基线):yjson @ `bb43321`(修复后、优化前)
- B(优化):dev @ 优化系列(map add 检测、覆写式 path、escape 查表、
  cursor 直读 Option 标量、池化 writer 状态复用、skip 线性扫描)

结论与逐 case 表见
[`benchmarks/results/t9-ab-qualification-20260905/qualification.md`](../../benchmarks/results/t9-ab-qualification-20260905/qualification.md);
原始证据(22 个 cell 的完整输出)在同目录 `ab-results.tgz`。

## 结果摘要

| 指标 | 值 |
| --- | ---: |
| **geomean B/A(30 case,全 stable)** | **0.9482** |
| t9_5_2_optionDeserialize | **0.468**(-53.2%) |
| t9_5_3_optionRoundTrip | **0.598**(-40.2%) |
| t9_2_2_longStringSerialize | **0.630**(-37.0%) |
| t9_5_1_optionSerialize | 0.881(-11.9%) |
| t9_5_8_unknownFieldDeserialize | 0.915(-8.5%) |
| 退化 >5% | 3 个亚微秒 case(+34~85ns,geomean 已被吸收) |

与 Jackson 的关系:归档矩阵(单 run diagnostic)测得 yjson-msgc/Jackson
geomean 1.018(hand 口径);按本 qualification 的 0.9482 折算,优化树约
**0.965**——与 Jackson 持平偏优。Jackson 侧自身的 11 轮交替对照不在本页
范围内,vs-Jackson 倍数声明仍以矩阵页的 diagnostic 标注为准。
