# 性能研究摘要

本文记录影响公开 API 和实现方向的性能结论，不保留开发机路径、逐次运行过程或失败实验
流水账。当前可引用的数字见[性能结果](performance/README.md)。

## 已采用的方向

### JSON literal

`@Json` 直接写入紧凑 JSON，`@JsonValue` 构造可修改树。两者共享插值求值与 codec 选择
规则，但服务于不同返回类型，不应为追求表面统一而增加中间 AST。

### Generated typed codec

生成代码优先保留 canonical fast path：结构已完整、字段顺序可确定时直接构造目标值；
需要完整配置语义时继续使用通用 reader。缓存 `YJson.fastDecoder` 可以复用 codec 选择，
但不引入持有调用方输入或跨调用共享可变解析状态的 session。

### Large Map encode

大 Map 的主要成本集中在 entry 遍历、key/value 编码和输出增长。已采用单次遍历与直接输出
路径；需要额外 materialization、排序或二次扫描的候选未进入默认实现。

### Backend selection

Pure、Custom Native 与 yyjson backend 面向不同 workload。小对象的固定跨层成本可能高于
收益；较大输入的 decode 可能受益于 native parser。默认 backend 因此保持 Pure，Native
路径由应用显式选择。

## 未采用的方向

- 持有输入 buffer 的 reusable decode session：生命周期和所有权成本高于已验证收益。
- 按 payload 动态切换 session：增加分支和状态，没有形成稳定的跨 workload 改善。
- Borrowed view 作为 generated codec 默认路径：扩大公开生命周期 contract，且收益不稳定。
- 针对单一 Person workload 的专用内部路径：局部收益无法覆盖更广的回归风险。

这些结论只约束当前默认实现；新的候选仍需在等语义 workload 上独立验证。
