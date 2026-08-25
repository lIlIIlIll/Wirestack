# 性能方法

公开性能结论遵守以下约束：

- 明确 library/backend、API、operation、payload 与输入形态；
- baseline 与 candidate 使用相同 workload，并交替执行以降低顺序偏差；
- 方向结论与精确比例分开，波动超出门槛时不发布精确比例；
- latency ratio 统一为 `yjson median / peer median`；
- README 展示行要求两侧 CV ≤ 5%，更严格的绝对延迟结论使用 CV ≤ 3%；
- 每个 release 必须发布 yjson、stdx.json、cjfast_json 同批次的完整匹配 workload 表；
- CV 只决定 `stable` / `noisy` 标签，任何已完成 workload 都不得因波动过大而隐藏；
- 跨 runtime 数据只提供特定 API 的上下文，不代表产品整体排名；
- 延迟、吞吐、allocation 与峰值内存分别陈述，不能相互推导。

结果页只保留理解结论所需的 workload、统计值和限制。机器路径、临时目录、运行日志与
一次性排障过程不属于用户文档；需要长期审计的原始证据应作为不可变 artifact 单独发布。
