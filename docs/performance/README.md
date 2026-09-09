# 性能测试

比较性能时，要先确认使用的是同一种 API、数据模型、输入数据和机器环境。类型编解码、
可修改的 `JsonNode`、只读的 `JsonDocument`、可选后端和流式读写需要分别测量。

## 0.1.0 状态

`0.1.0` 尚未通过正式性能验收。用于发布的测试结果必须记录候选提交、产品和测试脚本的
摘要、SDK、CPU 亲和性、堆大小、测试数据校验和、RSS、原始样本及运行脚本版本。

发布前至少完成以下检查：

- Pure 基线与候选版本的 11 轮 A/B 测试，交替运行并反转顺序；
- Native 与 Pure 在独立进程中的 11 轮对比；
- yjson、stdx.json、cjfast_json 的同一批次、相同数据的对比；
- DOM、类型编解码和流式读写分别列出结果；
- 校验和、RSS，以及不同配置下的重复测试；
- 双方变异系数（CV）不超过 5%；超出时保留完整批次并标记为噪声较大。

具体阈值见[性能方法](methodology.md)。实现设计结论见
[性能设计结论](../performance.md)。

当前 `main` 开发快照的七库完整测量见[2026-09-09 main 七库对比](results/2026-09-09-main-seven-library.md)。

## 历史证据

以下页面记录了旧版本或开发快照的结果，可用来查看历史数据或选择测试基线：

- [2026-09-05 T9 A/B qualification](results/2026-09-05-t9-ab-qualification.md)
- [2026-09-05 T9 矩阵(diagnostic)](results/2026-09-05-t9-matrix-bb43321.md)
- [2.0.0 性能验收](results/2026-08-27-yjson-2.0.0.md)
- [2026-08-26 Native acceleration](results/2026-08-26-native-acceleration.md)
- [2026-08-25 Linux release baseline](results/2026-08-25-linux-release-three-library.md)

历史页面保留测量时的信息，不随 `0.1.x` 的实现变化而更新。

## 如何读表

- 比值统一为 `yjson median / peer median`；小于 1 表示 yjson 延迟更低；
- 延迟主要采用进程样本的中位数；
- CV 超过阈值的行保留并标为 noisy，不发布精确比例；
- 高 CV 的慢速用例也必须保留；
- 不同日期、运行时、SDK、输入或 API 的数字不能合并；
- 延迟不能用来推导分配量、RSS、内存峰值或吞吐量。

发布时保存原始样本、日志、清单、校验和及环境信息，不再改写。只有结果页标记为通过，
且能对应到已发布提交的结果，才能用于对外说明性能。
