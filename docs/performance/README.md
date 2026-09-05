# 性能证据

yjson 的性能取决于 API、data model、payload、input shape 和 host。typed codec、mutable
`JsonNode`、managed `JsonDocument`、显式 backend 和 stream 是不同问题，不能拼成一个
“最快库”排名。

## 0.1.0 状态

`0.1.0` 还没有完成正式 release qualification，因此当前不发布新的性能倍数声明。合格结果
必须绑定候选 commit、产品源码 digest、benchmark digest、固定 SDK、CPU affinity、heap、
workload checksum、RSS、原始轮次和 runner version。

发布门禁至少包含：

- Pure baseline/candidate 的 11 轮交替/反转 A/B；
- Native/Pure 的独立进程 11 轮资格；
- yjson、stdx.json、cjfast_json 的同批次共同 workload；
- DOM、typed codec 和 stream 分表；
- checksum 正确性、RSS 和跨 profile 重复；
- 双方 CV 不超过 5%，否则保留完整 noisy 批次。

具体阈值见[性能方法](methodology.md)。实现设计结论见
[性能设计结论](../performance.md)。

## 历史证据

以下页面绑定旧版本或开发快照，只用于审计和新候选的 baseline 选择：

- [2026-09-05 T9 A/B qualification](results/2026-09-05-t9-ab-qualification.md)
- [2026-09-05 T9 矩阵(diagnostic)](results/2026-09-05-t9-matrix-bb43321.md)
- [2.0.0 性能验收](results/2026-08-27-yjson-2.0.0.md)
- [2026-08-26 Native acceleration](results/2026-08-26-native-acceleration.md)
- [2026-08-25 Linux release baseline](results/2026-08-25-linux-release-three-library.md)

旧页面不会因 `0.1.x` API 或实现变化而改写，也不能直接成为 `0.1.0` claim。

## 如何读表

- ratio 统一为 `yjson median / peer median`；小于 1 表示 yjson 延迟更低；
- process median 是主要延迟统计；
- CV 超过门槛的行保留并标为 noisy，不发布精确比例；
- 高 CV 不能用于隐藏不利 workload；
- 不同日期、runtime、SDK、input 或 API 的数字不能合并；
- latency 不能推导 allocation、RSS、peak memory 或 throughput。

原始样本、logs、manifest、checksum 和环境信息属于不可变 release artifact。只有结果页明确
写为通过，并且能追溯到已发布 commit 时，才能进入用户-facing claim。
