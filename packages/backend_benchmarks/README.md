# Backend benchmarks

该 package 通过公开 API 比较四种 DOM backend：

- mutable Pure Cangjie `JsonNode`；
- read-only Pure Cangjie `CompactJsonDocument`；
- Custom Native `NativeCompactJsonDocument`；
- yyjson Direct `YyjsonCompactJsonDocument`。

它与 typed codec benchmark 分离，避免把不同数据模型或 Native 依赖混为同一排名。

workload 覆盖 parse lifecycle、retained lookup、traversal、serialization 与 round trip。
Native parse 和 round trip 包含 `close()`；contract test 会验证各 backend 的可观察结果
一致。traversal checksum 只用于防止结果被消除，不是跨 backend 的语义 hash。

结果与统计边界见[性能文档](../../docs/performance/README.md)。
