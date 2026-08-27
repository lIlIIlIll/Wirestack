# Backend benchmark package

该 executable 使用 public API 比较四种 DOM 表示：mutable `JsonNode`、Pure
`CompactJsonDocument`、Custom Native DOM 和 yyjson Direct DOM。

Workload 分开测量 parse lifecycle、retained lookup、bulk traversal、serialization 与 round
trip。Native parse/roundtrip 计入 deterministic `close()`；checksum 只防止结果消除，不是
跨 backend 的语义 hash。

运行前先通过 contract checks 验证可观察结果一致。该 package 不用于 typed codec 或 typed
stream 排名。采集方法与当前结果见[性能文档](../../docs/performance/README.md)。
