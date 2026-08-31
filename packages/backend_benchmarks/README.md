# Backend benchmark package

这个 repository-only executable 使用 public API 比较四种文档路径：mutable `JsonNode`、
managed `JsonDocument`、`NativeBackends.customNative` 和 `YyjsonBackends.yyjson`。

workload 分开测量 parse lifecycle、retained lookup、细粒度 view traversal、同形状的 fine-view/
bulk materialization、serialization 和 roundtrip。
Native/yyjson parse 与 roundtrip 计入确定性 `close()`。checksum 用于防止结果消除，不是跨
backend 的语义 hash。

运行前先通过 contract checks 验证可观察结果一致。该 package 不用于 typed codec 或 typed
stream 排名。采集方法与当前结果见[性能文档](../../docs/performance/README.md)。
