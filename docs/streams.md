# Stream I/O

普通 stream API 始终连接统一的增量 reader/writer。stream 由调用方创建和关闭；yjson 不会
关闭 caller-owned `InputStream` 或 `OutputStream`。

```cangjie
YJson.encodeToStreamWith(UserJson, user, output)
let decoded = YJson.decodeFromStreamWith(UserJson, input)

YJson.toStream(user, output)
let decoded = YJson.fromStream<User>(input)
```

这些入口没有 backend 参数，也不会把普通 stream 偷换成 read-to-EOF。每次调用读取一个
完整 JSON document 并检查 trailing content；它不是多文档 framing protocol。失败后不
保证 stream 停在可恢复边界。

读取限制通过 `JsonReadConfig(limits: JsonReadLimits(...))` 传入，写出限制通过
`JsonWriteConfig(..., limits: JsonWriteLimits(...))` 传入。增量 writer 可能已经写出前缀后
才在 `finish()` 报告 `output_too_large`，因此任何失败后的输出都不可继续追加。

需要 Native/yyjson whole-document 行为时，显式依赖 `yjson_backends` 并调用
`YJsonAdvanced.*WithBackend`；详见 [Native 加速与高级 Backend](backends.md)。
