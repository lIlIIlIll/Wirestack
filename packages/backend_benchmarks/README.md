# 文档后端性能测试

本包通过公开 API 比较四种文档表示：可修改的 `JsonNode`、由 GC 管理的
`JsonDocument`、`NativeBackends.customNative` 和 `YyjsonBackends.yyjson`。
它只在仓库内用于性能测试。

测试分别测量解析和释放、保留文档后的查找、逐项遍历视图、批量转换为 AST、序列化及往返转换。
逐项遍历与批量转换使用相同形状的数据。Native 和 yyjson 的解析及往返转换用例计入
`close()` 的耗时。校验和用于防止编译器消除计算结果，不用于判断各后端的结果是否相同。

测量前，先运行契约检查，确认各后端的可观察结果一致。本包不比较类型编解码或类型流式处理的性能。
采集方法与当前结果见[性能文档](../../docs/performance/README.md)。
